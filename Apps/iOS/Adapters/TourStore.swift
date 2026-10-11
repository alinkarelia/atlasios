import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import AtlasCore

enum TourProjection: String, Codable, CaseIterable, Sendable { case photograph, equirectangular360 }

struct TourImagePoint: Codable, Hashable, Sendable { var x: Double; var y: Double }
enum TourAnnotationKind: String, Codable, CaseIterable, Sendable { case polygon, polyline, point }
struct TourAnnotation: Identifiable, Codable, Sendable {
    var id = UUID()
    var featureID: UUID
    var vertices: [TourImagePoint]
    var kind: TourAnnotationKind = .polygon
    var source = "operatorDrawnOnOriginalPhoto"
    var createdAt = Date()
}

struct TourStation: Identifiable, Codable, Sendable {
    var id: UUID
    var photoID: UUID
    var originalRelativePath: String
    var originalSHA256: String
    var name: String
    var comment: String
    var addedAt: Date
    var capturedAt: Date?
    var importedAt: Date
    var pixelWidth: Int
    var pixelHeight: Int
    var geoTag: GeoTag?
    var sourceGeoMetadata: PhotoSourceGeoMetadata?
    var cameraFrameID: UUID?
    var cameraTransform: [Float]?
    var projection: TourProjection
    var projectionConfirmedAt: Date?
    var annotations: [TourAnnotation]
    var videoFrameProvenance: VideoFrameProvenance?

    init(photo: PhotoEvidence, number: Int) {
        id = UUID(); photoID = photo.id; originalRelativePath = photo.relativePath; originalSHA256 = photo.sha256
        name = "Точка \(number)"; comment = ""; addedAt = Date(); capturedAt = photo.capturedAt; importedAt = photo.createdAt
        pixelWidth = photo.pixelWidth; pixelHeight = photo.pixelHeight; geoTag = photo.geoTag; sourceGeoMetadata = photo.sourceGeoMetadata
        cameraFrameID = photo.cameraFrameID; cameraTransform = photo.cameraTransform; projection = .photograph; projectionConfirmedAt = nil
        annotations = []
        videoFrameProvenance = photo.videoFrameProvenance
    }
    var coordinate: GeographicCoordinate? { geoTag?.effectiveFix?.coordinate ?? sourceGeoMetadata?.coordinate }
}

struct TourManifest: Identifiable, Codable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var projectID: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var stations: [TourStation]
    init(projectID: UUID, title: String) {
        id = UUID(); self.projectID = projectID; self.title = title; createdAt = Date(); updatedAt = Date(); stations = []
    }
}

enum TourError: LocalizedError { case invalidManifest, panoramaNeedsConfirmation, sourceMissing, manifestTooLarge
    var errorDescription: String? {
        switch self {
        case .invalidManifest: "Некорректный маршрут или ссылка на исходное фото."
        case .panoramaNeedsConfirmation: "Режим 360° доступен только для подтверждённой полной эквидистантной панорамы 2:1. Обычный снимок остаётся обычным снимком."
        case .sourceMissing: "Исходная фотография точки недоступна. Верните оригинал в проект или выберите другое фото."
        case .manifestTooLarge: "Маршрут превышает 32 МБ. Разделите его на несколько маршрутов. Предыдущее сохранение осталось без изменений."
        }
    }
}

