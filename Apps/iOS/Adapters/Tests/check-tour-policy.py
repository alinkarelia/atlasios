#!/usr/bin/env python3
"""Compile production tour policy/types and run annotation/provenance checks.

The harness extracts actual Foundation-only evidence/Core value types. No tour,
point-in-polygon, aspect-fit or panorama algorithm is reimplemented here. On
Linux only the unavailable Apple file-protection write option is omitted; the
production atomic save/load and path-validation logic still run.
"""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
SOURCE = ROOT / "Apps/iOS/Adapters/TourStore.swift"
production = SOURCE.read_text().replace("import AtlasCore\n", "")
video_document = (ROOT / "Apps/iOS/Adapters/CaptureVideoDocument.swift").read_text()
video_policy = (ROOT / "Apps/iOS/Adapters/VideoTourPolicy.swift").read_text()
domain = (ROOT / "Packages/AtlasCore/Sources/AtlasCore/Domain.swift").read_text()
coordinate = domain[domain.index("public struct GeographicCoordinate:"):domain.index("/// Rings are stored")]
geo_source = (ROOT / "Packages/AtlasCore/Sources/AtlasCore/GeoTag.swift").read_text()
geo = geo_source[geo_source.index("public enum GeoFixSource:"):geo_source.index("public enum GeoTagError:")]
photo_source = (ROOT / "Apps/iOS/Adapters/EvidenceService.swift").read_text()
photos = photo_source[photo_source.index("struct PhotoEvidence:"):photo_source.index("/// Evidence is kept locally.")]
metadata_source = (ROOT / "Apps/iOS/Adapters/PhotoGeoMetadata.swift").read_text()
timestamp = metadata_source[metadata_source.index("enum PhotoGeoTimestampBasis:"):metadata_source.index("struct PhotoGeoObservation:")]
if platform.system() == "Darwin":
    compiler = ["xcrun", "swiftc"]
else:
    swiftc = os.environ.get("ATLAS_SWIFTC") or shutil.which("swiftc")
    if not swiftc:
        raise SystemExit("Swift 6 compiler required; set ATLAS_SWIFTC to its path.")
    compiler = [swiftc]
    production = production.replace("[.atomic,.completeFileProtectionUntilFirstUserAuthentication]", "[.atomic]")

