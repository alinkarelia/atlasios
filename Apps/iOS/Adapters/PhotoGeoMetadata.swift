import Foundation
import CoreFoundation

/// The basis of the timestamp attached to a geographic observation. Import time
/// is deliberately distinguishable from the unknown capture time of an old photo.
enum PhotoGeoTimestampBasis: String, Codable, Sendable {
    case gpsUTC, exifOffset, importedAtUnknownCaptureTime, deviceLocation, cameraCapture
}

struct PhotoGeoObservation: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double?
    let horizontalAccuracyMeters: Double?
}

struct NormalizedPhotoGeoMetadata: Equatable, Sendable {
    let observation: PhotoGeoObservation?
    let capturedAt: Date?
    let timestampBasis: PhotoGeoTimestampBasis
}

/// Parses the dictionaries supplied by ImageIO, without changing source bytes.
/// GPS coordinates require explicit, valid hemisphere references. A damaged GPS
/// dictionary never turns into a guessed point at the origin.
enum PhotoGeoMetadata {
    static func normalize(_ properties: [String: Any]) -> NormalizedPhotoGeoMetadata {
        let gps = properties["{GPS}"] as? [String: Any]
        let exif = properties["{Exif}"] as? [String: Any]
        let utc = gps.flatMap(gpsDate)
        let offsetDate = exif.flatMap(exifDate)
        let date = utc ?? offsetDate
        let basis: PhotoGeoTimestampBasis = utc != nil ? .gpsUTC
            : offsetDate != nil ? .exifOffset : .importedAtUnknownCaptureTime
        return NormalizedPhotoGeoMetadata(observation: gps.flatMap(observation),
                                          capturedAt: date, timestampBasis: basis)
    }

    private static func observation(_ gps: [String: Any]) -> PhotoGeoObservation? {
        guard let latitude = number(gps["Latitude"]), (0...90).contains(latitude),
              let longitude = number(gps["Longitude"]), (0...180).contains(longitude),
              let latitudeRef = gps["LatitudeRef"] as? String, ["N", "S"].contains(latitudeRef),
              let longitudeRef = gps["LongitudeRef"] as? String, ["E", "W"].contains(longitudeRef) else { return nil }
        var altitude: Double?
        if gps["Altitude"] != nil || gps["AltitudeRef"] != nil {
            guard let magnitude = number(gps["Altitude"]), magnitude >= 0,
                  let reference = number(gps["AltitudeRef"]), reference == 0 || reference == 1 else { return nil }
            altitude = reference == 1 ? -magnitude : magnitude
        }
        var accuracy: Double?
        if gps["HPositioningError"] != nil {
            guard let value = number(gps["HPositioningError"]), value >= 0 else { return nil }
            accuracy = value
        }
        return PhotoGeoObservation(latitude: latitudeRef == "S" ? -latitude : latitude,
            longitude: longitudeRef == "W" ? -longitude : longitude,
            altitudeMeters: altitude, horizontalAccuracyMeters: accuracy)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func gpsDate(_ gps: [String: Any]) -> Date? {
        guard let date = gps["DateStamp"] as? String,
              let parts = dateParts(date), let time = timeParts(gps["TimeStamp"]) else { return nil }
        return calendarDate(year: parts.0, month: parts.1, day: parts.2,
                            hour: time.0, minute: time.1, seconds: time.2, offsetSeconds: 0)
    }

    private static func exifDate(_ exif: [String: Any]) -> Date? {
        guard let value = exif["DateTimeOriginal"] as? String, value.count == 19,
              let offset = exif["OffsetTimeOriginal"] as? String,
              let offsetSeconds = utcOffset(offset),
              let date = dateParts(String(value.prefix(10))),
              value[value.index(value.startIndex, offsetBy: 10)] == " ",
              let time = timeParts(String(value.suffix(8))) else { return nil }
        return calendarDate(year: date.0, month: date.1, day: date.2,
                            hour: time.0, minute: time.1, seconds: time.2, offsetSeconds: offsetSeconds)
    }

    private static func dateParts(_ value: String) -> (Int, Int, Int)? {
        guard value.count == 10 else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ asciiDigits($0) }),
              let year = Int(parts[0]), (1...9999).contains(year),
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day) else { return nil }
        return (year, month, day)
    }

    private static func timeParts(_ value: Any?) -> (Int, Int, Double)? {
        let hours: Double, minutes: Double, seconds: Double
        if let value = value as? String {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].count == 2, parts[1].count == 2,
                  asciiDigits(parts[0]), asciiDigits(parts[1]),
                  validSeconds(parts[2]), let h = Double(parts[0]),
                  let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            hours = h; minutes = m; seconds = s
        } else if let values = value as? [Any], values.count == 3,
                  let h = number(values[0]), let m = number(values[1]), let s = number(values[2]) {
            hours = h; minutes = m; seconds = s
        } else { return nil }
        guard hours.rounded() == hours, minutes.rounded() == minutes,
              (0..<24).contains(hours), (0..<60).contains(minutes),
              seconds.isFinite, (0..<60).contains(seconds) else { return nil }
        return (Int(hours), Int(minutes), seconds)
    }

    private static func validSeconds(_ value: Substring) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts[0].count == 2, asciiDigits(parts[0]) else { return false }
        return parts.count == 1 || ((1...9).contains(parts[1].count) && asciiDigits(parts[1]))
    }

    private static func utcOffset(_ value: String) -> Int? {
        guard value.count == 6, value.first == "+" || value.first == "-",
              value[value.index(value.startIndex, offsetBy: 3)] == ":" else { return nil }
        let hours = value.dropFirst().prefix(2), minutes = value.suffix(2)
        guard asciiDigits(hours), asciiDigits(minutes), let h = Int(hours), let m = Int(minutes),
              (0...14).contains(h), (0...59).contains(m), h < 14 || m == 0 else { return nil }
        return (value.first == "-" ? -1 : 1) * (h * 3600 + m * 60)
    }

    private static func asciiDigits(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func calendarDate(year: Int, month: Int, day: Int, hour: Int,
                                     minute: Int, seconds: Double, offsetSeconds: Int) -> Date? {
        guard let zone = TimeZone(secondsFromGMT: offsetSeconds) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let integralSeconds = Int(seconds)
        let components = DateComponents(timeZone: zone, year: year, month: month, day: day,
            hour: hour, minute: minute, second: integralSeconds)
        guard let date = calendar.date(from: components) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard checked.year == year, checked.month == month, checked.day == day,
              checked.hour == hour, checked.minute == minute, checked.second == integralSeconds else { return nil }
        return date.addingTimeInterval(seconds - Double(integralSeconds))
    }
}
