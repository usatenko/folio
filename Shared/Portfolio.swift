import Foundation
import Security

struct Point: Codable, Hashable {
    let t: TimeInterval
    let v: Double
    var date: Date { Date(timeIntervalSince1970: t) }
}

struct Position: Codable, Hashable, Identifiable {
    let ticker: String
    let name: String
    let qty: Double
    let price: Double
    let currency: String
    let baseValue: Double
    let basePnl: Double
    let pnlPct: Double?
    let weight: Double?
    var avgPrice: Double? = nil
    var exchange: String? = nil
    var id: String { ticker }
}

struct CashBalance: Codable, Hashable {
    let currency: String
    let cash: Double
    let settled: Double
    let rate: Double
    var baseCash: Double { cash * rate }
}

struct Portfolio: Codable {
    let account: String
    let env: String
    let currency: String
    let fetchedAt: TimeInterval
    let nav: Double
    let cash: Double
    let unrealizedPnl: Double?
    let dayChange: Double?
    let dayChangePct: Double?
    let returns: [String: Double?]
    let navSeries: [Point]
    let positions: [Position]
    // dashboard extras; optional so older cached files and the widget keep decoding
    var stockValue: Double? = nil
    var cashBalances: [CashBalance]? = nil
    var periodSeries: [String: [Point]]? = nil
    var periodReturns: [String: Double]? = nil

    var fetchedDate: Date { Date(timeIntervalSince1970: fetchedAt) }

    /// Daily NAV history from IBKR plus the current value as the last point.
    var navChart: [Point] { navSeries + [Point(t: fetchedAt, v: nav)] }

    /// The market holding most of the portfolio's value.
    var primaryMarket: Market? {
        var totals: [Market: Double] = [:]
        for pos in positions {
            if let m = Market.from(exchange: pos.exchange, currency: pos.currency) { totals[m, default: 0] += pos.baseValue }
        }
        return totals.max { $0.value < $1.value }?.key
    }

    /// True when the data is older than the app's polling would ever leave it: the app is probably not running.
    func isStale(at now: Date) -> Bool { now.timeIntervalSince(fetchedDate) > 45 * 60 }

    /// Written by the app after each poll; the widget only reads it.
    static func load() throws -> Portfolio {
        try JSONDecoder().decode(Portfolio.self, from: Data(contentsOf: AppGroup.portfolioFile))
    }
}

enum AppGroup {
    /// The app group is team-prefixed, so read it from our own code-signing entitlements instead of hardcoding a team.
    static let id: String = {
        if let task = SecTaskCreateFromSelf(nil),
           let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
           let first = groups.first {
            return first
        }
        return "com.ou.ibkrwidget"  // unsigned builds (tests, headless renders)
    }()

    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) ?? FileManager.default.temporaryDirectory
    }
    static var portfolioFile: URL { container.appendingPathComponent("portfolio.json") }
}

enum Fmt {
    static func money(_ v: Double, _ currency: String, decimals: Int = 0) -> String {
        // the locale separates number and symbol with a space; the widget columns are tight, so join them
        let s = v.formatted(.currency(code: currency).precision(.fractionLength(decimals)))
        return s.replacing(#/[\s\u{00A0}\u{202F}]+(?=\p{Sc}+$|[A-Z]{3}$)/#, with: "")
            .replacing(#/^(\p{Sc}+|[A-Z]{3})[\s\u{00A0}\u{202F}]+/#) { String($0.1) }
    }

    static func pct(_ v: Double?, signed: Bool = true) -> String {
        guard let v else { return "–" }
        let s = v.formatted(.percent.precision(.fractionLength(1)))
        return signed && v > 0 ? "+" + s : s
    }

    static func signedMoney(_ v: Double, _ currency: String) -> String {
        (v > 0 ? "+" : "") + money(v, currency)
    }

    static func symbol(_ currency: String) -> String {
        ["USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥", "CAD": "C$", "AUD": "A$", "HKD": "HK$"][currency] ?? currency
    }

    /// Whole amount with the short symbol used in the table ("6 010$"), for foreign-currency cash.
    static func amount(_ v: Double, _ currency: String) -> String {
        v.formatted(.number.precision(.fractionLength(0))) + symbol(currency)
    }

    static func price(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(2)))
    }

    static func arrow(_ v: Double?) -> String {
        guard let v, v != 0 else { return "" }
        return v > 0 ? "▲" : "▼"
    }
}
