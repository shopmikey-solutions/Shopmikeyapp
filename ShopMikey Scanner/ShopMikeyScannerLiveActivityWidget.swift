//
//  ShopMikeyScannerLiveActivityWidget.swift
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

struct ShopMikeyScannerLiveActivityWidget: Widget {
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
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    Label(stageLabel(for: context.state.statusText), systemImage: stageIconName(for: context.state.statusText))
                        .labelStyle(.iconOnly)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing, priority: 1) {
                    Text("\(progressPercent(clampedProgress(context.state.progress)))%")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.center, priority: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.statusText)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                        Text(context.state.detailText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                    }
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        ProgressView(value: clampedProgress(context.state.progress))
                            .tint(.accentColor)
                        Text(context.state.updatedAt, style: .relative)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "doc.text.viewfinder")
            } compactTrailing: {
                Text("\(progressPercent(clampedProgress(context.state.progress)))%")
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "doc.text.viewfinder")
            }
            .widgetURL(deepLinkURL(for: context))
            .keylineTint(Color.accentColor)
        }
    }

    private func clampedProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0.02 }
        return min(1, max(0.02, progress))
    }

    private func progressPercent(_ progress: Double) -> Int {
        Int((progress * 100).rounded())
    }

    private func stageLabel(for statusText: String) -> String {
        let normalized = statusText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("step 1") || normalized.contains("capture") {
            return "Capture"
        }
        if normalized.contains("step 2") || normalized.contains("ocr") || normalized.contains("parsing") {
            return "Review"
        }
        if normalized.contains("step 3") || normalized.contains("draft") {
            return "Draft"
        }
        if normalized.contains("step 4") || normalized.contains("submit") {
            return "Submit"
        }
        if normalized.contains("fail") {
            return "Attention"
        }
        return "Parts Intake"
    }

    private func stageIconName(for statusText: String) -> String {
        let normalized = statusText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("step 1") || normalized.contains("capture") {
            return "camera.viewfinder"
        }
        if normalized.contains("step 2") || normalized.contains("ocr") || normalized.contains("parsing") {
            return "doc.text.magnifyingglass"
        }
        if normalized.contains("step 3") || normalized.contains("draft") {
            return "square.and.pencil"
        }
        if normalized.contains("step 4") || normalized.contains("submit") {
            return "paperplane"
        }
        if normalized.contains("fail") {
            return "exclamationmark.triangle"
        }
        return "doc.text.viewfinder"
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
   ShopMikeyScannerLiveActivityWidget()
} contentStates: {
    PartsIntakeActivityAttributes.ContentState.parsing
    PartsIntakeActivityAttributes.ContentState.finalizing
}
