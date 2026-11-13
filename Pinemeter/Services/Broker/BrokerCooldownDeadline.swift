import Foundation

/// Strict cooldown timestamp grammar mirrored by mcpd.parseUntil.
enum BrokerCooldownDeadline {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$"#
    )

    static func parse(_ raw: String) -> Date? {
        let fullRange = NSRange(location: 0, length: raw.utf16.count)
        guard let match = pattern.firstMatch(in: raw, options: [], range: fullRange),
              match.range == fullRange else { return nil }
        let source = raw as NSString
        func part(_ index: Int) -> String {
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
        let year = Int(part(1))!, month = Int(part(2))!, day = Int(part(3))!
        let hour = Int(part(4))!, minute = Int(part(5))!, second = Int(part(6))!
        guard (1...12).contains(month), (1...daysIn(year: year, month: month)).contains(day),
              hour <= 23, minute <= 59, second <= 59 else { return nil }
        var offset = 0
        let zone = part(8)
        if zone != "Z" {
            let digits = Array(zone)
            let offsetHour = Int(String(digits[1...2]))!
            let offsetMinute = Int(String(digits[4...5]))!
            guard offsetHour <= 23, offsetMinute <= 59 else { return nil }
            offset = (offsetHour * 3600 + offsetMinute * 60) * (digits[0] == "-" ? -1 : 1)
        }
        // Proleptic Gregorian arithmetic preserves year zero and pre-1582 dates across engines.
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146097 + dayOfEra - 719468
        var seconds = days * 86400 + hour * 3600 + minute * 60 + second - offset
        if part(7).contains(where: { $0 != "." && $0 != "0" }) { seconds += 1 }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func daysIn(year: Int, month: Int) -> Int {
        if month == 2 {
            return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        }
        return [4, 6, 9, 11].contains(month) ? 30 : 31
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        // Drop the fraction before formatting: DateFormatter rounds to the
        // millisecond, while Go's Format truncates, so a clamped deadline
        // would otherwise echo a different second in each engine.
        return formatter.string(from: Date(timeIntervalSince1970: floor(date.timeIntervalSince1970)))
    }
}
