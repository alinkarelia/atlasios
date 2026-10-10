#if ATLAS_PHOTO_METADATA_CHECKS
import Foundation

@main
struct PhotoGeoMetadataChecks {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            guard value() else { fatalError("Photo GPS check failed: \(description)") }
            checks += 1
        }
        func normalize(_ gps: [String: Any], _ exif: [String: Any]? = nil) -> NormalizedPhotoGeoMetadata {
            var properties: [String: Any] = ["{GPS}": gps]
            if let exif { properties["{Exif}"] = exif }
            return PhotoGeoMetadata.normalize(properties)
        }
        let valid: [String: Any] = ["Latitude": 55.75, "LatitudeRef": "N", "Longitude": 37.61, "LongitudeRef": "E"]
        func changed(_ key: String, _ value: Any?) -> [String: Any] {
            var gps = valid; gps[key] = value; return gps
        }
        let north = normalize(valid)
        check(north.observation?.latitude == 55.75 && north.observation?.longitude == 37.61, "north/east references")
        check(north.capturedAt == nil && north.timestampBasis == .importedAtUnknownCaptureTime, "unknown capture time is explicit")
        check(north.observation?.horizontalAccuracyMeters == nil, "missing accuracy remains unknown")
        var south = valid; south["LatitudeRef"] = "S"; south["LongitudeRef"] = "W"
        check(normalize(south).observation?.latitude == -55.75 && normalize(south).observation?.longitude == -37.61, "south/west references")
        var origin = valid; origin["Latitude"] = 0; origin["Longitude"] = 0
        check(normalize(origin).observation?.latitude == 0 && normalize(origin).observation?.longitude == 0, "explicit geographic origin is valid")
        check(PhotoGeoMetadata.normalize([:]).observation == nil, "missing GPS never invents origin")
        check(normalize(changed("LatitudeRef", nil)).observation == nil, "latitude hemisphere required")
        check(normalize(changed("LongitudeRef", nil)).observation == nil, "longitude hemisphere required")
        check(normalize(changed("LatitudeRef", "Q")).observation == nil, "invalid latitude reference rejected")
        check(normalize(changed("LongitudeRef", "east")).observation == nil, "invalid longitude reference rejected")
        check(normalize(changed("Latitude", 90.001)).observation == nil, "latitude range")
        check(normalize(changed("Longitude", 180.001)).observation == nil, "longitude range")
        check(normalize(changed("Latitude", -55.75)).observation == nil, "signed magnitude not double inverted")
        check(normalize(changed("Longitude", Double.nan)).observation == nil, "NaN rejected")
        check(normalize(changed("Latitude", Double.infinity)).observation == nil, "infinity rejected")
        check(normalize(changed("Latitude", true)).observation == nil, "boolean not a coordinate")
        check(normalize(changed("Latitude", "55.75")).observation == nil, "non-numeric EXIF coordinate rejected")
        var altitude = valid; altitude["Altitude"] = 120.5; altitude["AltitudeRef"] = 0
        check(normalize(altitude).observation?.altitudeMeters == 120.5, "above sea level")
        altitude["AltitudeRef"] = 1
        check(normalize(altitude).observation?.altitudeMeters == -120.5, "below sea level")
        altitude["AltitudeRef"] = 2
        check(normalize(altitude).observation == nil, "invalid altitude reference")
        altitude["AltitudeRef"] = nil
        check(normalize(altitude).observation == nil, "unknown altitude reference not guessed")
        altitude["AltitudeRef"] = 0; altitude["Altitude"] = -2
        check(normalize(altitude).observation == nil, "negative unsigned altitude rejected")
        altitude["Altitude"] = Double.infinity
        check(normalize(altitude).observation == nil, "non-finite altitude rejected")
        check(normalize(changed("HPositioningError", 4.2)).observation?.horizontalAccuracyMeters == 4.2, "actual EXIF accuracy")
        check(normalize(changed("HPositioningError", -1)).observation == nil, "negative EXIF accuracy rejected")
        check(normalize(changed("HPositioningError", Double.nan)).observation == nil, "non-finite accuracy rejected")
        var utc = valid; utc["DateStamp"] = "2026:10:09"; utc["TimeStamp"] = "12:34:56.125"
        let utcResult = normalize(utc)
        let expectedUTC = ISO8601DateFormatter().date(from: "2026-10-09T12:34:56Z")!
        check(utcResult.capturedAt == expectedUTC.addingTimeInterval(0.125) && utcResult.timestampBasis == .gpsUTC, "GPS UTC including fractional seconds")
        utc["TimeStamp"] = [12, 34, 56.125]
        check(normalize(utc).capturedAt == expectedUTC.addingTimeInterval(0.125), "numeric GPS time components")
        let exif: [String: Any] = ["DateTimeOriginal": "2026:10:09 15:34:56", "OffsetTimeOriginal": "+03:00"]
        check(normalize(valid, exif).capturedAt == expectedUTC && normalize(valid, exif).timestampBasis == .exifOffset, "EXIF explicit timezone converted to UTC")
        let westExif: [String: Any] = ["DateTimeOriginal": "2026:10:08 23:34:56", "OffsetTimeOriginal": "-13:00"]
        check(normalize(valid, westExif).capturedAt == expectedUTC, "negative timezone crosses calendar date")
        check(normalize(utc, exif).timestampBasis == .gpsUTC, "GPS UTC has priority")
        check(normalize(valid, ["DateTimeOriginal": "2026:10:09 15:34:56"]).capturedAt == nil, "timezone-less local time not guessed")
        check(PhotoGeoMetadata.normalize(["{Exif}": exif]).capturedAt == expectedUTC && PhotoGeoMetadata.normalize(["{Exif}": exif]).observation == nil, "capture timestamp can exist without coordinates")
        utc["DateStamp"] = "2026:02:29"
        check(normalize(utc).capturedAt == nil && normalize(utc).observation != nil, "invalid calendar date does not invalidate valid point")
        utc["DateStamp"] = "2024:02:29"
        check(normalize(utc).capturedAt != nil, "real leap day")
        utc["DateStamp"] = "2026:10:09"; utc["TimeStamp"] = "24:00:00"
        check(normalize(utc).capturedAt == nil, "hours cannot roll into another date")
        utc["TimeStamp"] = "12:34:60"
        check(normalize(utc).capturedAt == nil, "invalid seconds not rolled over")
        utc["TimeStamp"] = "12:34:56junk"
        check(normalize(utc).capturedAt == nil, "junk time text rejected")
        utc["TimeStamp"] = [true, 34, 56]
        check(normalize(utc).capturedAt == nil, "boolean time component rejected")
        var malformedOffset = exif; malformedOffset["OffsetTimeOriginal"] = "+14:01"
        check(normalize(valid, malformedOffset).capturedAt == nil, "invalid timezone limit")
        malformedOffset["OffsetTimeOriginal"] = "+03:99"
        check(normalize(valid, malformedOffset).capturedAt == nil, "timezone minutes range")
        print("Photo geographic metadata: \(checks) checks passed.")
    }
}
#endif
