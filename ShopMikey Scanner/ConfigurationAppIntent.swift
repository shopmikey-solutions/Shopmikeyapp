//
//  ConfigurationAppIntent.swift
//  ShopMikey Scanner
//

import AppIntents

/// Backward-compatible widget intent to avoid "intentNotFound" when older widget activity
/// metadata references ConfigurationAppIntent.
struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Widget Configuration"
    static var description = IntentDescription("Configure the ShopMikey parts intake widget.")
}
