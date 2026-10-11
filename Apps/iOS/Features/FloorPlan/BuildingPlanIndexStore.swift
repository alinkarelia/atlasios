import Foundation

struct BuildingPlanFloorRecord: Identifiable, Codable, Hashable, Sendable {
    var floorIndex: Int
    var name: String
    var id: Int { floorIndex }
}

struct BuildingPlanApartment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var floorIndex: Int
    var label: String
    init(id: UUID = UUID(), floorIndex: Int, label: String) {
        self.id = id; self.floorIndex = floorIndex; self.label = label
    }
}

/// An organizational link to an exact saved plan, never a geometric alignment.
struct BuildingPlanAssociation: Codable, Hashable, Sendable {
    var planID: UUID
    var apartmentID: UUID
    var floorIndex: Int
}

struct BuildingPlanIndex: Codable, Hashable, Sendable {
    var schemaVersion = 1
    var projectID: UUID
    var buildingName: String?
    var floors: [BuildingPlanFloorRecord] = []
    var apartments: [BuildingPlanApartment] = []
    var associations: [BuildingPlanAssociation] = []
    var revision: Int64 = 0
    var updatedAt = Date()

    func apartment(for planID: UUID, floorIndex: Int) -> BuildingPlanApartment? {
        guard let link = associations.first(where: { $0.planID == planID && $0.floorIndex == floorIndex }) else { return nil }
        return apartments.first { $0.id == link.apartmentID && $0.floorIndex == floorIndex }
    }
    func floorName(_ index: Int) -> String {
        floors.first { $0.floorIndex == index }?.name ?? "Этаж \(index)"
    }
}

enum BuildingPlanIndexError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}

