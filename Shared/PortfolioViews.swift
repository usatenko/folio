import SwiftUI

struct Header: View {
    let p: Portfolio
    let now: Date
    var large = false  // full market sentence and update time; smaller sizes get the short form

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if p.env != "live" {
                    Text(p.env.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.orange)
                }
                if p.isStale(at: now) {
                    // the app has not written anything for a while: that matters more than market hours
                    Label { Text("Last update \(p.fetchedDate, style: .time)") } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .help("No update from Folio for a while. Is it running?")
                } else if let m = p.primaryMarket {
                    MarketStatus(market: m, now: now, full: large)
                }
                Spacer(minLength: 4)
                if large, !p.isStale(at: now) {
                    Text("Updated \(p.fetchedDate, style: .time)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            if large {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    nav
                    change
                }
            } else {
                nav
                change
            }
        }
    }

    private var nav: some View {
        Text(Fmt.money(p.nav, p.currency))
            .font(.title2.weight(.semibold))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }

    private var change: some View {
        HStack(spacing: 4) {
            if let d = p.dayChange {
                Text(Fmt.signedMoney(d, p.currency)).foregroundStyle(Palette.delta(d))
            }
            Text(Fmt.pct(p.dayChangePct)).foregroundStyle(Palette.delta(p.dayChangePct))
            Text("today").foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// Full: "US closes in 2 hr, 10 min (14:00)" / "US opens in 12 hr, 50 min (Tue 07:30)". Short: without the market and clock time.
/// The countdown is a relative-date Text, which WidgetKit keeps ticking; times are in the viewer's local time.
struct MarketStatus: View {
    let market: Market
    let now: Date
    var full = false

    var body: some View {
        let s = market.status(at: now)
        let clock = Calendar.current.isDate(s.next, inSameDayAs: now)
            ? s.next.formatted(date: .omitted, time: .shortened)
            : s.next.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let verb = s.isOpen ? "closes in " : "opens in "
        HStack(spacing: 3) {
            Circle().fill(s.isOpen ? Palette.up : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            if full {
                Text("\(market.shortName) \(verb)") + Text(s.next, style: .relative) + Text(" (\(clock))")
            } else {
                Text(verb.capitalized) + Text(s.next, style: .relative)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .minimumScaleFactor(0.85)
    }
}

struct Returns: View {
    let p: Portfolio
    var keys = ["MTD", "YTD", "1Y"]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(keys, id: \.self) { k in
                let v = p.returns[k] ?? nil
                HStack(spacing: 3) {
                    Text(k).foregroundStyle(.secondary)
                    Text(Fmt.pct(v)).foregroundStyle(Palette.delta(v))
                }
            }
        }
        .font(.caption2.weight(.medium))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}

/// Share of the portfolio as a slim bar, relative to the largest position so the biggest is full width.
struct WeightBar: View {
    let weight: Double
    let max: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Palette.series).frame(width: max > 0 ? geo.size.width * weight / max : 0)
            }
        }
        .frame(height: 4)
    }
}

/// Column labels for the detailed rows, laid out with the same fixed widths as PositionRow.
struct PositionHeader: View {
    var showWeightBar = false

    var body: some View {
        HStack(spacing: 3) {
            Text("Ticker").frame(width: 38, alignment: .leading)
            if showWeightBar {
                Text("Weight").frame(maxWidth: .infinity, alignment: .leading)
                Text("").frame(width: 34)
            }
            // same three sub-columns as the data: cost right-aligned, arrow, price left-aligned
            HStack(spacing: 2) {
                Text("Cost").frame(width: 42, alignment: .trailing)
                Text("→").frame(width: 9)
                Text("Price").frame(width: 52, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: showWeightBar ? .trailing : .leading)
            Text("Value").frame(width: 50, alignment: .trailing)
            Text("P&L").frame(width: 50, alignment: .trailing)
            Text("P&L %").frame(width: 38, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .lineLimit(1)
    }
}

struct PositionRow: View {
    let pos: Position
    let currency: String
    var maxWeight: Double = 1
    var detailed = false  // large widget: one line with cost → price, value, P&L amount and %
    var dense = false  // smaller type when many positions must fit
    var showWeightBar = false  // extra-large widget has room for the bar as well

    var body: some View {
        if detailed {
            // every column has a fixed width and the sum (≈285pt) stays under the 297pt row even at
            // the real widget's slightly wider font metrics, so nothing shifts between rows
            HStack(spacing: 3) {
                Text(pos.ticker).font(.caption.weight(.semibold)).frame(width: 38, alignment: .leading)
                if showWeightBar {
                    WeightBar(weight: pos.weight ?? 0, max: maxWeight).frame(minWidth: 30)
                    Text(Fmt.pct(pos.weight, signed: false)).foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                }
                // average cost → current price in the stock's own currency, as aligned sub-columns
                HStack(spacing: 2) {
                    Text(pos.avgPrice.map(Fmt.price) ?? "–").frame(width: 42, alignment: .trailing)
                    Text("→").foregroundStyle(.tertiary).frame(width: 9)
                    // cost right-aligned, price left-aligned: the arrow sits centred between them in every row
                    Text("\(Fmt.price(pos.price))\(Fmt.symbol(pos.currency))").frame(width: 52, alignment: .leading)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: showWeightBar ? .trailing : .leading)
                Text(Fmt.money(pos.baseValue, currency)).fontWeight(.medium).frame(width: 50, alignment: .trailing)
                Text(Fmt.signedMoney(pos.basePnl, currency))
                    .foregroundStyle(Palette.delta(pos.basePnl)).frame(width: 50, alignment: .trailing)
                Text(Fmt.pct(pos.pnlPct)).foregroundStyle(Palette.delta(pos.basePnl)).frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: dense ? 9 : 10))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        } else {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(pos.ticker).font(.caption.weight(.semibold))
                    if let w = pos.weight {
                        Text(Fmt.pct(w, signed: false)).font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .frame(width: 44, alignment: .leading)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.money(pos.baseValue, currency)).font(.caption.weight(.medium))
                    Text(Fmt.pct(pos.pnlPct))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.delta(pos.basePnl))
                }
                .lineLimit(1)
                .monospacedDigit()
                .frame(width: 74, alignment: .trailing)
            }
        }
    }
}