enum TourPolicy {
    static func supportsPanorama(width: Int, height: Int, explicitlyConfirmed: Bool) -> Bool {
        explicitlyConfirmed && width >= 512 && width <= 65_536 && height >= 256 && height <= 32_768 && width == height*2
    }
    /// Image coordinates have no ground units or automatic geographic meaning.
    static func validContour(_ points: [TourImagePoint]) -> Bool {
        guard points.count >= 3, points.count <= 64,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              Set(points).count == points.count else { return false }
        var twiceArea = 0.0
        for index in points.indices {
            let next = (index+1)%points.count
            twiceArea += points[index].x*points[next].y-points[next].x*points[index].y
            let dx = points[index].x-points[next].x, dy = points[index].y-points[next].y
            if dx*dx+dy*dy < 0.000001 { return false }
        }
        guard abs(twiceArea) > 0.00002 else { return false }
        for first in points.indices {
            let second = (first+1)%points.count
            for third in points.indices where third > first {
                let fourth = (third+1)%points.count
                if second == third || fourth == first { continue }
                if intersects(points[first],points[second],points[third],points[fourth]) { return false }
            }
        }
        return true
    }
    static func contains(_ point: TourImagePoint, contour: [TourImagePoint]) -> Bool {
        guard validContour(contour),point.x.isFinite,point.y.isFinite else { return false }
        var inside = false
        for index in contour.indices {
            let a = contour[index], b = contour[(index+1)%contour.count]
            if abs(cross(a,b,point)) < 1e-9 && onSegment(point,a,b) { return true }
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x-a.x)*(point.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
        }
        return inside
    }
    static func validAnnotation(_ annotation: TourAnnotation) -> Bool {
        let points = annotation.vertices
        guard points.count <= 64,points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        switch annotation.kind {
        case .polygon: return validContour(points)
        case .point: return points.count == 1
        case .polyline:
            guard points.count >= 2 else { return false }
            for index in 1..<points.count {
                let dx = points[index].x-points[index-1].x,dy = points[index].y-points[index-1].y
                if dx*dx+dy*dy < 0.000001 { return false }
            }
            return true
        }
    }
    static func hit(_ point: TourImagePoint, annotation: TourAnnotation, tolerance: Double = 0.018) -> Bool {
        guard validAnnotation(annotation),point.x.isFinite,point.y.isFinite,tolerance.isFinite,tolerance >= 0 else { return false }
        if annotation.kind == .polygon { return contains(point,contour:annotation.vertices) }
        if annotation.kind == .point {
            let dx = point.x-annotation.vertices[0].x,dy = point.y-annotation.vertices[0].y
            return dx*dx+dy*dy <= tolerance*tolerance
        }
        for index in 1..<annotation.vertices.count {
            let a = annotation.vertices[index-1], b = annotation.vertices[index]
            let dx = b.x-a.x,dy = b.y-a.y
            let projection = max(0,min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/(dx*dx+dy*dy)))
            let offsetX = point.x-(a.x+projection*dx),offsetY = point.y-(a.y+projection*dy)
            if offsetX*offsetX+offsetY*offsetY <= tolerance*tolerance { return true }
        }
        return false
    }
    static func imageRect(imageWidth: Double, imageHeight: Double, container: CGRect) -> CGRect {
        guard imageWidth.isFinite,imageHeight.isFinite,imageWidth > 0,imageHeight > 0,container.origin.x.isFinite,container.origin.y.isFinite,container.width.isFinite,container.height.isFinite,container.width > 0,container.height > 0 else { return .zero }
        let scale = min(container.width/imageWidth,container.height/imageHeight)
        let width = imageWidth*scale, height = imageHeight*scale
        return CGRect(x:container.midX-width/2,y:container.midY-height/2,width:width,height:height)
    }
    static func normalized(_ location: CGPoint, imageRect: CGRect) -> TourImagePoint? {
        guard location.x.isFinite,location.y.isFinite,imageRect.origin.x.isFinite,imageRect.origin.y.isFinite,imageRect.width.isFinite,imageRect.height.isFinite,imageRect.width > 0,imageRect.height > 0,imageRect.contains(location) else { return nil }
        return TourImagePoint(x:(location.x-imageRect.minX)/imageRect.width,y:(location.y-imageRect.minY)/imageRect.height)
    }
    private static func cross(_ a: TourImagePoint,_ b: TourImagePoint,_ c: TourImagePoint) -> Double { (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) }
    private static func onSegment(_ p: TourImagePoint,_ a: TourImagePoint,_ b: TourImagePoint) -> Bool {
        p.x >= min(a.x,b.x)-1e-9 && p.x <= max(a.x,b.x)+1e-9 && p.y >= min(a.y,b.y)-1e-9 && p.y <= max(a.y,b.y)+1e-9
    }
    private static func intersects(_ a: TourImagePoint,_ b: TourImagePoint,_ c: TourImagePoint,_ d: TourImagePoint) -> Bool {
        let abC = cross(a,b,c),abD = cross(a,b,d),cdA = cross(c,d,a),cdB = cross(c,d,b)
        if ((abC > 0 && abD < 0)||(abC < 0 && abD > 0)) && ((cdA > 0 && cdB < 0)||(cdA < 0 && cdB > 0)) { return true }
        return (abs(abC)<1e-9 && onSegment(c,a,b)) || (abs(abD)<1e-9 && onSegment(d,a,b)) || (abs(cdA)<1e-9 && onSegment(a,c,d)) || (abs(cdB)<1e-9 && onSegment(b,c,d))
    }
    static func validate(_ tour: TourManifest, projectID: UUID) throws {
        guard tour.schemaVersion == 1, tour.projectID == projectID, tour.stations.count <= 500,
              !tour.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, tour.title.count <= 250,
              Set(tour.stations.map(\.id)).count == tour.stations.count else { throw TourError.invalidManifest }
        for station in tour.stations {
            guard station.name.count <= 250, station.comment.count <= 10_000,
                  station.originalRelativePath.hasPrefix("evidence/\(station.photoID.uuidString)."),
                  !station.originalRelativePath.contains(".."), !station.originalRelativePath.contains("\\"),
                  station.originalRelativePath.split(separator:"/").count == 2,
                  station.originalSHA256.count == 64, station.originalSHA256.allSatisfy({ $0.isHexDigit }),
                  station.cameraTransform == nil || (station.cameraFrameID != nil && station.cameraTransform?.count == 16 && station.cameraTransform!.allSatisfy(\.isFinite)),
                  station.annotations.count <= 200,Set(station.annotations.map(\.id)).count == station.annotations.count,
                  station.annotations.allSatisfy({ $0.source == "operatorDrawnOnOriginalPhoto" && validAnnotation($0) }),
                  station.videoFrameProvenance == nil || (station.videoFrameProvenance!.isValid && station.cameraFrameID == station.videoFrameProvenance!.frameID) else { throw TourError.invalidManifest }
            if station.projection == .equirectangular360,
               !supportsPanorama(width:station.pixelWidth,height:station.pixelHeight,explicitlyConfirmed:station.projectionConfirmedAt != nil) { throw TourError.panoramaNeedsConfirmation }
        }
    }
}

