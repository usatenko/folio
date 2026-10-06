import Foundation
import WidgetKit

/// Polls IBKR, records per-ticker price snapshots, and publishes the portfolio to the app group for the widget.
@MainActor
final class PortfolioStore: ObservableObject {
    static let shared = PortfolioStore()

    @Published private(set) var portfolio: Portfolio? = try? Portfolio.load()
    @Published private(set) var lastError: String?
    @Published private(set) var refreshing = false
    @Published private(set) var nextPoll: Date?

    private var client: IBKRClient?
    private var pollTask: Task<Void, Never>?

    var pollMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: "pollMinutes")
        return v > 0 ? v : 5
    }

    func credentialsChanged() {
        client = nil
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await refresh()
                nextPoll = Date.now.addingTimeInterval(TimeInterval(pollMinutes * 60))
                try? await Task.sleep(for: .seconds(pollMinutes * 60))
            }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            if client == nil {
                guard let creds = Credentials.load(), creds.isComplete else {
                    lastError = "Not connected: add your IBKR credentials in Settings"
                    return
                }
                client = try IBKRClient(credentials: creds)
            }
            let p = try await Self.fetch(client!)
            try JSONEncoder().encode(p).write(to: AppGroup.portfolioFile, options: .atomic)
            // account data: owner-only, even inside the group container
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppGroup.portfolioFile.path)
            portfolio = p
            lastError = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: payload

    private static func num(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    /// Assembles the portfolio from IBKR's read-only endpoints: 5 calls.
    static func fetch(_ client: IBKRClient) async throws -> Portfolio {
        guard let acct = try await client.accounts().first?["accountId"] as? String else {
            throw IBKRError.badResponse("no accounts")
        }
        let summary = try await client.summary(acct)
        let ledger = try await client.ledger(acct)
        let positions = try await client.positions(acct)
        guard let perf = try await client.allPeriods(acct)[acct] as? [String: Any] else {
            throw IBKRError.badResponse("no performance data")
        }
        func amount(_ key: String) -> Double? { num((summary[key] as? [String: Any])?["amount"]) }
        guard let nav = amount("netliquidation") else { throw IBKRError.badResponse("no net liquidation") }
        let currency = perf["baseCurrency"] as? String ?? "EUR"
        let base = ledger["BASE"] as? [String: Any] ?? [:]
        let now = Int(Date.now.timeIntervalSince1970)

        var rows: [Position] = []
        for p in positions {
            guard let qty = num(p["position"]), let price = num(p["mktPrice"]) else { continue }
            let ccy = p["currency"] as? String ?? ""
            let rate = num((ledger[ccy] as? [String: Any])?["exchangerate"]) ?? 1
            let value = (num(p["mktValue"]) ?? 0) * rate
            let pnl = (num(p["unrealizedPnl"]) ?? 0) * rate
            let cost = (num(p["avgCost"]) ?? 0) * qty * rate
            let ticker = p["ticker"] as? String ?? p["contractDesc"] as? String ?? "?"
            rows.append(Position(
                ticker: ticker,
                name: p["name"] as? String ?? ticker,
                qty: qty, price: price, currency: ccy,
                baseValue: value, basePnl: pnl,
                pnlPct: cost != 0 ? pnl / cost : nil,
                weight: nav != 0 ? value / nav : nil,
                avgPrice: num(p["avgPrice"]),
                exchange: p["listingExchange"] as? String
            ))
        }
        rows.sort { $0.baseValue > $1.baseValue }

        func period(_ k: String) -> [String: Any]? { perf[k] as? [String: Any] }
        func lastReturn(_ k: String) -> Double? { (period(k)?["cps"] as? [Any])?.last.flatMap(num) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func series(_ k: String) -> [Point] {
            let dates = period(k)?["dates"] as? [String] ?? []
            let navs = (period(k)?["nav"] as? [Any] ?? []).compactMap(num)
            return zip(dates, navs).compactMap { d, v in
                guard d.count == 8, let y = Int(d.prefix(4)), let m = Int(d.dropFirst(4).prefix(2)), let day = Int(d.suffix(2)),
                      let date = cal.date(from: DateComponents(year: y, month: m, day: day)) else { return nil }
                return Point(t: date.timeIntervalSince1970, v: v)
            }
        }
        let periods = perf["periods"] as? [String] ?? ["1D", "7D", "MTD", "1M", "YTD", "1Y"]
        let dayStart = num((period("1D")?["startNAV"] as? [String: Any])?["val"])
        let cash: [CashBalance] = ledger.compactMap { key, value in
            guard key != "BASE", let v = value as? [String: Any], let bal = num(v["cashbalance"]), bal != 0 else { return nil }
            return CashBalance(currency: key, cash: bal, settled: num(v["settledcash"]) ?? bal, rate: num(v["exchangerate"]) ?? 1)
        }.sorted { $0.baseCash > $1.baseCash }

        return Portfolio(
            account: acct,
            env: "live",
            currency: currency,
            fetchedAt: TimeInterval(now),
            nav: nav,
            cash: num(base["cashbalance"]) ?? 0,
            unrealizedPnl: num(base["unrealizedpnl"]),
            dayChange: dayStart.map { nav - $0 },
            dayChangePct: lastReturn("1D"),
            returns: ["MTD": lastReturn("MTD"), "YTD": lastReturn("YTD"), "1Y": lastReturn("1Y")],
            navSeries: series("1M"),
            positions: rows,
            stockValue: num(base["stockmarketvalue"]),
            cashBalances: cash,
            periodSeries: Dictionary(uniqueKeysWithValues: periods.map { ($0, series($0)) }),
            periodReturns: Dictionary(uniqueKeysWithValues: periods.compactMap { k in lastReturn(k).map { (k, $0) } })
        )
    }
}
