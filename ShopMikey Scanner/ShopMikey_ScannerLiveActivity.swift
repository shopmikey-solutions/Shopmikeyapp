//
//  ShopMikey_ScannerLiveActivity.swift
//  ShopMikey Scanner
//
//  Created by Michael Bordeaux on 2/18/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct PartsIntakeActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var statusText: String
        var detailText: String
        var progress: Double
        var updatedAt: Date
        var deepLinkURL: String?
    }

    var title: String
}

struct ShopMikey_ScannerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PartsIntakeActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(context.attributes.title, systemImage: "doc.text.viewfinder")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(context.state.updatedAt, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(context.state.statusText)
                    .font(.headline)
                    .lineLimit(1)

                ProgressView(value: clampedProgress(context.state.progress))
                    .tint(.accentColor)

                Text(context.state.detailText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .activityBackgroundTint(Color.accentColor.opacity(0.14))
            .activitySystemActionForegroundColor(.primary)
            .widgetURL(deepLinkURL(for: context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Intake", systemImage: "doc.text.viewfinder")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.accentColor)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int((clampedProgress(context.state.progress) * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.statusText)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        ProgressView(value: clampedProgress(context.state.progress))
                            .tint(.accentColor)
                        Text(context.state.detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } compactLeading: {
                Image(systemName: "doc.text.viewfinder")
            } compactTrailing: {
                Text("\(Int((clampedProgress(context.state.progress) * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "doc.text.viewfinder")
            }
            .widgetURL(deepLinkURL(for: context))
            .keylineTint(Color.accentColor)
        }
    }

    private func clampedProgress(_ progress: Double) -> Double {
        min(1, max(0.02, progress))
    }

    private func deepLinkURL(for context: ActivityViewContext<PartsIntakeActivityAttributes>) -> URL? {
        if let raw = context.state.deepLinkURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "shopmikey://scan?compose=1")
    }
}

extension PartsIntakeActivityAttributes {
    fileprivate static var preview: PartsIntakeActivityAttributes {
        PartsIntakeActivityAttributes(title: "Parts Intake")
    }
}

extension PartsIntakeActivityAttributes.ContentState {
    fileprivate static var parsing: PartsIntakeActivityAttributes.ContentState {
        PartsIntakeActivityAttributes.ContentState(
            statusText: "Classifying parts",
            detailText: "Applying on-device AI and deterministic rules.",
            progress: 0.64,
            updatedAt: .now,
            deepLinkURL: "shopmikey://scan?compose=1"
        )
    }

    fileprivate static var finalizing: PartsIntakeActivityAttributes.ContentState {
        PartsIntakeActivityAttributes.ContentState(
            statusText: "Preparing review",
            detailText: "Finishing purchase-order intake checks.",
            progress: 0.9,
            updatedAt: .now,
            deepLinkURL: "shopmikey://scan?compose=1"
        )
    }
}

#Preview("Notification", as: .content, using: PartsIntakeActivityAttributes.preview) {
   ShopMikey_ScannerLiveActivity()
} contentStates: {
    PartsIntakeActivityAttributes.ContentState.parsing
    PartsIntakeActivityAttributes.ContentState.finalizing
}