actor TourStore {
    static let maximumManifestBytes = 32 * 1_024 * 1_024
    func load(projectID: UUID, directory: URL) throws -> [TourManifest] {
        let folder = directory.appendingPathComponent("Tours",isDirectory:true)
        guard FileManager.default.fileExists(atPath:folder.path) else { return [] }
        guard safe(folder,inside:directory) else { throw TourError.invalidManifest }
        let files = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.fileSizeKey,.isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasSuffix(".tour.json") }
        guard files.count <= 100 else { throw TourError.invalidManifest }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try files.map { file in
            guard safe(file,inside:directory),let bytes = try file.resourceValues(forKeys:[.fileSizeKey]).fileSize,bytes > 0 else { throw TourError.invalidManifest }
            guard bytes <= Self.maximumManifestBytes else { throw TourError.manifestTooLarge }
            let result = try decoder.decode(TourManifest.self,from:Data(contentsOf:file))
            try TourPolicy.validate(result,projectID:projectID)
            guard file.lastPathComponent == "\(result.id.uuidString).tour.json" else { throw TourError.invalidManifest }
            return result
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func save(_ tour: TourManifest, directory: URL, projectID: UUID) throws -> URL {
        try TourPolicy.validate(tour,projectID:projectID)
        let folder = directory.appendingPathComponent("Tours",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        guard safe(folder,inside:directory) else { throw TourError.invalidManifest }
        let url = folder.appendingPathComponent("\(tour.id.uuidString).tour.json")
        guard safe(url,inside:directory) else { throw TourError.invalidManifest }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(tour)
        guard data.count <= Self.maximumManifestBytes else { throw TourError.manifestTooLarge }
        try data.write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        return url
    }
    private func safe(_ url: URL, inside root: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path+"/") &&
            url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path+"/") &&
            (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true
    }
}
