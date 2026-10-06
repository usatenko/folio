import Foundation

/// Regular trading hours for the markets the positions are listed on. Holidays are listed for the
/// US and Xetra; other markets only skip weekends. Early-close days are treated as full days.
enum Market: String, CaseIterable {
    case us, xetra, euronext, lse, six, tsx, tokyo, hk, asx

    var name: String {
        switch self {
        case .us: "US market"
        case .xetra: "Xetra"
        case .euronext: "Euronext"
        case .lse: "London"
        case .six: "SIX"
        case .tsx: "Toronto"
        case .tokyo: "Tokyo"
        case .hk: "Hong Kong"
        case .asx: "ASX"
        }
    }

    var shortName: String {
        switch self {
        case .us: "US"
        case .hk: "HK"
        default: name
        }
    }

    var timeZone: TimeZone {
        TimeZone(identifier: [
            .us: "America/New_York", .xetra: "Europe/Berlin", .euronext: "Europe/Paris", .lse: "Europe/London",
            .six: "Europe/Zurich", .tsx: "America/Toronto", .tokyo: "Asia/Tokyo", .hk: "Asia/Hong_Kong", .asx: "Australia/Sydney",
        ][self]!)!
    }

    /// (open hour, open minute, close hour, close minute) in the market's local time
    var hours: (Int, Int, Int, Int) {
        switch self {
        case .us, .tsx: (9, 30, 16, 0)
        case .xetra, .euronext, .six: (9, 0, 17, 30)
        case .lse: (8, 0, 16, 30)
        case .tokyo: (9, 0, 15, 30)
        case .hk: (9, 30, 16, 0)
        case .asx: (10, 0, 16, 0)
        }
    }

    private static let holidays: [Market: Set<String>] = [
        .us: [
            "2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25", "2026-06-19", "2026-07-03", "2026-09-07", "2026-11-26", "2026-12-25",
            "2027-01-01", "2027-01-18", "2027-02-15", "2027-03-26", "2027-05-31", "2027-06-18", "2027-07-05", "2027-09-06", "2027-11-25", "2027-12-24",
        ],
        .xetra: [
            "2026-01-01", "2026-04-03", "2026-04-06", "2026-05-01", "2026-12-24", "2026-12-25", "2026-12-31",
            "2027-01-01", "2027-03-26", "2027-03-29", "2027-05-01", "2027-12-24", "2027-12-31",
        ],
    ]

    /// Maps IBKR's listing exchange codes; falls back to the trading currency.
    static func from(exchange: String?, currency: String) -> Market? {
        switch exchange?.uppercased() {
        case "NASDAQ", "NYSE", "ARCA", "AMEX", "BATS", "PINK", "NYSENAT", "IEX": return .us
        case "IBIS", "FWB", "SWB", "TGATE": return .xetra
        case "SBF", "AEB", "ENEXT.BE", "BVL", "EBS": return .euronext
        case "LSE", "LSEETF", "LSEIOB1": return .lse
        case "SWX", "VIRTX": return .six
        case "TSE", "VENTURE": return .tsx
        case "TSEJ": return .tokyo
        case "SEHK": return .hk
        case "ASX": return .asx
        default: break
        }
        return [.init("USD"): .us, "EUR": .xetra, "GBP": .lse, "CHF": .six, "CAD": .tsx, "JPY": .tokyo, "HKD": .hk, "AUD": .asx][currency]
    }

    struct Status {
        let isOpen: Bool
        let next: Date  // next close when open, next open when closed
    }

    func status(at now: Date) -> Status {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let (oh, om, ch, cm) = hours
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        for offset in 0..<14 {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)) else { continue }
            let weekday = cal.component(.weekday, from: day)
            if weekday == 1 || weekday == 7 || Self.holidays[self]?.contains(fmt.string(from: day)) == true { continue }
            guard let open = cal.date(bySettingHour: oh, minute: om, second: 0, of: day),
                  let close = cal.date(bySettingHour: ch, minute: cm, second: 0, of: day) else { continue }
            if now >= close { continue }
            return now < open ? Status(isOpen: false, next: open) : Status(isOpen: true, next: close)
        }
        return Status(isOpen: false, next: now.addingTimeInterval(86400))
    }
}