TESTS = r'''
@main struct Checks {
    static func main() async throws {
        var count = 0
        func expect(_ result: Bool, _ title: String) {
            guard result else { fatalError("Tour policy regression: \(title)") }
            count += 1
        }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a-b) < 0.00000001 }
        func point(_ x: Double, _ y: Double) -> TourImagePoint { TourImagePoint(x:x,y:y) }
        let rectangle = [point(0.1,0.1),point(0.9,0.1),point(0.9,0.9),point(0.1,0.9)]
        expect(TourPolicy.validContour(rectangle), "a normalized operator-drawn grave contour is accepted")
        expect(TourPolicy.validContour(Array(rectangle.reversed())), "both contour windings are accepted")
        expect(!TourPolicy.validContour([point(0.1,0.1),point(0.9,0.9),point(0.9,0.1),point(0.1,0.9)]),
               "a self-crossing bow-tie cannot identify a grave")
        expect(!TourPolicy.validContour([point(0.1,0.1),point(0.9,0.1),point(0.9,0.9),point(0.5,0.1),point(0.1,0.9)]),
               "a nonadjacent edge touching another contour edge is rejected")
        expect(!TourPolicy.validContour([point(0.1,0.1),point(0.5,0.5),point(0.9,0.9)]),
               "a collinear contour has no usable area")
        expect(!TourPolicy.validContour(rectangle+[rectangle[0]]), "a repeated closing vertex is rejected")
        expect(!TourPolicy.validContour([rectangle[0],rectangle[1],rectangle[1],rectangle[2],rectangle[3]]),
               "a repeated interior vertex is rejected")
        expect(!TourPolicy.validContour([point(-0.01,0.1),point(0.9,0.1),point(0.9,0.9)])
               && !TourPolicy.validContour([point(0.1,0.1),point(1.01,0.1),point(0.9,0.9)]),
               "image contours cannot extend into letterbox margins")
        expect(!TourPolicy.validContour([point(.nan,0.1),point(0.9,0.1),point(0.9,0.9)])
               && !TourPolicy.validContour([point(0.1,.infinity),point(0.9,0.1),point(0.9,0.9)]),
               "nonfinite normalized vertices are rejected")
        expect(!TourPolicy.validContour([point(0.1,0.1),point(0.1001,0.1),point(0.9,0.9)]),
               "almost coincident contour points are rejected")
        expect(!TourPolicy.validContour(Array(rectangle.prefix(2))), "a contour requires at least three vertices")
        let circle: [TourImagePoint] = (0..<64).map {
            let angle = Double($0) * 2 * Double.pi / 64
            return point(0.5+cos(angle)*0.4,0.5+sin(angle)*0.4)
        }
        expect(TourPolicy.validContour(circle), "a valid 64-vertex contour is permitted")
        let tooMany: [TourImagePoint] = (0..<65).map {
            let angle = Double($0) * 2 * Double.pi / 65
            return point(0.5+cos(angle)*0.4,0.5+sin(angle)*0.4)
        }
        expect(!TourPolicy.validContour(tooMany), "the 64-vertex operator contour limit is enforced")
        expect(TourPolicy.contains(point(0.5,0.5),contour:rectangle), "tapping inside a grave selects its contour")
        expect(TourPolicy.contains(point(0.1,0.5),contour:rectangle), "tapping an actual contour edge still selects it")
        expect(!TourPolicy.contains(point(0.05,0.5),contour:rectangle), "nearby background never selects a grave")
        expect(!TourPolicy.contains(point(.nan,0.5),contour:rectangle), "nonfinite taps are rejected")
        let concave = [point(0.1,0.1),point(0.9,0.1),point(0.9,0.4),point(0.4,0.4),point(0.4,0.9),point(0.1,0.9)]
        expect(TourPolicy.validContour(concave) && TourPolicy.contains(point(0.2,0.8),contour:concave)
               && !TourPolicy.contains(point(0.8,0.8),contour:concave),
               "concave contours select their actual area rather than the bounding rectangle")

        let annotationFeature = UUID()
        let polygon = TourAnnotation(featureID:annotationFeature,vertices:rectangle,kind:.polygon)
        let openRoad = TourAnnotation(featureID:annotationFeature,vertices:[point(0.1,0.1),point(0.9,0.1),point(0.9,0.9)],kind:.polyline)
        let marker = TourAnnotation(featureID:annotationFeature,vertices:[point(0.5,0.5)],kind:.point)
        expect(TourPolicy.validAnnotation(polygon), "grave polygons use the validated closed-contour policy")
        expect(!TourPolicy.validAnnotation(TourAnnotation(featureID:annotationFeature,vertices:[point(0.1,0.1),point(0.9,0.9)],kind:.polygon)),
               "polygon annotations need at least three valid vertices")
        expect(TourPolicy.validAnnotation(marker), "a one-position tree or object marker is supported")
        expect(!TourPolicy.validAnnotation(TourAnnotation(featureID:annotationFeature,vertices:[],kind:.point))
               && !TourPolicy.validAnnotation(TourAnnotation(featureID:annotationFeature,vertices:rectangle,kind:.point)),
               "point markers require exactly one original-photo position")
        expect(TourPolicy.validAnnotation(openRoad), "open paths and fences are valid without being closed into polygons")
        expect(TourPolicy.validAnnotation(TourAnnotation(featureID:annotationFeature,vertices:[point(0.1,0.1),point(0.9,0.9)],kind:.polyline)),
               "two distinct endpoints are enough for a road annotation")
        expect(!TourPolicy.validAnnotation(TourAnnotation(featureID:annotationFeature,vertices:[point(0.1,0.1)],kind:.polyline)),
               "a road requires at least two positions")
        expect(!TourPolicy.validAnnotation(TourAnnotation(featureID:annotationFeature,vertices:[point(0.1,0.1),point(0.1,0.1),point(0.9,0.9)],kind:.polyline))
               && !TourPolicy.validAnnotation(TourAnnotation(featureID:annotationFeature,vertices:[point(0.1,0.1),point(0.1001,0.1)],kind:.polyline)),
               "coincident and almost coincident adjacent road endpoints are rejected")
        expect(TourPolicy.validAnnotation(TourAnnotation(featureID:annotationFeature,vertices:circle,kind:.polyline))
               && !TourPolicy.validAnnotation(TourAnnotation(featureID:annotationFeature,vertices:tooMany,kind:.polyline)),
               "the 64-vertex cap also bounds open road annotations")
        expect(!TourPolicy.validAnnotation(TourAnnotation(featureID:annotationFeature,vertices:[point(.nan,0.5)],kind:.point))
               && !TourPolicy.validAnnotation(TourAnnotation(featureID:annotationFeature,vertices:[point(0.1,0.1),point(.infinity,0.9)],kind:.polyline)),
               "every annotation kind rejects nonfinite coordinates")
        expect(!TourPolicy.validAnnotation(TourAnnotation(featureID:annotationFeature,vertices:[point(-0.1,0.5)],kind:.point))
               && !TourPolicy.validAnnotation(TourAnnotation(featureID:annotationFeature,vertices:[point(0.1,0.1),point(0.9,1.1)],kind:.polyline)),
               "point and road coordinates stay inside the original photograph")
        expect(TourPolicy.hit(point(0.1,0.1),annotation:openRoad,tolerance:0), "an exact road endpoint can be selected")
        expect(TourPolicy.hit(point(0.5,0.11),annotation:openRoad), "a nearby tap selects the actual road segment")
        expect(!TourPolicy.hit(point(0.5,0.14),annotation:openRoad), "a tap outside road tolerance does not select it")
        expect(TourPolicy.hit(point(0.09,0.1),annotation:openRoad)
               && !TourPolicy.hit(point(0.07,0.1),annotation:openRoad),
               "road endpoint tolerance uses endpoint distance instead of an unbounded line")
        expect(!TourPolicy.hit(point(0.5,0.5),annotation:openRoad),
               "an open road never gains an imaginary closing segment between its last and first positions")
        expect(TourPolicy.hit(point(0.51,0.5),annotation:marker) && !TourPolicy.hit(point(0.53,0.5),annotation:marker),
               "object markers use their bounded selection radius")
        expect(TourPolicy.hit(point(0.5,0.5),annotation:marker,tolerance:0)
               && !TourPolicy.hit(point(0.5001,0.5),annotation:marker,tolerance:0),
               "zero marker tolerance permits only the exact source position")
        expect(TourPolicy.hit(point(0.5,0.5),annotation:polygon)
               && !TourPolicy.hit(point(0.05,0.5),annotation:polygon,tolerance:0.1),
               "polygon hits use their actual interior instead of expanding grave borders with line tolerance")
        expect(!TourPolicy.hit(point(.nan,0.5),annotation:marker)
               && !TourPolicy.hit(point(0.5,0.5),annotation:marker,tolerance:-1)
               && !TourPolicy.hit(point(0.5,0.5),annotation:openRoad,tolerance:.infinity),
               "invalid taps or hit tolerances cannot select annotations")

        let container = CGRect(x:10,y:20,width:400,height:600)
        let imageRect = TourPolicy.imageRect(imageWidth:4000,imageHeight:2000,container:container)
        expect(imageRect == CGRect(x:10,y:220,width:400,height:200), "wide photos retain their exact aspect-fit rectangle")
        let center = TourPolicy.normalized(CGPoint(x:210,y:320),imageRect:imageRect)
        expect(center?.x == 0.5 && center?.y == 0.5, "screen taps map to normalized original-photo coordinates")
        let quarter = TourPolicy.normalized(CGPoint(x:110,y:270),imageRect:imageRect)
        expect(quarter?.x == 0.25 && quarter?.y == 0.25, "known photo locations map without using container dimensions")
        expect(TourPolicy.normalized(CGPoint(x:210,y:100),imageRect:imageRect) == nil,
               "top letterbox margins cannot create image annotations")
        expect(TourPolicy.normalized(CGPoint(x:210,y:500),imageRect:imageRect) == nil,
               "bottom letterbox margins cannot create image annotations")
        let portraitRect = TourPolicy.imageRect(imageWidth:1000,imageHeight:2000,container:container)
        expect(portraitRect == CGRect(x:60,y:20,width:300,height:600), "portrait photos preserve left and right margins")
        expect(TourPolicy.normalized(CGPoint(x:20,y:320),imageRect:portraitRect) == nil,
               "side margins cannot create image annotations")
        expect(TourPolicy.imageRect(imageWidth:0,imageHeight:2000,container:container) == .zero
               && TourPolicy.imageRect(imageWidth:.nan,imageHeight:2000,container:container) == .zero,
               "invalid photo dimensions have no drawable rectangle")
        expect(TourPolicy.imageRect(imageWidth:4000,imageHeight:2000,container:CGRect(x:Double.nan,y:20,width:400,height:600)) == .zero
               && TourPolicy.imageRect(imageWidth:4000,imageHeight:2000,container:CGRect(x:10,y:20,width:Double.infinity,height:600)) == .zero,
               "nonfinite view origins and dimensions have no drawable photo rectangle")
        expect(TourPolicy.normalized(CGPoint(x:10,y:20),imageRect:.zero) == nil,
               "unloaded photos cannot receive normalized taps")
        expect(TourPolicy.normalized(CGPoint(x:Double.nan,y:320),imageRect:imageRect) == nil
               && TourPolicy.normalized(CGPoint(x:210,y:320),imageRect:CGRect(x:Double.infinity,y:220,width:400,height:200)) == nil,
               "nonfinite taps and rectangles cannot produce normalized image positions")

        expect(!TourPolicy.supportsPanorama(width:4000,height:2000,explicitlyConfirmed:false),
               "a 2:1 aspect ratio alone never turns a normal photograph into a panorama")
        expect(TourPolicy.supportsPanorama(width:4000,height:2000,explicitlyConfirmed:true),
               "an explicitly confirmed full 2:1 panorama can use 360 viewing")
        expect(!TourPolicy.supportsPanorama(width:4032,height:3024,explicitlyConfirmed:true),
               "an ordinary confirmed photo still cannot use spherical projection")
        expect(!TourPolicy.supportsPanorama(width:256,height:128,explicitlyConfirmed:true)
               && !TourPolicy.supportsPanorama(width:Int.max,height:Int.max,explicitlyConfirmed:true),
               "tiny and out-of-range panorama dimensions are rejected without overflow")
        expect(TourPolicy.supportsPanorama(width:512,height:256,explicitlyConfirmed:true)
               && TourPolicy.supportsPanorama(width:65536,height:32768,explicitlyConfirmed:true),
               "documented panorama resolution boundaries remain valid")

        let projectID = UUID(), photoID = UUID(), frameID = UUID(), featureID = UUID()
        let importedAt = Date(timeIntervalSince1970:1_765_432_100)
        let capturedAt = Date(timeIntervalSince1970:1_600_000_000)
        let coordinate = GeographicCoordinate(longitude:33.1234,latitude:61.9876)
        let fix = GeoLocationFix(coordinate:coordinate,observedAt:capturedAt,source:.photoEXIF)
        let originalSHA = String(repeating:"0123456789abcdef",count:4)
        let identity: [Float] = [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
        let photo = PhotoEvidence(id:photoID,projectID:projectID,createdAt:importedAt,
            relativePath:"evidence/\(photoID.uuidString).jpg",metadataPath:"evidence/\(photoID.uuidString).json",
            source:"photoLibrary",byteCount:12345,sha256:originalSHA,pixelWidth:4000,pixelHeight:2000,
            cameraTransform:identity,cameraFrameID:frameID,ocr:nil,recognitionIssue:nil,
            geoTag:GeoTag(automaticFix:fix),capturedAt:capturedAt,geoTimestampBasis:.gpsUTC,
            sourceGeoMetadata:PhotoSourceGeoMetadata(coordinate:coordinate,altitudeMeters:nil,horizontalAccuracyMeters:nil,
                                                   capturedAt:capturedAt,timestampBasis:.gpsUTC))
        var station = TourStation(photo:photo,number:1)
        expect(station.photoID == photo.id && station.originalRelativePath == photo.relativePath
               && station.originalSHA256 == originalSHA, "adding a tour station preserves exact original photo identity/path/SHA")
        expect(station.capturedAt == capturedAt && station.importedAt == importedAt,
               "tour creation preserves capture time separately from later import time")
        expect(station.cameraFrameID == frameID && station.cameraTransform == identity && station.coordinate == coordinate,
               "tour stations preserve original camera frame and geographic observation")
        expect(station.projection == .photograph && station.projectionConfirmedAt == nil && station.annotations.isEmpty,
               "new stations begin as ordinary unannotated photographs")
        station.annotations = [TourAnnotation(featureID:featureID,vertices:rectangle),
                               TourAnnotation(featureID:featureID,vertices:openRoad.vertices,kind:.polyline),
                               TourAnnotation(featureID:featureID,vertices:marker.vertices,kind:.point)]
        var tour = TourManifest(projectID:projectID,title:"Кладбище — маршрут оператора")
        tour.stations = [station]
        func rejects(_ value: TourManifest, expectedProject: UUID? = nil) -> Bool {
            do { try TourPolicy.validate(value,projectID:expectedProject ?? projectID); return false }
            catch { return true }
        }
        expect(!rejects(tour), "a station with a valid explicit grave-photo linkage passes manifest validation")
        let captureID = UUID(),segmentID = UUID()
        let provenance = VideoFrameProvenance(captureID:captureID,segmentID:segmentID,frameID:frameID,
            sourceVideoRelativePath:VideoTourPolicy.videoPath(captureID:captureID,segmentID:segmentID),
            sourceVideoSHA256:String(repeating:"ab",count:32),sourceMetadataSHA256:String(repeating:"cd",count:32),
            requestedVideoSeconds:12,actualVideoSeconds:12,sourceARTimestamp:200,sourceObservedAt:capturedAt,
            sourceIntrinsics:[1200,0,0,0,1200,0,960,720,1],sourceWidth:1920,sourceHeight:1440,
            encodedWidth:1920,encodedHeight:1440,imageRotationApplied:.landscapeLeft,poseTimeOffsetSeconds:0,trackingState:"normal")
        var videoPhoto = photo; videoPhoto.videoFrameProvenance = provenance
        let videoStation = TourStation(photo:videoPhoto,number:2)
        expect(videoStation.videoFrameProvenance == provenance && videoStation.cameraFrameID == frameID,
               "derived stations preserve actual movie path/hash/time/pose provenance")
        expect(station.videoFrameProvenance == nil,"ordinary photos acquire no invented video source")
        var videoTour = tour; videoTour.stations = [videoStation]
        expect(!rejects(videoTour),"a valid actual movie-frame station can be persisted")
        videoTour.stations[0].cameraFrameID = UUID()
        expect(rejects(videoTour),"movie pose metadata cannot attach to a different AR coordinate frame")
        videoTour.stations[0].cameraFrameID = frameID
        videoTour.stations[0].videoFrameProvenance?.sourceVideoSHA256 = "tampered"
        expect(rejects(videoTour),"invalid source movie identity is rejected")
        var altered = tour; altered.schemaVersion = 2
        expect(rejects(altered), "unknown tour schemas are rejected")
        expect(rejects(tour,expectedProject:UUID()), "tours cannot be loaded as another project's materials")
        altered = tour; altered.title = " \n "
        expect(rejects(altered), "blank route titles are rejected")
        altered = tour; altered.stations.append(station)
        expect(rejects(altered), "duplicate station identity is rejected")
        altered = tour; altered.stations[0].originalRelativePath = "evidence/\(UUID().uuidString).jpg"
        expect(rejects(altered), "a station path must refer to its exact recorded original photo ID")
        altered = tour; altered.stations[0].originalRelativePath = "evidence/\(photoID.uuidString).jpg/../../outside.jpg"
        expect(rejects(altered), "path traversal cannot be smuggled into original references")
        altered = tour; altered.stations[0].originalSHA256 = "not-a-hash"
        expect(rejects(altered), "invalid original SHA identity is rejected")
        altered = tour; altered.stations[0].cameraFrameID = nil
        expect(rejects(altered), "camera transforms require their actual coordinate frame identity")
        altered = tour; altered.stations[0].cameraTransform![0] = .nan
        expect(rejects(altered), "nonfinite camera poses are rejected")
        altered = tour; altered.stations[0].annotations[0].source = "automaticGeographicSurvey"
        expect(rejects(altered), "image annotations cannot falsely claim geographic surveying provenance")
        altered = tour; altered.stations[0].annotations[0].vertices = [rectangle[0],rectangle[1]]
        expect(rejects(altered), "invalid grave-photo contours are rejected during manifest validation")
        altered = tour; altered.stations[0].annotations.append(station.annotations[0])
        expect(rejects(altered), "duplicate annotation identities are rejected")
        altered = tour; altered.stations[0].annotations = (0..<201).map { _ in TourAnnotation(featureID:featureID,vertices:rectangle) }
        expect(rejects(altered), "more than 200 annotations in one station are rejected")
        altered = tour; altered.stations[0].annotations = (0..<200).map { _ in TourAnnotation(featureID:featureID,vertices:rectangle) }
        expect(!rejects(altered), "exactly 200 valid operator annotations remain supported")
        altered = tour; altered.stations = (0..<500).map { _ in
            var value = station; value.id = UUID(); return value
        }
        expect(!rejects(altered), "the documented 500-station route limit remains valid")
        var extraStation = station; extraStation.id = UUID(); altered.stations.append(extraStation)
        expect(rejects(altered), "route station counts are bounded before persistence")
        altered = tour; altered.stations[0].projection = .equirectangular360
        expect(rejects(altered), "manifest validation enforces explicit 360 confirmation")
        altered.stations[0].projectionConfirmedAt = importedAt
        expect(!rejects(altered), "valid confirmed panorama persists its explicit operator decision")

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try decoder.decode(TourManifest.self,from:encoder.encode(tour))
        expect(roundTrip.stations[0].originalSHA256 == originalSHA && roundTrip.stations[0].photoID == photoID,
               "JSON round trips preserve exact original photo and hash identity")
        expect(roundTrip.stations[0].annotations[0].featureID == featureID
               && roundTrip.stations[0].annotations[0].vertices == rectangle
               && roundTrip.stations[0].annotations[0].source == "operatorDrawnOnOriginalPhoto",
               "JSON preserves operator grave linkage and normalized coordinates without inventing world units")
        expect(roundTrip.stations[0].annotations.map(\.kind) == [.polygon,.polyline,.point]
               && roundTrip.stations[0].annotations[1].vertices == openRoad.vertices,
               "JSON preserves open road and point kinds without closing roads into grave polygons")
        expect(roundTrip.stations[0].capturedAt == capturedAt && roundTrip.stations[0].importedAt == importedAt,
               "JSON preserves distinct original and import timestamps")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("terraview-tour-check-\(UUID())",isDirectory:true)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let store = TourStore()
        let saved = try await store.save(tour,directory:temporary,projectID:projectID)
        expect(saved.lastPathComponent == "\(tour.id.uuidString).tour.json", "atomic tour files retain their manifest identity")
        let loaded = try await store.load(projectID:projectID,directory:temporary)
        expect(loaded.count == 1 && loaded[0].stations[0].originalSHA256 == originalSHA
               && loaded[0].stations[0].annotations[0].featureID == featureID,
               "production store save/load preserves source and operator annotation identity")
        let otherName = saved.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).tour.json")
        try FileManager.default.moveItem(at:saved,to:otherName)
        var mismatchedIdentityRejected = false
        do { _ = try await store.load(projectID:projectID,directory:temporary) }
        catch { mismatchedIdentityRejected = true }
        expect(mismatchedIdentityRejected, "a file name cannot impersonate a different route identity")
        let unsafeRoot = temporary.appendingPathComponent("unsafe-root",isDirectory:true)
        let outside = temporary.appendingPathComponent("outside-project",isDirectory:true)
        try FileManager.default.createDirectory(at:unsafeRoot,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:unsafeRoot.appendingPathComponent("Tours"),withDestinationURL:outside)
        var symlinkRejected = false
        do { _ = try await store.save(tour,directory:unsafeRoot,projectID:projectID) }
        catch { symlinkRejected = true }
        expect(symlinkRejected, "a symlink cannot redirect operator tour files outside their project root")
        let fileSymlinkRoot = temporary.appendingPathComponent("file-symlink-root",isDirectory:true)
        let fileSymlinkTours = fileSymlinkRoot.appendingPathComponent("Tours",isDirectory:true)
        try FileManager.default.createDirectory(at:fileSymlinkTours,withIntermediateDirectories:true)
        let untouchedExternalFile = outside.appendingPathComponent("outside-tour.json")
        let externalOriginal = Data("external-file-must-stay-unchanged".utf8)
        try externalOriginal.write(to:untouchedExternalFile)
        let redirectedManifest = fileSymlinkTours.appendingPathComponent("\(tour.id.uuidString).tour.json")
        try FileManager.default.createSymbolicLink(at:redirectedManifest,withDestinationURL:untouchedExternalFile)
        var fileSymlinkRejected = false
        do { _ = try await store.save(tour,directory:fileSymlinkRoot,projectID:projectID) }
        catch { fileSymlinkRejected = true }
        expect(fileSymlinkRejected, "an existing manifest-file symlink is rejected before saving")
        expect(try Data(contentsOf:untouchedExternalFile) == externalOriginal,
               "a rejected manifest symlink cannot overwrite an external file")
        var large = tour
        large.stations = (0..<500).map { _ in
            var value = station; value.id = UUID()
            value.annotations = (0..<30).map { _ in TourAnnotation(featureID:featureID,vertices:rectangle) }
            return value
        }
        let largeDirectory = temporary.appendingPathComponent("large-valid-route",isDirectory:true)
        let largeURL = try await store.save(large,directory:largeDirectory,projectID:projectID)
        let committedLarge = try Data(contentsOf:largeURL)
        expect(committedLarge.count > 8*1_024*1_024 && committedLarge.count <= TourStore.maximumManifestBytes,
               "a valid large cemetery route exercises the former unreadable-over-8MB regression")
        let loadedLarge = try await store.load(projectID:projectID,directory:largeDirectory)
        expect(loadedLarge.count == 1 && loadedLarge[0].stations.count == 500
               && loadedLarge[0].stations.last?.annotations.count == 30,
               "a successfully committed large route can immediately reopen with all records")
        var oversized = large
        for index in oversized.stations.indices {
            oversized.stations[index].comment = String(repeating:"墓",count:10_000)
            oversized.stations[index].annotations = (0..<60).map { _ in TourAnnotation(featureID:featureID,vertices:rectangle) }
        }
        try TourPolicy.validate(oversized,projectID:projectID)
        var preciseSizeRejection = false
        do { _ = try await store.save(oversized,directory:largeDirectory,projectID:projectID) }
        catch TourError.manifestTooLarge { preciseSizeRejection = true }
        expect(preciseSizeRejection,"a policy-valid oversized route gets a precise size error before replacement")
        expect(try Data(contentsOf:largeURL) == committedLarge,
               "an oversized update preserves the exact previously committed route bytes")
        let restoredLarge = try await TourStore().load(projectID:projectID,directory:largeDirectory)
        expect(restoredLarge.first?.stations.last?.annotations.count == 30
               && restoredLarge.first?.stations.last?.comment == station.comment,
               "the prior route remains readable by a new store after an oversized update")
        print("Tour policy regression: \(count) checks passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="terraview-tour-policy-") as directory:
    root = Path(directory)
    harness = root / "TourPolicyChecks.swift"
    executable = root / "tour-policy-check"
    harness.write_text("import Foundation\n#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n" + coordinate + geo + timestamp + video_document + "\n" + video_policy + "\n" + photos + production + TESTS)
    subprocess.run(compiler + ["-swift-version", "6", "-strict-concurrency=complete",
        "-parse-as-library", str(harness), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
