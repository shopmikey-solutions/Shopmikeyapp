//
//  ShopMikey_Scanner.swift
//  ShopMikey Scanner
//
//  Created by Michael Bordeaux on 2/18/26.
//

import WidgetKit
import SwiftUI

struct PartsIntakeWidgetSnapshot: Codable {
    let generatedAt: Date
    let scansToday: Int
    let submittedCount: Int
    let failedCount: Int
    let pendingCount: Int
    let totalValueCents: Int
}

struct Provider: TimelineProvider {
    typealias Entry = SimpleEntry

    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(
            date: Date(),
            scansToday: 0,
            submittedCount: 0,
            failedCount: 0,
            pendingCount: 0,
            totalValueCents: 0
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(loadEntry(fallbackDate: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        let entry = loadEntry(fallbackDate: Date())
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date) ?? entry.date.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func loadEntry(fallbackDate: Date) -> SimpleEntry {
        let defaults = sharedDefaults ?? .standard
        guard let data = defaults.data(forKey: "partsIntake.widgetSnapshot.v1"),
              let snapshot = try? JSONDecoder().decode(PartsIntakeWidgetSnapshot.self, from: data) else {
            return SimpleEntry(
                date: fallbackDate,
                scansToday: 0,
                submittedCount: 0,
                failedCount: 0,
                pendingCount: 0,
                totalValueCents: 0
            )
        }

        return SimpleEntry(
            date: snapshot.generatedAt,
            scansToday: snapshot.scansToday,
            submittedCount: snapshot.submittedCount,
            failedCount: snapshot.failedCount,
            pendingCount: snapshot.pendingCount,
            totalValueCents: snapshot.totalValueCents
        )
    }

    private var sharedDefaults: UserDefaults? {
        let configuredID = (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = (configuredID?.isEmpty == false) ? configuredID : "group.com.mikey.POScannerApp"
        return UserDefaults(suiteName: groupID)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let scansToday: Int
    let submittedCount: Int
    let failedCount: Int
    let pendingCount: Int
    let totalValueCents: Int
}

struct ShopMikey_ScannerEntryView : View {
    var entry: Provider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Parts Intake", systemImage: "doc.text.viewfinder")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(entry.date, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                metric(title: "Scans", value: entry.scansToday)
                metric(title: "Submitted", value: entry.submittedCount)
                metric(title: "Retry", value: entry.failedCount)
            }

            ProgressView(value: progress)
                .tint(.accentColor)

            Text(totalValueString)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var progress: Double {
        guard entry.scansToday > 0 else { return 0 }
        return min(1, Double(entry.submittedCount) / Double(entry.scansToday))
    }

    private var totalValueString: String {
        let value = Double(entry.totalValueCents) / 100
        return value.formatted(.currency(code: "USD"))
    }

    private func metric(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShopMikey_Scanner: Widget {
    let kind: String = "ShopMikey_Scanner"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            ShopMikey_ScannerEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Parts Intake")
        .description("Snapshot of today’s Shopmikey parts intake pipeline.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemMedium) {
    ShopMikey_Scanner()
} timeline: {
    SimpleEntry(
        date: .now,
        scansToday: 18,
        submittedCount: 14,
        failedCount: 2,
        pendingCount: 2,
        totalValueCents: 9088003
    )
}
