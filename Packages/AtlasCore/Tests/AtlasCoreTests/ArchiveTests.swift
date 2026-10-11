import Foundation
import Testing
@testable import AtlasCore

private func archiveDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-archive-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func uint32(_ data: Data, at offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
}

@Test func archiveUsesKnownCRC32AndUTF8Flags() throws {
    let directory = try archiveDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.txt")
    try Data("123456789".utf8).write(to: source)
    let destination = directory.appendingPathComponent("project.zip")
    try AtlasArchiveWriter.write(entries: [.init(relativePath: "съёмка/source.txt", fileURL: source)], to: destination)
    let bytes = try Data(contentsOf: destination)
    #expect(uint32(bytes, at: 0) == 0x04034b50)
    #expect(bytes[6] == 0x08 && bytes[7] == 0x08)
    let centralOffset = Int(uint32(bytes, at: bytes.count - 6))
    #expect(uint32(bytes, at: centralOffset) == 0x02014b50)
    #expect(uint32(bytes, at: centralOffset + 16) == 0xcbf43926) // published CRC32 test vector
    #expect(uint32(bytes, at: centralOffset + 20) == 9)
    #expect(uint32(bytes, at: centralOffset + 24) == 9)
}

@Test func independentPythonZipfileReadsEveryStreamedByteAndVerifiesCRC() throws {
    let directory = try archiveDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let metadata = directory.appendingPathComponent("metadata.json")
    try Data("{\"project\":\"Atlas\"}".utf8).write(to: metadata)
    let source = directory.appendingPathComponent("source.bin")
    let payload = Data((0..<200_003).map { UInt8($0 % 251) })
    try payload.write(to: source)
    let empty = directory.appendingPathComponent("empty.bin")
    try Data().write(to: empty)
    let destination = directory.appendingPathComponent("project.zip")
    try AtlasArchiveWriter.write(entries: [.init(relativePath: "project.atlas.json", fileURL: metadata),
                                          .init(relativePath: "съёмка/mesh.bin", fileURL: source),
                                          .init(relativePath: "assets/empty.bin", fileURL: empty)], to: destination)
    #if os(Linux) || os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // Keep Python's -c argument ASCII: Darwin may decompose Unicode in
    // Process arguments, while the ZIP writer deliberately stores NFC names.
    // Python constructs the exact expected NFC scalars after argument transport.
    let pythonSource = #"""
        import sys, zipfile
        mesh_name = '\u0441\u044a\u0451\u043c\u043a\u0430/mesh.bin'
        with zipfile.ZipFile(sys.argv[1]) as archive:
            actual = archive.namelist()
            assert actual == ['project.atlas.json', mesh_name, 'assets/empty.bin'], repr(actual)
            assert archive.testzip() is None
            assert archive.read('project.atlas.json') == b'{"project":"Atlas"}'
            assert archive.read(mesh_name) == open(sys.argv[2], 'rb').read()
            assert archive.read('assets/empty.bin') == b''
            assert all(item.flag_bits & 0x800 for item in archive.infolist())
            assert all(item.compress_type == zipfile.ZIP_STORED for item in archive.infolist())
        """#
    #expect(pythonSource.utf8.allSatisfy { $0 < 0x80 })
    process.arguments = ["python3", "-c", pythonSource, destination.path, source.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #endif
}

@Test func unsafeArchivePathsNeverReplaceAnExistingOutput() throws {
    let directory = try archiveDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.txt")
    let destination = directory.appendingPathComponent("project.zip")
    let previous = Data("previous backup must survive".utf8)
    try Data("source".utf8).write(to: source)
    try previous.write(to: destination)
    for path in ["", "/absolute", "../outside", "assets/../outside", "assets//mesh", "assets\\mesh", "C:mesh", "bad\npath", "bad\0path"] {
        #expect(throws: AtlasArchiveError.self) { try AtlasArchiveWriter.write(entries: [.init(relativePath: path, fileURL: source)], to: destination) }
        #expect(try Data(contentsOf: destination) == previous)
    }
    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!remaining.contains { $0.hasSuffix(".partial") })
}

@Test func duplicateNormalizedNamesAndSymbolicLinksAreRejected() throws {
    let directory = try archiveDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.txt")
    try Data("source".utf8).write(to: source)
    let destination = directory.appendingPathComponent("project.zip")
    #expect(throws: AtlasArchiveError.duplicatePath("café.json")) {
        try AtlasArchiveWriter.write(entries: [.init(relativePath: "café.json", fileURL: source),
                                              .init(relativePath: "cafe\u{301}.json", fileURL: source)], to: destination)
    }
    #expect(throws: AtlasArchiveError.duplicatePath("metadata.json")) {
        try AtlasArchiveWriter.write(entries: [.init(relativePath: "Metadata.json", fileURL: source),
                                              .init(relativePath: "metadata.json", fileURL: source)], to: destination)
    }
    let link = directory.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: AtlasArchiveError.sourceMustBeRegularFile("link.txt")) {
        try AtlasArchiveWriter.write(entries: [.init(relativePath: "link.txt", fileURL: link)], to: destination)
    }
    #expect(throws: AtlasArchiveError.sourceIsDestination) {
        try AtlasArchiveWriter.write(entries: [.init(relativePath: "source.txt", fileURL: source)], to: source)
    }
}

@Test func ZIP32BoundsAreRejectedBeforeReadingHugeSparseFiles() throws {
    let directory = try archiveDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("large.bin")
    #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
    let handle = try FileHandle(forWritingTo: source)
    try handle.truncate(atOffset: UInt64(UInt32.max))
    try handle.close()
    #expect(throws: AtlasArchiveError.requiresZIP64) {
        try AtlasArchiveWriter.write(entries: [.init(relativePath: "large.bin", fileURL: source)], to: directory.appendingPathComponent("large.zip"))
    }
    let repeated = Array(repeating: AtlasArchiveEntry(relativePath: "source", fileURL: source), count: Int(UInt16.max))
    #expect(throws: AtlasArchiveError.requiresZIP64) { try AtlasArchiveWriter.write(entries: repeated, to: directory.appendingPathComponent("many.zip")) }
}

@Test func emptyArchiveIsValidAndSuccessfulPublicationReplacesOutput() throws {
    let directory = try archiveDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("empty.zip")
    try Data("old".utf8).write(to: destination)
    try AtlasArchiveWriter.write(entries: [], to: destination)
    let data = try Data(contentsOf: destination)
    #expect(data.count == 22)
    #expect(uint32(data, at: 0) == 0x06054b50)
    #expect(data.dropFirst(4).allSatisfy { $0 == 0 })
}

@Test func passportSHA256AcceptsExactStreamedArchiveMembersIncludingEmptyFile() throws {
    let directory = try archiveDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("original.txt"), empty = directory.appendingPathComponent("empty.bin")
    try Data("123456789".utf8).write(to: source); try Data().write(to: empty)
    let destination = directory.appendingPathComponent("verified.zip")
    try AtlasArchiveWriter.write(entries: [
        .init(relativePath: "original.txt", fileURL: source,
              expectedSHA256: "15e2b0d3c33891ebb0f1ef609ec419420c20e320ce94c65fbc8c3312448eb225"),
        .init(relativePath: "empty.bin", fileURL: empty,
              expectedSHA256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    ], to: destination)
    #expect(uint32(try Data(contentsOf: destination), at: 0) == 0x04034b50)
    #if os(Linux) || os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", "import hashlib,sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; assert hashlib.sha256(z.read('original.txt')).hexdigest() == '15e2b0d3c33891ebb0f1ef609ec419420c20e320ce94c65fbc8c3312448eb225'; assert z.read('empty.bin') == b''", destination.path]
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #endif
}

@Test func passportSHA256RejectsSameSizeChangedSourceAndPreservesPreviousArchive() throws {
    let directory = try archiveDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("metadata.json")
    let original = Data("{\"label\":\"A\"}".utf8), changed = Data("{\"label\":\"B\"}".utf8)
    #expect(original.count == changed.count)
    try original.write(to: source)
    let expected = FieldTransferDigest.sha256(original)
    let destination = directory.appendingPathComponent("verified.zip")
    let entry = AtlasArchiveEntry(relativePath: "metadata.json", fileURL: source, expectedSHA256: expected)
    try AtlasArchiveWriter.write(entries: [entry], to: destination)
    let previous = try Data(contentsOf: destination)
    // Models a metadata edit after the delivery passport was assembled. The
    // file's current size still matches, so the old size-only check accepts it.
    try changed.write(to: source, options: .atomic)
    #expect(throws: AtlasArchiveError.sourceChanged("metadata.json")) {
        try AtlasArchiveWriter.write(entries: [entry], to: destination)
    }
    #expect(try Data(contentsOf: destination) == previous)
    #expect(try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".partial") })
}

@Test func invalidPassportDigestNeverPublishesOrReplacesArchive() throws {
    let directory = try archiveDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("original.txt"), destination = directory.appendingPathComponent("verified.zip")
    try Data("original".utf8).write(to: source)
    for digest in ["", "not-a-sha256", String(repeating: "A", count: 64), String(repeating: "0", count: 64)] {
        #expect(throws: AtlasArchiveError.sourceChanged("original.txt")) {
            try AtlasArchiveWriter.write(entries: [.init(relativePath: "original.txt", fileURL: source, expectedSHA256: digest)], to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