struct PortfolioView: View {
    enum Size { case small, medium, large, extraLarge }
    let p: Portfolio
    let size: Size
    var now: Date = .now

    var body: some View {
        let maxWeight = p.positions.compactMap(\.weight).max() ?? 1
        let n = p.positions.count
        switch size {
        case .small:
            VStack(alignment: .leading, spacing: 4) {
                Header(p: p, now: now)
                LineChart(points: p.navChart)
                DateRange(points: p.navChart)
            }
        case .medium:
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Header(p: p, now: now)
                    LineChart(points: p.navChart, showAxis: true)
                    DateRange(points: p.navChart)
                    Returns(p: p, keys: ["YTD", "1Y"])
                }
                VStack(spacing: 5) {
                    Caption(title: "Top positions")
                    ForEach(p.positions.prefix(4)) { PositionRow(pos: $0, currency: p.currency) }
                    more(after: 4)
                    Spacer(minLength: 0)
                }
                .frame(width: 170)
            }
        case .large:
            // fixed ~310pt of height: spend it on the chart when there are few positions, on rows when many
            let dense = n > 7
            VStack(alignment: .leading, spacing: 4) {
                Header(p: p, now: now, large: true)
                LineChart(points: p.navChart, showAxis: true)
                    .frame(height: n <= 4 ? 80 : n <= 7 ? 56 : 28)
                DateRange(points: p.navChart)
                returnsRow
                cashRow
                PositionHeader()
                    .padding(.top, 2)
                VStack(spacing: n <= 4 ? 12 : n <= 7 ? 9 : 3) {
                    ForEach(p.positions.prefix(10)) { PositionRow(pos: $0, currency: p.currency, maxWeight: maxWeight, detailed: true, dense: dense) }
                }
                more(after: 10)
                Spacer(minLength: 0)
            }
        case .extraLarge:
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Header(p: p, now: now, large: true)
                    LineChart(points: p.navChart, showAxis: true)
                        .frame(maxHeight: .infinity)
                    DateRange(points: p.navChart)
                    returnsRow
                    if let cash = p.cashBalances, !cash.isEmpty {
                        HStack(spacing: 4) {
                            Text("Cash").foregroundStyle(.secondary)
                            Text(cash.map { Fmt.amount($0.cash, $0.currency) }.joined(separator: " + "))
                        }
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                    }
                }
                .frame(width: 290)
                VStack(spacing: n > 10 ? 3 : n > 7 ? 6 : 10) {
                    PositionHeader(showWeightBar: true)
                    ForEach(p.positions.prefix(14)) { PositionRow(pos: $0, currency: p.currency, maxWeight: maxWeight, detailed: true, dense: n > 10, showWeightBar: true) }
                    more(after: 14)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var returnsRow: some View {
        HStack {
            Returns(p: p)
            Spacer(minLength: 4)
            if let u = p.unrealizedPnl {
                HStack(spacing: 3) {
                    Text("P&L").foregroundStyle(.secondary)
                    Text(Fmt.signedMoney(u, p.currency)).foregroundStyle(Palette.delta(u))
                }
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            }
        }
    }

    /// Available cash: total in the base currency, then the balances it is made of.
    @ViewBuilder
    private var cashRow: some View {
        HStack(spacing: 4) {
            Text("Cash").foregroundStyle(.secondary)
            Text(Fmt.money(p.cash, p.currency)).fontWeight(.medium)
            if let cash = p.cashBalances, cash.count > 1 || cash.first?.currency != p.currency {
                Text("·").foregroundStyle(.tertiary)
                Text(cash.map { Fmt.amount($0.cash, $0.currency) }.joined(separator: " + ")).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption2)
        .monospacedDigit()
        .lineLimit(1)
    }

    /// "+3 more · 1 240 €" when the list is cut, so the total is never silently incomplete.
    @ViewBuilder
    private func more(after shown: Int) -> some View {
        let rest = p.positions.dropFirst(shown)
        if !rest.isEmpty {
            HStack {
                Text("+\(rest.count) more").foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.money(rest.reduce(0) { $0 + $1.baseValue }, p.currency)).foregroundStyle(.secondary)
            }
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
        }
    }
}

/// Section caption: a label on the left, a muted note on the right.
struct Caption: View {
    let title: String
    var note: String? = nil

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            if let note { Text(note).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 9, weight: .medium))
        .textCase(.uppercase)
    }
}
