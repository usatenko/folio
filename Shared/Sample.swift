import Foundation

extension Portfolio {
    /// Placeholder data for the widget gallery; not real account data.
    static let sample: Portfolio = {
        let now = Date.now.timeIntervalSince1970
        let nav: [Point] = (0..<21).map { i in
            let wiggle: Double = i % 3 == 0 ? -200 : 120
            return Point(t: now - Double(21 - i) * 86400, v: 30000 + Double(i) * 150 + wiggle)
        }
        func pos(_ t: String, _ v: Double, _ pnl: Double) -> Position {
            Position(ticker: t, name: t, qty: 10, price: v / 10, currency: "USD", baseValue: v, basePnl: v * pnl,
                     pnlPct: pnl, weight: v / 33000, exchange: "NASDAQ")
        }
        return Portfolio(account: "U0000000", env: "sample", currency: "EUR", fetchedAt: now, nav: 33000, cash: 10000, unrealizedPnl: 2400,
                         dayChange: 250, dayChangePct: 0.0076, returns: ["MTD": 0.02, "YTD": 0.11, "1Y": 0.15],
                         navSeries: nav, positions: [pos("AAPL", 9000, 0.12), pos("MSFT", 7000, 0.08), pos("NVDA", 5000, -0.03), pos("GOOG", 2000, 0.05)])
    }()
}
