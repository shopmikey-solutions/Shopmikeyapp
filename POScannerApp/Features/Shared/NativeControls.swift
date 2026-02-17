//
//  NativeControls.swift
//  POScannerApp
//

import SwiftUI

struct NativeSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    let titleForOption: (Option) -> String
    @Binding var selection: Option
    var accessibilityIdentifier: String?

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(titleForOption(option))
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .modifier(OptionalAccessibilityIdentifier(id: accessibilityIdentifier))
    }
}

struct NativeTextView: View {
    @Binding var text: String
    var placeholder: String
    var accessibilityIdentifier: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
            }

            TextEditor(text: $text)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .modifier(OptionalAccessibilityIdentifier(id: accessibilityIdentifier))
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let id: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let id, !id.isEmpty {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

struct NativeListSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}

extension View {
    func nativeListSurface() -> some View {
        modifier(NativeListSurfaceModifier())
    }
}
