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
        Group {
            if isLoading && services.isEmpty {
                ProgressView("Loading Shopmonkey services…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, services.isEmpty {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Couldn't Load Shopmonkey Services",
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
                    "No Services Found",
                    systemImage: "wrench.and.screwdriver",
                    description: Text("No services were returned for this order in Shopmonkey.")
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
                .listStyle(.insetGrouped)
                .nativeListSurface()
                .refreshable {
                    await fetchServices()
                }
            }
        }
        .navigationTitle("Select Shopmonkey Service")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .task {
            await fetchServices()
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

#if DEBUG
#Preview("Service Picker") {
    ServicePickerView(
        service: PreviewFixtures.previewShopmonkeyService,
        orderId: "preview-order-1"
    ) { _ in }
}
#endif
