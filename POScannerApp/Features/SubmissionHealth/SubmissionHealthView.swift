//
//  SubmissionHealthView.swift
//  POScannerApp
//

import SwiftUI
import ShopmikeyCoreSync

struct SubmissionHealthView: View {
    @StateObject private var viewModel: SubmissionHealthViewModel

    init(syncOperationQueue: SyncOperationQueueStore) {
        _viewModel = StateObject(
            wrappedValue: SubmissionHealthViewModel(syncOperationQueue: syncOperationQueue)
        )
    }

    var body: some View {
        List {
            section(
                title: "Pending / Queued",
                sectionID: "submissionHealth.pendingSection",
                rows: viewModel.pendingRows
            )

            section(
                title: "Retrying",
                sectionID: "submissionHealth.retryingSection",
                rows: viewModel.retryingRows
            )

            section(
                title: "In Progress",
                sectionID: "submissionHealth.inProgressSection",
                rows: viewModel.inProgressRows
            )

            section(
                title: "Failed",
                sectionID: "submissionHealth.failedSection",
                rows: viewModel.failedRows
            )
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .navigationTitle("Submission Health")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("submissionHealth.list")
        .task {
            await viewModel.refresh()
        }
    }

    @ViewBuilder
    private func section(
        title: String,
        sectionID: String,
        rows: [SubmissionHealthViewModel.OperationRow]
    ) -> some View {
        Section {
            if rows.isEmpty {
                Text("No operations")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    OperationInspectorRow(row: row)
                }
            }
        } header: {
            Text(title)
                .accessibilityIdentifier(sectionID)
        }
    }
}
