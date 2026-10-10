import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct AtlasArchiveEntry: Sendable {
    public let relativePath: String
    public let fileURL: URL
    public init(relativePath: String, fileURL: URL) { self.relativePath = relativePath; self.fileURL = fileURL }
}

public enum AtlasArchiveError: Error, LocalizedError, Equatable, Sendable {
    case invalidPath(String)
    case duplicatePath(String)
    case sourceMustBeRegularFile(String)
    case sourceIsDestination
    case sourceChanged(String)
    case requiresZIP64
    case outputMustBeFileURL
    case cannotCreateTemporaryFile
    case publishFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidPath: "У одного из файлов недопустимое имя внутри архива. Исходники проекта сохранены."
        case .duplicatePath: "В архиве совпадают имена файлов. Устраните дубликат перед повторным экспортом."
        case .sourceMustBeRegularFile: "Один из исходников недоступен или является ссылкой. Проверьте файлы проекта."
        case .sourceIsDestination: "Архив нельзя сохранить поверх исходного файла. Выберите другое место."
        case .sourceChanged: "Исходный файл изменился во время экспорта. Дождитесь завершения съёмки и повторите создание архива."
        case .requiresZIP64: "Проект превышает лимит ZIP32: архив должен быть меньше 4 ГиБ и содержать менее 65 535 файлов. Экспортируйте отдельные части проекта."
        case .outputMustBeFileURL: "Для архива необходимо выбрать локальный файл."
        case .cannotCreateTemporaryFile: "Не удалось начать запись архива. Проверьте свободное место и доступ к папке."
        case .publishFailed: "Не удалось завершить сохранение архива. Предыдущая копия сохранена."
        }
    }
}

/// A stored (uncompressed) ZIP32 archive with 64 KiB source buffers. Metadata is
/// proportional to the number of entries; source files are never loaded in full.
/// Existing output survives any failure before atomic publication. ZIP64 is not
/// supported, and every overflowing size/count/offset is rejected explicitly.
public enum AtlasArchiveWriter {
    private static let flags: UInt16 = 0x0808 // UTF-8 paths + trailing data descriptor
    private static let limit = UInt64(UInt32.max) // max fields are reserved for ZIP64
    private static let chunkSize = 64 * 1024

    public static func write(entries: [AtlasArchiveEntry], to destination: URL) throws {
        guard destination.isFileURL, !destination.path.contains("\0") else { throw AtlasArchiveError.outputMustBeFileURL }
        guard entries.count < Int(UInt16.max) else { throw AtlasArchiveError.requiresZIP64 }
        let prepared = try prepare(entries, destination: destination)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".atlas-archive-\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw AtlasArchiveError.cannotCreateTemporaryFile }
        let output: FileHandle
        do { output = try FileHandle(forWritingTo: temporary) }
        catch { try? FileManager.default.removeItem(at: temporary); throw error }
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }

        var offset: UInt64 = 0
        var central: [CentralEntry] = []
        central.reserveCapacity(prepared.count)
        func emit(_ data: Data) throws {
            guard UInt64(data.count) < limit, offset < limit - UInt64(data.count) else { throw AtlasArchiveError.requiresZIP64 }
            try output.write(contentsOf: data)
            offset += UInt64(data.count)
        }

