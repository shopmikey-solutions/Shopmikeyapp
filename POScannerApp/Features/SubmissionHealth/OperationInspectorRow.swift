//
//  OperationInspectorRow.swift
//  POScannerApp
//

import SwiftUI

struct OperationInspectorRow: View {
    let row: SubmissionHealthViewModel.OperationRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.title)
                .font(.headline)
            Text(row.subtitle)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(row.metadata)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let diagnostic = row.diagnostic {
                Text(diagnostic)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("submissionHealth.row.\(row.safeAccessibilityID)")
    }
}
