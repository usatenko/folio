import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let portfolio: Portfolio?
    let error: String?
}

struct Provider: TimelineProvider {
    static let refresh: TimeInterval = 15 * 60
    static let retry: TimeInterval = 5 * 60

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, portfolio: .sample, error: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        if context.isPreview {
            return completion(placeholder(in: context))
        }
        Task { completion(await fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            let entry = await fetch()
            var entries = [entry]
            // flip the market status exactly at the next open/close
            if let p = entry.portfolio, let m = p.primaryMarket {
                let next = m.status(at: entry.date).next
                if next.timeIntervalSince(entry.date) < 24 * 3600 {
                    entries.append(Entry(date: next, portfolio: p, error: nil))
                }
            }
            let refresh = Date.now.addingTimeInterval(entry.portfolio == nil ? Self.retry : Self.refresh)
            completion(Timeline(entries: entries, policy: .after(refresh)))
        }
    }

    private func fetch() async -> Entry {
        do {
            return Entry(date: .now, portfolio: try Portfolio.load(), error: nil)
        } catch {
            return Entry(date: .now, portfolio: nil, error: "Open Folio to connect")
        }
    }
}

struct IBKRWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        Group {
            if let p = entry.portfolio {
                PortfolioView(p: p, size: size, now: entry.date)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(entry.error ?? "No data").font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var size: PortfolioView.Size {
        switch family {
        case .systemSmall: .small
        case .systemMedium: .medium
        case .systemExtraLarge: .extraLarge
        default: .large
        }
    }
}

@main
struct IBKRWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "IBKRPortfolio", provider: Provider()) { entry in
            IBKRWidgetView(entry: entry)
        }
        .configurationDisplayName("Folio")
        .description("Account value, today's change, returns and positions from your IBKR account.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
