import Charts
import SwiftUI

enum Palette {
    static let series = Color(light: 0x2a78d6, dark: 0x3987e5)
    static let up = Color(light: 0x006300, dark: 0x0ca30c)
    static let down = Color(light: 0xd03b3b, dark: 0xe66767)
    static let grid = Color(light: 0xe1e0d9, dark: 0x2c2c2a)

    static func delta(_ v: Double?) -> Color {
        guard let v, v != 0 else { return .secondary }
        return v > 0 ? up : down
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1
            )
        })
    }
}

/// Line chart of a single series. With `showAxis` it draws a recessive value axis; otherwise it is a sparkline.
/// `tint` defaults to the series color; sparklines pass a direction color.
struct LineChart: View {
    let points: [Point]
    var showAxis = false
    var tint: Color = Palette.series

    var body: some View {
        if points.count < 2 {
            Text("collecting…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let values = points.map(\.v)
            let lo = values.min()!, hi = values.max()!
            let pad = max((hi - lo) * 0.1, hi * 0.005)  // floor the range so tiny moves stay visually small
            Chart(points, id: \.t) { p in
                LineMark(x: .value("Time", p.date), y: .value("Value", p.v))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(tint)
                AreaMark(x: .value("Time", p.date), yStart: .value("Low", lo - pad), yEnd: .value("Value", p.v))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(
                        colors: [tint.opacity(0.18), tint.opacity(0)],
                        startPoint: .top, endPoint: .bottom))
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartXAxis(.hidden)
            .chartYAxis {
                if showAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.grid)
                        AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName)).font(.system(size: 9))
                    }
                }
            }
            .chartLegend(.hidden)
        }
    }
}

/// Compact time range under a chart: first and last date, never colliding.
struct DateRange: View {
    let points: [Point]

    var body: some View {
        if let first = points.first?.date, let last = points.last?.date {
            HStack {
                Text(first, format: .dateTime.day().month(.abbreviated))
                Spacer()
                Text(Calendar.current.isDateInToday(last) ? "Today" : last.formatted(.dateTime.day().month(.abbreviated)))
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }
}
