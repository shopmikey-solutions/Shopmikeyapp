//
//  ServicePickerView.swift
//  POScannerApp
//

import SwiftUI

struct ServicePickerView: View {
    @Environment(\.dismiss) private var dismiss

    let service: any ShopmonkeyServicing
    let orderId: String
    let onSelect: (ServiceSummary) -> Void

    @State private var services: [ServiceSummary] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && services.isEmpty {
                    ProgressView("Loading services…")
                } else if let errorMessage, services.isEmpty {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "Couldn’t Load Services",
                            systemImage: "exclamationmark.triangle",
                            description: Text(errorMessage)
                        )

                        Button("Retry") {
                            Task { await fetchServices() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if services.isEmpty {
                    ContentUnavailableView(
                        "No Services",
                        systemImage: "wrench.and.screwdriver",
                        description: Text("No services were returned for this order.")
                    )
                } else {
                    List {
                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }

                        ForEach(services) { service in
                            Button {
                                onSelect(service)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(service.name?.isEmpty == false ? (service.name ?? "") : "Service \(service.id)")
                                        .font(.headline)
                                    Text(service.id)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .refreshable {
                        await fetchServices()
                    }
                }
            }
            .navigationTitle("Select Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await fetchServices()
            }
        }
    }

    private func fetchServices() async {
        if isLoading { return }

        let safeOrderId = orderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeOrderId.isEmpty else {
            services = []
            errorMessage = "Order ID is required."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            services = try await service.fetchServices(orderId: safeOrderId)
        } catch {
            errorMessage = userMessage(for: error)
        }

        isLoading = false
    }
}
