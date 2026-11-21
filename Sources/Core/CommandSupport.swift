import Foundation

enum Fmt {
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    static let longDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static let unixDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss zzz yyyy"
        return formatter
    }()

    static func humanSize(_ bytes: Int64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 {
            return "\(Int(value))B"
        }
        return String(format: "%.1f%@", value, units[unit])
    }

    static func padded(_ text: String, _ width: Int, left: Bool = false) -> String {
        let missing = max(0, width - text.count)
        let pad = String(repeating: " ", count: missing)
        return left ? pad + text : text + pad
    }
}

// MARK: - 字符串小工具

extension String {
    func leftPadded(_ width: Int) -> String {
        Fmt.padded(self, width, left: true)
    }

    func trimmedRight() -> String {
        var value = self
        while value.hasSuffix(" ") { value.removeLast() }
        return value
    }

    var firstLine: String {
        components(separatedBy: "\n").first ?? self
    }
}