        for entry in prepared {
            let localOffset = UInt32(offset)
            var header = Data()
            header.littleEndian(UInt32(0x04034b50)); header.littleEndian(UInt16(20))
            header.littleEndian(flags); header.littleEndian(UInt16(0))
            header.littleEndian(entry.time); header.littleEndian(entry.date)
            header.littleEndian(UInt32(0)); header.littleEndian(UInt32(0)); header.littleEndian(UInt32(0))
            header.littleEndian(UInt16(entry.name.count)); header.littleEndian(UInt16(0)); header.append(entry.name)
            try emit(header)

            let input = try FileHandle(forReadingFrom: entry.source)
            var crc = CRC32()
            var size: UInt64 = 0
            do {
                while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                    guard size < limit - UInt64(chunk.count) else { throw AtlasArchiveError.requiresZIP64 }
                    size += UInt64(chunk.count)
                    guard size <= entry.expectedSize else { throw AtlasArchiveError.sourceChanged(entry.path) }
                    crc.update(chunk)
                    try emit(chunk)
                }
                try input.close()
            } catch { try? input.close(); throw error }
            guard size == entry.expectedSize else { throw AtlasArchiveError.sourceChanged(entry.path) }
            var descriptor = Data()
            descriptor.littleEndian(UInt32(0x08074b50)); descriptor.littleEndian(crc.value)
            descriptor.littleEndian(UInt32(size)); descriptor.littleEndian(UInt32(size))
            try emit(descriptor)
            central.append(CentralEntry(name: entry.name, crc: crc.value, size: UInt32(size),
                                        offset: localOffset, time: entry.time, date: entry.date))
        }

        let centralOffset = UInt32(offset)
        for entry in central {
            var header = Data()
            header.littleEndian(UInt32(0x02014b50)); header.littleEndian(UInt16(0x0314)); header.littleEndian(UInt16(20))
            header.littleEndian(flags); header.littleEndian(UInt16(0)); header.littleEndian(entry.time); header.littleEndian(entry.date)
            header.littleEndian(entry.crc); header.littleEndian(entry.size); header.littleEndian(entry.size)
            header.littleEndian(UInt16(entry.name.count)); header.littleEndian(UInt16(0)); header.littleEndian(UInt16(0))
            header.littleEndian(UInt16(0)); header.littleEndian(UInt16(0)); header.littleEndian(UInt32(0o100600) << 16)
            header.littleEndian(entry.offset); header.append(entry.name)
            try emit(header)
        }
        let centralSize = UInt32(offset - UInt64(centralOffset))
        var end = Data()
        end.littleEndian(UInt32(0x06054b50)); end.littleEndian(UInt16(0)); end.littleEndian(UInt16(0))
        end.littleEndian(UInt16(central.count)); end.littleEndian(UInt16(central.count))
        end.littleEndian(centralSize); end.littleEndian(centralOffset); end.littleEndian(UInt16(0))
        try emit(end)
        try output.synchronize()
        try output.close()

        // Same-directory POSIX rename atomically replaces a previous archive.
        guard rename(temporary.path, destination.path) == 0 else { throw AtlasArchiveError.publishFailed(errno) }
    }

    private static func prepare(_ entries: [AtlasArchiveEntry], destination: URL) throws -> [PreparedEntry] {
        var seen = Set<String>()
        var minimumSize: UInt64 = 22
        return try entries.map { entry in
            let path = entry.relativePath.precomposedStringWithCanonicalMapping
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
                  path.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw AtlasArchiveError.invalidPath(path) }
            // Reject case variants as well, so extraction on case-insensitive disks is safe.
            guard seen.insert(path.lowercased()).inserted else { throw AtlasArchiveError.duplicatePath(path) }
            let name = Data(path.utf8)
            guard name.count <= Int(UInt16.max) else { throw AtlasArchiveError.requiresZIP64 }
            guard entry.fileURL.isFileURL, !entry.fileURL.path.contains("\0") else { throw AtlasArchiveError.sourceMustBeRegularFile(path) }
            guard entry.fileURL.standardizedFileURL != destination.standardizedFileURL else { throw AtlasArchiveError.sourceIsDestination }
            let attributes = try FileManager.default.attributesOfItem(atPath: entry.fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let bytes = attributes[.size] as? NSNumber else { throw AtlasArchiveError.sourceMustBeRegularFile(path) }
            let size = bytes.uint64Value
            guard size < limit else { throw AtlasArchiveError.requiresZIP64 }
            let overhead = UInt64(30 + 16 + 46 + name.count * 2)
            guard minimumSize < limit - overhead, size < limit - minimumSize - overhead else { throw AtlasArchiveError.requiresZIP64 }
            minimumSize += size + overhead
            let timestamp = dosTimestamp(attributes[.modificationDate] as? Date ?? Date())
            return PreparedEntry(path: path, name: name, source: entry.fileURL, expectedSize: size,
                                 time: timestamp.time, date: timestamp.date)
        }
    }

    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = components.year, year >= 1980 else { return (0, 33) }
        guard year <= 2107 else { return (UInt16(23 << 11 | 59 << 5 | 29), UInt16(127 << 9 | 12 << 5 | 31)) }
        let time = (components.hour ?? 0) << 11 | (components.minute ?? 0) << 5 | (components.second ?? 0) / 2
        let day = (year - 1980) << 9 | (components.month ?? 1) << 5 | (components.day ?? 1)
        return (UInt16(time), UInt16(day))
    }

    private struct PreparedEntry {
        let path: String
        let name: Data
        let source: URL
        let expectedSize: UInt64
        let time: UInt16
        let date: UInt16
    }
    private struct CentralEntry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
        let time: UInt16
        let date: UInt16
    }
}

private extension Data {
    mutating func littleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

private struct CRC32 {
    private var state: UInt32 = 0xffffffff
    var value: UInt32 { state ^ 0xffffffff }
    mutating func update(_ data: Data) {
        for byte in data { state = Self.table[Int((state ^ UInt32(byte)) & 0xff)] ^ (state >> 8) }
    }
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1 }
        return value
    }
}
