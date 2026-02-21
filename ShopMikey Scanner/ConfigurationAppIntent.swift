//
//  ConfigurationAppIntent.swift
//  ShopMikey Scanner
//

import AppIntents

/// Intentionally retained for backward compatibility.
/// The widget now uses ``StaticConfiguration``, but this intent remains to ensure
/// any stale extension metadata can still resolve cleanly.
@available(iOS 17.0, *)
public struct ConfigurationAppIntent: WidgetConfigurationIntent {
    public init() {}

    public static let title: LocalizedStringResource = "Widget Configuration"
    public static let description = IntentDescription("Configure the ShopMikey parts intake widget.")
}
