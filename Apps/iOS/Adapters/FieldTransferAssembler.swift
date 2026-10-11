import Foundation
import AtlasCore

struct PreparedFieldTransfer: Sendable {
    var manifest: FieldTransferManifest
    var snapshot: AtlasProjectSnapshot
    var skippedScans: Int
}

/// Immutable content-addressed files let ten photo additions reuse nine existing
/// originals instead of copying the whole project ten times. Only complete scans
/// enter a package. This actor performs all directory IO and SHA work off the UI.
actor FieldTransferAssembler {
    private struct PhotoMetadata: Decodable {
        var id: UUID; var projectID: UUID; var createdAt: Date
        var relativePath: String; var metadataPath: String; var source: String
        var byteCount: Int; var sha256: String; var cameraFrameID: UUID?
        var geoTag: GeoTag?; var capturedAt: Date?
        var captureOperator: FieldCaptureOperator? = nil
    }
    private struct CachedDigest { var size: Int64; var modified: Date?; var digest: String }
    private var hashCache: [String: CachedDigest] = [:]
    private let root: URL
    private let blobs: URL
    private let packages: URL
    init(directory: URL) {
        root = directory.appendingPathComponent("FieldTransfers", isDirectory: true)
        blobs = root.appendingPathComponent("blobs", isDirectory: true)
        packages = root.appendingPathComponent("packages", isDirectory: true)
    }

    func prepare(snapshot original: AtlasProjectSnapshot, assetDirectory: URL,
                 scope: FieldTransferScope, device: FieldCaptureDevice,
                 previous: [FieldTransferManifest] = []) throws -> [PreparedFieldTransfer] {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
        let managed = assetDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let projectRoot = "Projects/" + original.project.id.uuidString + "/Captures/"
        let captures = try FieldTransferPaths.resolve(relativePath: String(projectRoot.dropLast()), root: managed)
        var snapshot = original
        snapshot.scans = original.scans.filter { $0.status == .ready }
        let skipped = original.scans.count - snapshot.scans.count
        var materials: [FieldMaterial] = []
        var assets: [FieldAsset] = []
        var paths = Set<String>()
        let projectMaterial = FieldMaterial(id: original.project.id, sourceEntityID: original.project.id, kind: .project)
        materials.append(projectMaterial)
        for scan in snapshot.scans.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try Task.checkCancellation()
            if let tag = scan.geoTag { try GeoTagPolicy.validate(tag) }
            materials.append(FieldMaterial(id: scan.id, sourceEntityID: scan.id,
                kind: scan.source == .roomPlan ? .floorPlan : (scan.assets.contains { $0.kind == .video } && !scan.assets.contains { $0.kind == .mesh } ? .video : .mesh), capturedAt: scan.createdAt,
                frameID: scan.frameID, geoTag: scan.geoTag))
            for reference in scan.assets.sorted(by: { $0.relativePath < $1.relativePath }) {
                guard reference.relativePath.hasPrefix(projectRoot) else {
                    throw TeamError.rejected("Исходник съёмки находится вне каталога этого проекта.")
                }
                // Photos have their own material identity and timing below.
                if reference.relativePath.hasPrefix(projectRoot + "evidence/") { continue }
                guard paths.insert(reference.relativePath).inserted else { continue }
                let file = try FieldTransferPaths.resolve(relativePath: reference.relativePath, root: managed)
                let details = try storeFile(file)
                if let expected = reference.sha256, expected.lowercased() != details.sha256 {
                    throw FieldTransportError.alteredOriginal
                }
                let kind: FieldAssetKind
                switch reference.kind {
                case .mesh: kind = .mesh
                case .roomPlanJSON: kind = .roomPlan
                case .cameraMetadata: kind = .metadata
                case .image: kind = .originalPhoto
                case .video: kind = .originalVideo
                case .depth: kind = .other
                }
                assets.append(FieldAsset(id: stableID("file:" + reference.relativePath), materialID: scan.id,
                    relativePath: reference.relativePath, mediaType: mediaType(file), byteCount: details.size,
                    sha256: details.sha256, kind: kind))
            }
        }
        let evidence = captures.appendingPathComponent("evidence", isDirectory: true)
        if FileManager.default.fileExists(atPath: evidence.path) {
            let metadataFiles = try FileManager.default.contentsOfDirectory(at: evidence,
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            for metadataFile in metadataFiles {
                try Task.checkCancellation()
                let relativeMetadata = projectRoot + "evidence/" + metadataFile.lastPathComponent
                let safeMetadata = try FieldTransferPaths.resolve(relativePath: relativeMetadata, root: managed)
                guard try fileSize(safeMetadata) <= 2 * 1_024 * 1_024 else { throw FieldTransportError.tooLarge }
                let photo = try decoder.decode(PhotoMetadata.self, from: Data(contentsOf: safeMetadata))
                guard photo.projectID == original.project.id,
                      photo.metadataPath == "evidence/" + photo.id.uuidString + ".json",
                      photo.relativePath.hasPrefix("evidence/" + photo.id.uuidString + "."),
                      metadataFile.lastPathComponent == photo.id.uuidString + ".json" else {
                    throw TeamError.rejected("Фото относится к другому проекту или его метаданные повреждены.")
                }
                if let tag = photo.geoTag { try GeoTagPolicy.validate(tag) }
                materials.append(FieldMaterial(id: photo.id, sourceEntityID: photo.id, kind: .photo,
                    capturedAt: photo.capturedAt, importedAt: photo.source == "photoLibrary" ? photo.createdAt : nil,
                    frameID: photo.cameraFrameID, geoTag: photo.geoTag))
                for (path, kind) in [(projectRoot + photo.relativePath, FieldAssetKind.originalPhoto),
                                     (relativeMetadata, FieldAssetKind.metadata)] {
                    guard paths.insert(path).inserted else { continue }
                    let file = try FieldTransferPaths.resolve(relativePath: path, root: managed)
                    let details = try storeFile(file)
                    if kind == .originalPhoto {
                        guard details.sha256 == photo.sha256.lowercased(), details.size == Int64(photo.byteCount) else {
                            throw FieldTransportError.alteredOriginal
                        }
                    }
                    assets.append(FieldAsset(id: stableID("file:" + path), materialID: photo.id,
                        relativePath: path, mediaType: mediaType(file), byteCount: details.size,
                        sha256: details.sha256, kind: kind))
                }
            }
        }
        // These materials are editable domain data, carried in the complete
        // project snapshot rather than being mislabeled as camera captures.
        for feature in snapshot.features {
            materials.append(FieldMaterial(id: feature.id, sourceEntityID: feature.id, kind: .feature))
        }
        for plan in snapshot.floorPlans where !materials.contains(where: { $0.id == plan.id }) {
            materials.append(FieldMaterial(id: plan.id, sourceEntityID: plan.id, kind: .floorPlan, frameID: plan.frameID))
        }
        for measurement in snapshot.measurements ?? [] {
            materials.append(FieldMaterial(id: measurement.id, sourceEntityID: measurement.id, kind: .measurement,
                capturedAt: measurement.createdAt, frameID: measurement.frameID))
        }
        materials.sort { $0.id.uuidString < $1.id.uuidString }
        assets.sort { $0.relativePath < $1.relativePath }
        // A large project is split into bounded packages. Every source entity
        // stays together with its originals; the snapshot in each package only
        // references scans whose files are present in that package.
        struct Group { let material: FieldMaterial; let assets: [FieldAsset] }
        var priorDomainHashes: [UUID: [UUID: String]] = [:]
        var priorSnapshots: [UUID: AtlasProjectSnapshot] = [:]
        for prior in previous {
            guard let value = try? self.snapshot(for: prior) else { continue }
            priorSnapshots[prior.id] = value
            var hashes: [UUID: String] = [:]
            for feature in value.features { hashes[feature.id] = FieldTransferDigest.sha256(try FieldTransferJSON.encode(feature)) }
            for plan in value.floorPlans { hashes[plan.id] = FieldTransferDigest.sha256(try FieldTransferJSON.encode(plan)) }
            for measurement in value.measurements ?? [] { hashes[measurement.id] = FieldTransferDigest.sha256(try FieldTransferJSON.encode(measurement)) }
            priorDomainHashes[prior.id] = hashes
        }
        var currentDomainHashes: [UUID: String] = [:]
        for feature in snapshot.features { currentDomainHashes[feature.id] = FieldTransferDigest.sha256(try FieldTransferJSON.encode(feature)) }
        for plan in snapshot.floorPlans { currentDomainHashes[plan.id] = FieldTransferDigest.sha256(try FieldTransferJSON.encode(plan)) }
        for measurement in snapshot.measurements ?? [] { currentDomainHashes[measurement.id] = FieldTransferDigest.sha256(try FieldTransferJSON.encode(measurement)) }
        var groups: [Group] = []
        for material in materials where material.id != projectMaterial.id {
            var references = assets.filter { $0.materialID == material.id }
            if let scan = snapshot.scans.first(where: { $0.id == material.sourceEntityID }) {
                let expectedPaths = Set(scan.assets.map(\.relativePath))
                references = assets.filter { expectedPaths.contains($0.relativePath) || $0.materialID == material.id }
            }
            struct Content: Encodable {
                let material: FieldMaterial; let assets: [FieldAsset]; let domainSHA256: String?
            }
            // Already queued or received originals are represented by their
            // original immutable package. A newly saved photo sends only its
            // new material, rather than republishing every older photo.
            func normalized(_ values: [FieldAsset]) -> [FieldAsset] {
                values.map { asset in
                    FieldAsset(id: asset.id, materialID: material.id, relativePath: asset.relativePath,
                        mediaType: asset.mediaType, byteCount: asset.byteCount, sha256: asset.sha256, kind: asset.kind)
                }.sorted { $0.relativePath < $1.relativePath }
            }
            let content = try FieldTransferJSON.encode(Content(material: material, assets: normalized(references),
                domainSHA256: currentDomainHashes[material.id]))
            let unchanged = try previous.contains { prior in
                guard let old = prior.materials.first(where: { $0.id == material.id }) else { return false }
                let priorPaths = Set(priorSnapshots[prior.id]?.scans.first(where: { $0.id == material.sourceEntityID })?.assets.map(\.relativePath) ?? [])
                let oldAssets = prior.assets.filter {
                    ($0.materialID == material.id || priorPaths.contains($0.relativePath)) && $0.kind != .projectSnapshot
                }
                return try FieldTransferJSON.encode(Content(material: old, assets: normalized(oldAssets),
                    domainSHA256: priorDomainHashes[prior.id]?[material.id])) == content
            }
            if !unchanged { groups.append(Group(material: material, assets: references)) }
        }
        if groups.isEmpty, let latest = previous.sorted(by: { $0.createdAt > $1.createdAt }).first,
           let prior = try? self.snapshot(for: latest),
           try FieldTransferJSON.encode(prior.project) == FieldTransferJSON.encode(snapshot.project) {
            return []
        }
        var batches: [[Group]] = [], current: [Group] = []
        var currentPaths = Set<String>(), currentBytes: Int64 = 0
        let byteLimit: Int64 = 1_073_741_824 - 8 * 1_024 * 1_024
        for group in groups {
            let groupBytes = group.assets.reduce(Int64(0)) { $0 + $1.byteCount }
            guard group.assets.count < 2_048, groupBytes <= byteLimit else {
                throw TeamError.rejected("Материал \(group.material.sourceEntityID.uuidString.prefix(8)) слишком большой для одного комплекта. Исходники сохранены; разделите съёмку.")
            }
            let added = group.assets.filter { !currentPaths.contains($0.relativePath) }
            if !current.isEmpty && (currentPaths.count + added.count >= 2_048 ||
                currentBytes + added.reduce(Int64(0), { $0 + $1.byteCount }) > byteLimit || current.count >= 999) {
                batches.append(current); current = []; currentPaths = []; currentBytes = 0
            }
            for asset in group.assets where currentPaths.insert(asset.relativePath).inserted { currentBytes += asset.byteCount }
            current.append(group)
        }
        if !current.isEmpty || batches.isEmpty { batches.append(current) }
        var result: [PreparedFieldTransfer] = []
        for batch in batches {
            var batchMaterials = [projectMaterial] + batch.map(\.material)
            let ids = Set(batch.map { $0.material.sourceEntityID })
            var batchSnapshot = snapshot
            batchSnapshot.scans = snapshot.scans.filter { ids.contains($0.id) }
            batchSnapshot.features = snapshot.features.filter { ids.contains($0.id) }
            batchSnapshot.floorPlans = snapshot.floorPlans.filter { ids.contains($0.id) }
            batchSnapshot.measurements = snapshot.measurements?.filter { ids.contains($0.id) }
            var batchAssets: [FieldAsset] = [], batchPaths = Set<String>()
            for group in batch {
                for asset in group.assets where batchPaths.insert(asset.relativePath).inserted {
                    let ownerID = batchMaterials.contains(where: { $0.id == asset.materialID }) ? asset.materialID : group.material.id
                    batchAssets.append(FieldAsset(id: asset.id, materialID: ownerID, relativePath: asset.relativePath,
                        mediaType: asset.mediaType, byteCount: asset.byteCount, sha256: asset.sha256, kind: asset.kind))
                }
            }
            let snapshotData = try FieldTransferJSON.encode(batchSnapshot)
            let snapshotSHA = FieldTransferDigest.sha256(snapshotData)
            try saveBlob(snapshotData, sha256: snapshotSHA)
            batchAssets.append(FieldAsset(id: stableID("snapshot:" + original.project.id.uuidString), materialID: projectMaterial.id,
                relativePath: "project.atlas.json", mediaType: "application/json", byteCount: Int64(snapshotData.count),
                sha256: snapshotSHA, kind: .projectSnapshot))
            batchMaterials.sort { $0.id.uuidString < $1.id.uuidString }
            batchAssets.sort { $0.relativePath < $1.relativePath }
            struct Identity: Encodable {
                let scope: FieldTransferScope; let projectID: UUID
                let materials: [FieldMaterial]; let assets: [FieldAsset]
            }
            let fingerprint = FieldTransferDigest.sha256(try FieldTransferJSON.encode(Identity(scope: scope,
                projectID: original.project.id, materials: batchMaterials, assets: batchAssets)))
            let id = stableID("package:" + fingerprint)
            let manifestFile = packages.appendingPathComponent(id.uuidString + ".json")
            let manifest: FieldTransferManifest
            if FileManager.default.fileExists(atPath: manifestFile.path) {
                manifest = try FieldTransferJSON.decode(FieldTransferManifest.self, from: Data(contentsOf: manifestFile))
                guard manifest.projectID == original.project.id, manifest.assets == batchAssets else {
                    throw FieldTransportError.alteredOriginal
                }
            } else {
                let value = FieldTransferManifest(id: id, projectID: original.project.id,
                    title: original.project.name, device: device, materials: batchMaterials, assets: batchAssets)
                try value.validate()
                let encoded = try FieldTransferJSON.encode(value)
                guard encoded.count <= 1_024 * 1_024 else { throw FieldTransportError.tooLarge }
                try protectedWrite(encoded, to: manifestFile)
                // The persisted representation is the immutable wire manifest,
                // including the exact millisecond date representation.
                manifest = try FieldTransferJSON.decode(FieldTransferManifest.self, from: encoded)
            }
            result.append(PreparedFieldTransfer(manifest: manifest, snapshot: batchSnapshot, skippedScans: skipped))
        }
        return result
    }

    /// Portable passport for manual sharing through Files, a chat or another
    /// archive app. It requires neither a server nor an authenticated account.
    func deliveryPassport(snapshot: AtlasProjectSnapshot, assetDirectory: URL,
                          device: FieldCaptureDevice, preparedBy: FieldCaptureOperator?) throws -> Data {
        struct CaptureHeader: Decodable {
            struct Segment: Decodable { var id: UUID; var endedAt: Date? }
            var captureOperator: FieldCaptureOperator?; var segments: [Segment]?; var endedAt: Date?
        }
        let managed = assetDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "Projects/" + snapshot.project.id.uuidString + "/Captures/"
        let captures = try FieldTransferPaths.resolve(relativePath: String(prefix.dropLast()), root: managed)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var materialValues: [FieldDeliveryPassport.Material] = []
        var references: [String: (UUID, FieldAssetKind)] = [:]
        let projectID = snapshot.project.id
        materialValues.append(.init(source: FieldMaterial(id: projectID, sourceEntityID: projectID, kind: .project), captureOperator: nil))
        for scan in snapshot.scans {
            var author: FieldCaptureOperator?, endedAt: Date?
            for asset in scan.assets {
                guard asset.relativePath.hasPrefix(prefix) else { throw FieldTransferError.invalidAssetPath(asset.relativePath) }
                let kind: FieldAssetKind = asset.kind == .mesh ? .mesh : (asset.kind == .roomPlanJSON ? .roomPlan : (asset.kind == .image ? .originalPhoto : (asset.kind == .video ? .originalVideo : .metadata)))
                references[asset.relativePath] = (scan.id, kind)
                if asset.kind == .cameraMetadata, asset.relativePath.hasSuffix("/manifest.json") {
                    let file = try FieldTransferPaths.resolve(relativePath: asset.relativePath, root: managed)
                    guard try fileSize(file) <= 2 * 1_024 * 1_024 else { throw FieldTransportError.tooLarge }
                    if let value = try? decoder.decode(CaptureHeader.self, from: Data(contentsOf: file)) {
                        author = value.captureOperator
                        endedAt = value.segments?.first(where: { $0.id == scan.id })?.endedAt ?? value.endedAt
                    }
                }
            }
            materialValues.append(.init(source: FieldMaterial(id: scan.id, sourceEntityID: scan.id,
                kind: scan.source == .roomPlan ? .floorPlan : (scan.assets.contains { $0.kind == .video } && !scan.assets.contains { $0.kind == .mesh } ? .video : .mesh), capturedAt: scan.createdAt,
                endedAt: endedAt, frameID: scan.frameID, geoTag: scan.geoTag), captureOperator: author))
        }
        let evidence = captures.appendingPathComponent("evidence", isDirectory: true)
        if FileManager.default.fileExists(atPath: evidence.path) {
            for file in try FileManager.default.contentsOfDirectory(at: evidence, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                let relative = prefix + "evidence/" + file.lastPathComponent
                let safe = try FieldTransferPaths.resolve(relativePath: relative, root: managed)
                guard try fileSize(safe) <= 2 * 1_024 * 1_024 else { throw FieldTransportError.tooLarge }
                let photo = try decoder.decode(PhotoMetadata.self, from: Data(contentsOf: safe))
                guard photo.projectID == projectID else { throw AtlasExportError.entityProjectMismatch }
                materialValues.append(.init(source: FieldMaterial(id: photo.id, sourceEntityID: photo.id,
                    kind: .photo, capturedAt: photo.capturedAt,
                    importedAt: photo.source == "photoLibrary" ? photo.createdAt : nil,
                    frameID: photo.cameraFrameID, geoTag: photo.geoTag), captureOperator: photo.captureOperator))
                references[relative] = (photo.id, .metadata)
                references[prefix + photo.relativePath] = (photo.id, .originalPhoto)
            }
        }
        for feature in snapshot.features { materialValues.append(.init(source: FieldMaterial(id: feature.id, sourceEntityID: feature.id, kind: .feature), captureOperator: nil)) }
        for plan in snapshot.floorPlans { materialValues.append(.init(source: FieldMaterial(id: plan.id, sourceEntityID: plan.id, kind: .floorPlan, frameID: plan.frameID), captureOperator: nil)) }
        for measurement in snapshot.measurements ?? [] { materialValues.append(.init(source: FieldMaterial(id: measurement.id, sourceEntityID: measurement.id, kind: .measurement, capturedAt: measurement.createdAt, frameID: measurement.frameID), captureOperator: nil)) }
        let projectData = try AtlasExporter.export(snapshot, format: .projectJSON).data
        var assets = [FieldAsset(id: stableID("archive:project:" + projectID.uuidString), materialID: projectID,
            relativePath: "project.json", mediaType: "application/json", byteCount: Int64(projectData.count),
            sha256: FieldTransferDigest.sha256(projectData), kind: .projectSnapshot)]
        if let enumerator = FileManager.default.enumerator(at: captures,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator {
                try Task.checkCancellation()
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw FieldTransferError.invalidAssetPath(file.lastPathComponent) }
                guard values.isRegularFile == true else { continue }
                let relative = String(file.standardizedFileURL.path.dropFirst(managed.path.count + 1))
                guard relative.hasPrefix(prefix) else { throw FieldTransferError.invalidAssetPath(relative) }
                let safe = try FieldTransferPaths.resolve(relativePath: relative, root: managed)
                let mapping = references[relative] ?? (projectID, .other)
                assets.append(FieldAsset(id: stableID("archive:" + relative), materialID: mapping.0,
                    relativePath: "Captures/" + String(relative.dropFirst(prefix.count)), mediaType: mediaType(safe),
                    byteCount: try fileSize(safe), sha256: try FieldTransferDigest.sha256(fileURL: safe), kind: mapping.1))
                guard assets.count <= 50_000 else { throw FieldTransportError.tooLarge }
            }
        }
        materialValues.sort { $0.source.id.uuidString < $1.source.id.uuidString }
        assets.sort { $0.relativePath < $1.relativePath }
        let passport = FieldDeliveryPassport(projectID: projectID, projectName: snapshot.project.name,
            preparedAt: Date(), timeZoneIdentifier: TimeZone.current.identifier,
            utcOffsetSeconds: TimeZone.current.secondsFromGMT(), device: device, preparedBy: preparedBy,
            materials: materialValues, assets: assets,
            notes: ["preparedAt and the package time zone describe archive preparation, not capture time.",
                "An absent captureOperator or capturedAt means the original source did not record it.",
                "Geotags retain observations, accuracy and correction history; GPS does not georeference a local AR frame.",
                "Original photo files keep their EXIF metadata. Asset hashes address exact archive members."])
        return try FieldTransferJSON.encode(passport, pretty: true)
    }

    func snapshot(for manifest: FieldTransferManifest) throws -> AtlasProjectSnapshot {
        guard let asset = manifest.assets.first(where: { $0.kind == .projectSnapshot }) else { throw FieldTransportError.invalidResponse }
        return try FieldTransferJSON.decode(AtlasProjectSnapshot.self, from: Data(contentsOf: blobURL(asset.sha256)))
    }
    func readChunk(asset: FieldAsset, offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length > 0, length <= FieldTransferTransport.maximumChunk,
              offset < asset.byteCount else { throw FieldTransportError.invalidResponse }
        let handle = try FileHandle(forReadingFrom: blobURL(asset.sha256)); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: min(length, Int(asset.byteCount - offset))) ?? Data()
        guard !data.isEmpty else { throw FieldTransportError.alteredOriginal }
        return data
    }
    func verify(asset: FieldAsset) throws {
        let url = blobURL(asset.sha256)
        guard try fileSize(url) == asset.byteCount,
              try FieldTransferDigest.sha256(fileURL: url) == asset.sha256 else { throw FieldTransportError.alteredOriginal }
    }
    func downloadOffset(asset: FieldAsset, packageID: UUID, scope: FieldTransferScope) throws -> Int64 {
        let url = try downloadFile(asset: asset, packageID: packageID, scope: scope)
        if FileManager.default.fileExists(atPath: url.path) {
            let size = try fileSize(url)
            guard size <= asset.byteCount else { throw FieldTransportError.alteredOriginal }
            return size
        }
        return 0
    }
    func appendDownload(_ data: Data, asset: FieldAsset, packageID: UUID, scope: FieldTransferScope, offset: Int64) throws {
        let file = try downloadFile(asset: asset, packageID: packageID, scope: scope)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { try protectedWrite(Data(), to: file) }
        guard try fileSize(file) == offset else { throw FieldTransportError.alteredOriginal }
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
    }
    func completeDownload(asset: FieldAsset, packageID: UUID, scope: FieldTransferScope) throws {
        let file = try downloadFile(asset: asset, packageID: packageID, scope: scope)
        guard try fileSize(file) == asset.byteCount,
              try FieldTransferDigest.sha256(fileURL: file) == asset.sha256 else {
            // A corrupt temporary download can be retried without touching any
            // live original or a previously verified download.
            try? FileManager.default.removeItem(at: file)
            throw FieldTransportError.alteredOriginal
        }
    }
    func downloaded(material: RemoteFieldMaterial, scope: FieldTransferScope) throws -> DownloadedFieldMaterial {
        guard let asset = material.manifest.assets.first(where: { $0.kind == .projectSnapshot }) else { throw FieldTransportError.invalidResponse }
        let file = try downloadFile(asset: asset, packageID: material.captureID, scope: scope)
        let snapshot = try FieldTransferJSON.decode(AtlasProjectSnapshot.self, from: Data(contentsOf: file))
        guard snapshot.project.id == material.projectID else { throw FieldTransportError.invalidResponse }
        let directory = root.appendingPathComponent("downloads/" + scope.key + "/" + material.captureID.uuidString, isDirectory: true)
        try protectedWrite(FieldTransferJSON.encode(material), to: directory.appendingPathComponent("transfer-receipt.json"))
        return DownloadedFieldMaterial(material: material, directory: directory, snapshot: snapshot)
    }

    private func downloadFile(asset: FieldAsset, packageID: UUID, scope: FieldTransferScope) throws -> URL {
        let directory = root.appendingPathComponent("downloads/" + scope.key + "/" + packageID.uuidString, isDirectory: true)
        return try FieldTransferPaths.resolve(relativePath: asset.relativePath, root: directory)
    }
    private func blobURL(_ digest: String) -> URL { blobs.appendingPathComponent(digest) }
    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw FieldTransportError.alteredOriginal }
        return Int64(values.fileSize ?? 0)
    }
    private func storeFile(_ file: URL) throws -> (size: Int64, sha256: String) {
        let size = try fileSize(file)
        guard size <= 512 * 1_024 * 1_024 else { throw FieldTransportError.tooLarge }
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let digest: String
        if let cached = hashCache[file.path], cached.size == size, cached.modified == modified {
            digest = cached.digest
        } else {
            digest = try FieldTransferDigest.sha256(fileURL: file)
            hashCache[file.path] = CachedDigest(size: size, modified: modified, digest: digest)
        }
        let destination = blobURL(digest)
        if !FileManager.default.fileExists(atPath: destination.path) {
            #if os(iOS)
            let capacity = try blobs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            guard (capacity.volumeAvailableCapacityForImportantUsage ?? 0) > size + 256 * 1_024 * 1_024 else {
                throw TeamError.rejected("Недостаточно места для безопасной подготовки отправки. Исходники сохранены на iPhone.")
            }
            #endif
            let temporary = blobs.appendingPathComponent("." + UUID().uuidString + ".partial")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let source = try FileHandle(forReadingFrom: file); defer { try? source.close() }
            try protectedWrite(Data(), to: temporary)
            let output = try FileHandle(forWritingTo: temporary); defer { try? output.close() }
            while let data = try source.read(upToCount: 65_536), !data.isEmpty {
                try Task.checkCancellation(); try output.write(contentsOf: data)
            }
            try output.synchronize()
            guard try fileSize(temporary) == size,
                  try FieldTransferDigest.sha256(fileURL: temporary) == digest else { throw FieldTransportError.alteredOriginal }
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return (size, digest)
    }
    private func saveBlob(_ data: Data, sha256: String) throws {
        let destination = blobURL(sha256)
        if !FileManager.default.fileExists(atPath: destination.path) { try protectedWrite(data, to: destination) }
    }
    private func protectedWrite(_ data: Data, to file: URL) throws {
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }
    private func stableID(_ text: String) -> UUID {
        let digest = FieldTransferDigest.sha256(Data(text.utf8))
        let hex = Array(digest.prefix(32)); var bytes: [UInt8] = []
        for index in stride(from: 0, to: hex.count, by: 2) {
            bytes.append(UInt8(String(hex[index...index + 1]), radix: 16) ?? 0)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private func mediaType(_ file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "heic", "heif": "image/heic"
        case "png": "image/png"
        case "json": "application/json"
        case "obj": "model/obj"
        case "usdz": "model/vnd.usdz+zip"
        case "mov": "video/quicktime"
        case "mp4": "video/mp4"
        case "pdf": "application/pdf"
        default: "application/octet-stream"
        }
    }
}