/// File IO runs outside the UI actor. Every mutation reloads and atomically replaces
/// the versioned document; failed reads/writes leave the previous file untouched.
actor BuildingPlanIndexStore {
    nonisolated let fileURL: URL
    private let projectID: UUID
    private static let maximumFileBytes = 8 * 1_024 * 1_024
    // Different navigation destinations can create separate actor instances.
    // Serialize their read-modify-write sections to avoid losing catalog edits.
    private static let documentLock = NSRecursiveLock()

    init(directory: URL, projectID: UUID) {
        self.projectID = projectID
        fileURL = directory.appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent("Design", isDirectory: true)
            .appendingPathComponent("plan-associations.json")
    }

    func load() throws -> BuildingPlanIndex {
        Self.documentLock.lock()
        defer { Self.documentLock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return BuildingPlanIndex(projectID: projectID)
        }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumFileBytes else { throw BuildingPlanIndexError.invalid("Каталог здания слишком большой. Исходный файл сохранён.") }
        let data = try Data(contentsOf: fileURL)
        let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let version = header?["schemaVersion"] as? Int, version == 1 else {
            throw BuildingPlanIndexError.invalid("Версия каталога здания не поддерживается. Обновите приложение; исходный файл сохранён.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(BuildingPlanIndex.self, from: data)
        try validate(index)
        return index
    }

    @discardableResult
    func renameBuilding(_ name: String) throws -> BuildingPlanIndex {
        let clean = try Self.name(name, title: "Название здания")
        return try commit { $0.buildingName = clean }
    }

    @discardableResult
    func saveFloor(_ draft: BuildingPlanFloorRecord) throws -> BuildingPlanIndex {
        let clean = BuildingPlanFloorRecord(floorIndex: draft.floorIndex, name: try Self.name(draft.name, title: "Название этажа"))
        return try commit { index in
            if let position = index.floors.firstIndex(where: { $0.floorIndex == clean.floorIndex }) { index.floors[position] = clean }
            else { index.floors.append(clean) }
        }
    }

    /// The screen also checks actual saved plans before removing an empty floor.
    @discardableResult
    func deleteFloor(_ floorIndex: Int) throws -> BuildingPlanIndex {
        try commit { index in
            guard !index.apartments.contains(where: { $0.floorIndex == floorIndex }),
                  !index.associations.contains(where: { $0.floorIndex == floorIndex }) else {
                throw BuildingPlanIndexError.invalid("Сначала перенесите или удалите квартиры этажа. Обмеры сохраняются отдельно.")
            }
            index.floors.removeAll { $0.floorIndex == floorIndex }
        }
    }

    @discardableResult
    func saveApartment(_ draft: BuildingPlanApartment) throws -> BuildingPlanIndex {
        var apartment = draft
        apartment.label = try Self.name(draft.label, title: "Название квартиры или зоны")
        return try commit { index in
            guard !index.associations.contains(where: { $0.apartmentID == apartment.id && $0.floorIndex != apartment.floorIndex }) else {
                throw BuildingPlanIndexError.invalid("У квартиры есть обмеры на другом этаже. Перенесите их через настройки обмеров перед изменением этажа квартиры.")
            }
            if let position = index.apartments.firstIndex(where: { $0.id == apartment.id }) { index.apartments[position] = apartment }
            else { index.apartments.append(apartment) }
        }
    }

    /// Removing an apartment only removes its organizational links, never plans.
    @discardableResult
    func deleteApartment(_ id: UUID) throws -> BuildingPlanIndex {
        try commit { index in
            index.apartments.removeAll { $0.id == id }
            index.associations.removeAll { $0.apartmentID == id }
        }
    }

    @discardableResult
    func assign(planID: UUID, apartmentID: UUID?, floorIndex: Int) throws -> BuildingPlanIndex {
        try commit { index in
            if let apartmentID {
                guard index.apartments.contains(where: { $0.id == apartmentID && $0.floorIndex == floorIndex }) else {
                    throw BuildingPlanIndexError.invalid("Квартира не найдена на выбранном этаже. Выберите другую квартиру или оставьте обмер без квартиры.")
                }
            }
            index.associations.removeAll { $0.planID == planID }
            if let apartmentID { index.associations.append(.init(planID: planID, apartmentID: apartmentID, floorIndex: floorIndex)) }
        }
    }

    private func commit(_ mutation: (inout BuildingPlanIndex) throws -> Void) throws -> BuildingPlanIndex {
        Self.documentLock.lock()
        defer { Self.documentLock.unlock() }
        var next = try load()
        try mutation(&next)
        let (revision, overflow) = next.revision.addingReportingOverflow(1)
        guard !overflow else { throw BuildingPlanIndexError.invalid("Счётчик версий каталога исчерпан. Исходный файл сохранён.") }
        next.revision = revision
        next.updatedAt = Date()
        next.floors.sort { $0.floorIndex < $1.floorIndex }
        next.apartments.sort { ($0.floorIndex, $0.label, $0.id.uuidString) < ($1.floorIndex, $1.label, $1.id.uuidString) }
        next.associations.sort { $0.planID.uuidString < $1.planID.uuidString }
        try validate(next)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= Self.maximumFileBytes else { throw BuildingPlanIndexError.invalid("Каталог здания слишком большой. Изменения не сохранены.") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
        return next
    }

    private func validate(_ index: BuildingPlanIndex) throws {
        guard index.schemaVersion == 1, index.projectID == projectID, index.revision >= 0,
              index.floors.count <= 601, index.apartments.count <= 20_000, index.associations.count <= 50_000,
              Set(index.floors.map(\.floorIndex)).count == index.floors.count,
              Set(index.apartments.map(\.id)).count == index.apartments.count,
              Set(index.associations.map(\.planID)).count == index.associations.count else {
            throw BuildingPlanIndexError.invalid("Каталог содержит неверный проект, повторные записи или некорректную версию. Исходный файл сохранён.")
        }
        if let name = index.buildingName { _ = try Self.name(name, title: "Название здания") }
        var apartmentKeys = Set<String>()
        for floor in index.floors {
            try Self.validateFloor(floor.floorIndex)
            _ = try Self.name(floor.name, title: "Название этажа")
        }
        for apartment in index.apartments {
            try Self.validateFloor(apartment.floorIndex)
            let label = try Self.name(apartment.label, title: "Название квартиры")
            let key = "\(apartment.floorIndex):" + label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            guard apartmentKeys.insert(key).inserted else { throw BuildingPlanIndexError.invalid("На этом этаже уже есть квартира с таким названием.") }
        }
        for link in index.associations {
            try Self.validateFloor(link.floorIndex)
            guard index.apartments.contains(where: { $0.id == link.apartmentID && $0.floorIndex == link.floorIndex }) else {
                throw BuildingPlanIndexError.invalid("В каталоге есть связь с отсутствующей квартирой или другим этажом. Исходный файл сохранён.")
            }
        }
    }

    private static func validateFloor(_ value: Int) throws {
        guard (-100...500).contains(value) else { throw BuildingPlanIndexError.invalid("Номер этажа должен быть от −100 до 500.") }
    }
    private static func name(_ value: String, title: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 200, !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BuildingPlanIndexError.invalid("\(title): введите от 1 до 200 символов без переносов строк.")
        }
        return clean
    }
}
