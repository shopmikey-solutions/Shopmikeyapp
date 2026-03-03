//
//  ScanResultActionsView.swift
//  POScannerApp
//

import SwiftUI

struct ScanResultActionsView: View {
    @StateObject private var viewModel: ScanResultActionsViewModel

    init(viewModel: ScanResultActionsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        List {
            Section {
                labeledValueRow(title: "Scanned code", value: viewModel.scannedCode)
            }

            Section("Suggested next step") {
                if let suggestedAction = viewModel.suggestedAction {
                    actionRow(
                        suggestedAction,
                        accessibilityIdentifier: "scanNextStep.suggestedAction",
                        isSuggested: true
                    )
                } else {
                    Text("No suggestion yet. Choose an action below.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Actions") {
                actionRow(.addToTicket, accessibilityIdentifier: "scanNextStep.action.addToTicket")
                actionRow(.receivePO, accessibilityIdentifier: "scanNextStep.action.receivePO")
                actionRow(.restockDraft, accessibilityIdentifier: "scanNextStep.action.restockDraft")
                actionRow(.lookupInventory, accessibilityIdentifier: "scanNextStep.action.lookupInventory")
            }
        }
        .navigationTitle("Next step")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("scanNextStep.root")
    }

    @ViewBuilder
    private func actionRow(
        _ action: ScanResultActionsViewModel.Action,
        accessibilityIdentifier: String,
        isSuggested: Bool = false
    ) -> some View {
        let state = viewModel.state(for: action)

        VStack(alignment: .leading, spacing: 6) {
            if isSuggested {
                Button(action.title) {
                    viewModel.performSuggestedAction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.isEnabled)
                .accessibilityIdentifier(accessibilityIdentifier)
            } else {
                Button(action.title) {
                    viewModel.performAction(action)
                }
                .buttonStyle(.bordered)
                .disabled(!state.isEnabled)
                .accessibilityIdentifier(accessibilityIdentifier)
            }

            if let reason = state.reason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let cta = state.callToAction {
                Button(cta.title) {
                    viewModel.performCallToAction(cta)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(cta.accessibilityIdentifier)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func labeledValueRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.monospaced())
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }
}
