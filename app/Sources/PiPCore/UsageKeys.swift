import Foundation

/// Daily counter keys for anonymous usage reporting: "day|name|k=v…", one per combination per day.
public enum UsageKeys {
    public static func counter(day: String, name: String, props: [String: String] = [:]) -> String {
        ([day, name] + props.keys.sorted().map { "\($0)=\(props[$0]!)" }).joined(separator: "|")
    }

    public static func parse(_ key: String) -> (day: String, name: String, props: [String: String])? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        var props: [String: String] = [:]
        for p in parts.dropFirst(2) {
            guard let i = p.firstIndex(of: "="), i != p.startIndex else { continue }
            props[String(p[..<i])] = String(p[p.index(after: i)...])
        }
        return (parts[0], parts[1], props)
    }

    public static func day(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Noon on that local day (ms), so a counter lands on its day in any report.
    public static func noon(of day: String, calendar: Calendar = .current) -> Int64 {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let d = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)) else {
            return Int64(Date().timeIntervalSince1970 * 1000)
        }
        return Int64(d.timeIntervalSince1970 * 1000)
    }
}
