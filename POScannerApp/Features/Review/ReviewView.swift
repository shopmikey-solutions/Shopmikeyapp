//
//  ReviewView.swift
//  POScannerApp
//

import SwiftUI

struct ReviewView: View {
    private enum FocusedField: Hashable {
        case vendor
        case vendorPhone
        case vendorEmail
        case invoice
        case po
        case order
        case service
    }

    @AppStorage("experimentalOrderPOLinking") private var experimentalOrderPOLinking: Bool = false
    @StateObject var viewModel: ReviewViewModel
    @State private var focusNeedsReviewOnly: Bool = false
    @State private var hasLoadedInitialMetrics: Bool = false
    @FocusState private var focusedField: FocusedField?
    @Environment(\.dismiss) private var dismiss

    init(environment: AppEnvironment, parsedInvoice: ParsedInvoice, draftSnapshot: ReviewDraftSnapshot? = nil) {
        _viewModel = StateObject(
            wrappedValue: ReviewViewModel(
                environment: environment,
                parsedInvoice: parsedInvoice,
                draftSnapshot: draftSnapshot
            )
        )
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage, !error.isEmpty {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if let status = viewModel.statusMessage, !status.isEmpty {
                Section {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppSurfaceStyle.success)
                }
            }

            Section("Parts Intake Status") {
                reviewHealthCard
                if viewModel.confidenceScore < 0.75 {
                    Label("Some intake fields still need review.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppSurfaceStyle.warning)
                }
            }

            Section("Vendor") {
                vendorSection
            }

            Section {
                identifierSection
            } header: {
                Text("Invoice & PO")
            }

            Section("Parts, Tires & Fees to Add") {
                if canFilterNeedsReview {
                    Toggle("Focus on items needing review", isOn: $focusNeedsReviewOnly)
                        .accessibilityIdentifier("review.focusNeedsReviewToggle")
                }

                if !viewModel.items.isEmpty {
                    Text("Swipe right to set type quickly, swipe left to delete.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                itemsList

                Button {
                    AppHaptics.impact(.light, intensity: 0.8)
                    viewModel.addEmptyItem()
                } label: {
                    Label("Add Part Line", systemImage: "plus")
                }
                .appSecondaryActionButton()
            }

            Section("Shopmonkey Destination") {
                if experimentalOrderPOLinking {
                    submissionModePicker
                    submissionContextLinks
                } else {
                    Text("Production mode keeps this simple: add scanned lines to a Shopmonkey draft purchase order.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                taxBehaviorRow
                Text(experimentalOrderPOLinking ? viewModel.modeGuidanceText : "Enable Experimental Order / PO Linking in Settings > Diagnostics for advanced add-to-order and add-to-PO tools.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Save Intake Draft") {
                    AppHaptics.impact(.light, intensity: 0.85)
                    Task { await viewModel.saveDraft() }
                }
                .appSecondaryActionButton()
                .accessibilityIdentifier("review.saveDraftButton")

                if let lastSaved = viewModel.lastDraftSavedAt {
                    Text("Saved \(lastSaved.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if viewModel.activeDraftID != nil {
                    Button("Discard Saved Draft", role: .destructive) {
                        AppHaptics.warning()
                        Task { await viewModel.discardDraft() }
                    }
                }
            }

            Section("PO Totals") {
                LabeledContent("Subtotal", value: viewModel.subtotalFormatted)
                if !viewModel.shouldIgnoreTax {
                    LabeledContent("Tax", value: viewModel.taxFormatted)
                }
                LabeledContent("Total", value: viewModel.grandTotalFormatted)
                    .font(.headline)
                LabeledContent("Scans Today", value: "\(viewModel.todayCount)")
            }

            Section("Parts Intake Notes") {
                NativeTextView(
                    text: $viewModel.notes,
                    placeholder: "Add notes for parts intake or Shopmonkey handoff",
                    accessibilityIdentifier: "review.notesField"
                )
                    .frame(minHeight: 120)
            }

            #if DEBUG
            Section("Debug Metrics") {
                LabeledContent("Unknown Type Rate", value: percentageString(viewModel.unknownKindRate))
                LabeledContent("Type Overrides", value: String(viewModel.typeOverrideCount))
                LabeledContent("Vendor Auto-Select", value: percentageString(viewModel.vendorAutoSelectSuccessRate))
            }
            #endif
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .keyboardDoneToolbar()
        .scrollDismissesKeyboard(.interactively)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Parts Intake Review")
        .navigationBarTitleDisplayMode(.inline)
        .onSubmit {
            advanceKeyboardFocus()
        }
        .animation(.snappy(duration: 0.24), value: focusNeedsReviewOnly)
        .animation(.snappy(duration: 0.24), value: filteredItemIndices.count)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if canEditItems {
                    EditButton()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(viewModel.isSubmitting ? "Submitting..." : submitButtonTitle) {
                    AppHaptics.impact(.medium, intensity: 0.9)
                    Task { await viewModel.submitTapped() }
                }
                .disabled(!viewModel.canSubmit || viewModel.isSubmitting)
                .accessibilityIdentifier("review.submitButton")
            }
        }
        .alert("Submission Complete", isPresented: $viewModel.showSuccessAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text("Parts, tires, and fees were sent to Shopmonkey.")
        }
        .onAppear {
            if !hasLoadedInitialMetrics {
                hasLoadedInitialMetrics = true
                viewModel.loadTodayMetrics()
            }
            if !experimentalOrderPOLinking {
                viewModel.applyProductionPolishMode()
            }
        }
        .onDisappear {
            Task { await viewModel.persistDraftOnExitIfNeeded() }
        }
        .onChange(of: experimentalOrderPOLinking) { _, enabled in
            if !enabled {
                viewModel.applyProductionPolishMode()
            }
        }
        .onChange(of: viewModel.modeUI) { _, _ in
            AppHaptics.selection()
        }
        .onChange(of: viewModel.showSuccessAlert) { _, presented in
            if presented { AppHaptics.success() }
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            if message != nil { AppHaptics.error() }
        }
    }

    private var reviewHealthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Readiness") {
                Text("\(Int((viewModel.reviewReadinessScore * 100).rounded()))%")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: viewModel.reviewReadinessScore)
                .animation(.smooth(duration: 0.24), value: viewModel.reviewReadinessScore)

            LabeledContent("Line Items") {
                Text("\(viewModel.items.count)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            LabeledContent("Needs Review") {
                Text("\(viewModel.unknownKindCount)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            Text(viewModel.canSubmit ? "Ready to add lines in Shopmonkey." : "Pick a vendor match and required IDs before sending.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("review.readinessHint")
        }
    }

    private var vendorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                viewModel.vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (viewModel.suggestedVendorName ?? "Vendor")
                    : "Vendor",
                text: Binding(
                    get: { viewModel.vendorName },
                    set: { viewModel.setVendorName($0) }
                )
            )
            .textInputAutocapitalization(.words)
            .focused($focusedField, equals: .vendor)
            .submitLabel(.next)
            .accessibilityIdentifier("review.vendorField")

            if !viewModel.vendorSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Potential vendor matches")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(viewModel.vendorSuggestions.prefix(5)) { vendor in
                        Button {
                            viewModel.selectVendorSuggestion(vendor)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vendor.name)
                                        .foregroundStyle(.primary)
                                    if let detail = vendorContactSummary(for: vendor) {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if viewModel.selectedVendorId == vendor.id ||
                                    vendor.name.normalizedVendorName == viewModel.vendorName.normalizedVendorName {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AppSurfaceStyle.success)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            TextField("Vendor Phone (optional)", text: $viewModel.vendorPhone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused($focusedField, equals: .vendorPhone)
                .submitLabel(.next)
                .accessibilityIdentifier("review.vendorPhoneField")

            TextField("Vendor Email (optional)", text: $viewModel.vendorEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textContentType(.emailAddress)
                .focused($focusedField, equals: .vendorEmail)
                .submitLabel(.next)
                .accessibilityIdentifier("review.vendorEmailField")

            NativeTextView(
                text: $viewModel.vendorNotes,
                placeholder: "Vendor notes (optional)",
                accessibilityIdentifier: "review.vendorNotesField"
            )
            .frame(minHeight: 84)

            Label(
                viewModel.selectedVendorId == nil ? "Vendor not selected" : "Vendor selected",
                systemImage: viewModel.selectedVendorId == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(viewModel.selectedVendorId == nil ? AppSurfaceStyle.warning : AppSurfaceStyle.success)

            if let suggestedVendorName = viewModel.suggestedVendorName, !suggestedVendorName.isEmpty {
                Text("OCR suggested vendor: \(suggestedVendorName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if viewModel.vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let suggestedVendorName = viewModel.suggestedVendorName,
               !suggestedVendorName.isEmpty {
                Button("Use vendor suggestion: \(suggestedVendorName)") {
                    viewModel.applySuggestedVendorName()
                }
                .font(.footnote)
            }

            if viewModel.selectedVendorId == nil {
                Button {
                    AppHaptics.impact(.light, intensity: 0.85)
                    Task { await viewModel.createVendorFromCurrentInput() }
                } label: {
                    Label(
                        viewModel.isCreatingVendor ? "Creating Vendor..." : "Create Vendor",
                        systemImage: "person.crop.circle.badge.plus"
                    )
                }
                .appSecondaryActionButton()
                .disabled(!viewModel.canCreateVendorFromCurrentInput || viewModel.isCreatingVendor)
                .accessibilityIdentifier("review.createVendorButton")

                Text("No match found? Create a new Shopmonkey vendor with these contact details.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var identifierSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                viewModel.vendorInvoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (viewModel.suggestedInvoiceNumber ?? "Vendor Invoice Number")
                    : "Vendor Invoice Number",
                text: $viewModel.vendorInvoiceNumber
            )
            .textInputAutocapitalization(.characters)
            .focused($focusedField, equals: .invoice)
            .submitLabel(.next)

            if viewModel.vendorInvoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let suggestedInvoice = viewModel.suggestedInvoiceNumber,
               !suggestedInvoice.isEmpty {
                Button("Use invoice suggestion: \(suggestedInvoice)") {
                    viewModel.applySuggestedInvoiceNumber()
                }
                .font(.footnote)
            }

            TextField(
                viewModel.poReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (viewModel.suggestedPONumber ?? "PO Reference (optional)")
                    : "PO Reference (optional)",
                text: Binding(
                    get: { viewModel.poReference },
                    set: { viewModel.setPOReference($0) }
                )
            )
            .textInputAutocapitalization(.characters)
            .focused($focusedField, equals: .po)
            .submitLabel(.done)

            if viewModel.poReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let suggestedPO = viewModel.suggestedPONumber,
               !suggestedPO.isEmpty {
                Button("Use PO suggestion: \(suggestedPO)") {
                    viewModel.applySuggestedPONumber()
                }
                .font(.footnote)
            }

            if experimentalOrderPOLinking, let poMatch = viewModel.purchaseOrderMatchMessage, !poMatch.isEmpty {
                Text(poMatch)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var submissionModePicker: some View {
        NativeSegmentedControl(
            options: ReviewViewModel.ModeUI.allCases,
            titleForOption: modeTitle(for:),
            selection: $viewModel.modeUI,
            accessibilityIdentifier: "review.modePicker"
        )
    }

    @ViewBuilder
    private var submissionContextLinks: some View {
        switch viewModel.modeUI {
        case .attach:
            NavigationLink("Select Draft Purchase Order") {
                PurchaseOrderPickerView(service: viewModel.shopmonkeyService) { purchaseOrder in
                    viewModel.selectPurchaseOrder(purchaseOrder, forceAttachMode: true)
                }
            }

            if let selectedPO = viewModel.selectedPurchaseOrder {
                LabeledContent("Selected PO", value: selectedPO.number ?? selectedPO.id)
                Label(
                    selectedPO.isDraft ? "Draft PO ready" : "PO is \(selectedPO.status)",
                    systemImage: selectedPO.isDraft ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(selectedPO.isDraft ? AppSurfaceStyle.success : AppSurfaceStyle.warning)
            } else {
                Text("No PO selected. Submitting in Attach mode creates a new draft purchase order.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            TextField("Order ID (optional PO link)", text: orderIdBinding)
                .focused($focusedField, equals: .order)
                .submitLabel(.done)

        case .quickAdd:
            Text("Add to Order is inventory-first: barcode/SKU lines post directly to a Shopmonkey order service.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            NavigationLink("Select Shopmonkey Order") {
                OrderPickerView(service: viewModel.shopmonkeyService) { order in
                    viewModel.selectOrder(order)
                }
            }

            if let selectedOrder = viewModel.selectedOrder {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedOrder.orderName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                         ? (selectedOrder.orderName ?? selectedOrder.displayTitle)
                         : selectedOrder.displayTitle)
                        .font(.subheadline.weight(.semibold))
                    if let number = selectedOrder.number?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !number.isEmpty {
                        Text("Order #\(number)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let customer = selectedOrder.customerName?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !customer.isEmpty {
                        Text(customer)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            TextField("Order ID", text: orderIdBinding)
                .focused($focusedField, equals: .order)
                .submitLabel(.next)

            if !orderIdBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NavigationLink("Select Ticket / Service") {
                    ServicePickerView(
                        service: viewModel.shopmonkeyService,
                        orderId: orderIdBinding.wrappedValue
                    ) { service in
                        viewModel.selectService(service)
                    }
                }
            }

            TextField("Ticket / Service ID", text: serviceIdBinding)
                .focused($focusedField, equals: .service)
                .submitLabel(.done)

            NavigationLink("Link to Draft PO (optional)") {
                PurchaseOrderPickerView(service: viewModel.shopmonkeyService) { purchaseOrder in
                    viewModel.selectPurchaseOrder(purchaseOrder)
                }
            }

        case .restock:
            Text("Restock PO keeps inventory procurement in a draft purchase order workflow.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            NavigationLink("Select Draft Purchase Order") {
                PurchaseOrderPickerView(service: viewModel.shopmonkeyService) { purchaseOrder in
                    viewModel.selectPurchaseOrder(purchaseOrder)
                }
            }

            if let selectedPO = viewModel.selectedPurchaseOrder {
                LabeledContent("Selected PO", value: selectedPO.number ?? selectedPO.id)
                Label(
                    selectedPO.isDraft ? "Draft PO selected" : "PO is \(selectedPO.status)",
                    systemImage: selectedPO.isDraft ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(selectedPO.isDraft ? AppSurfaceStyle.success : AppSurfaceStyle.warning)
            }

            TextField("Order ID (optional)", text: orderIdBinding)
                .focused($focusedField, equals: .order)
                .submitLabel(.done)
        }
    }

    private var taxBehaviorRow: some View {
        Toggle("Ignore tax and totals", isOn: $viewModel.ignoreTaxOverride)
    }

    @ViewBuilder
    private var itemsList: some View {
        if filteredItemIndices.isEmpty {
            Text("No line items match the current filter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        ForEach(filteredItemIndices, id: \.self) { index in
            let itemBinding = $viewModel.items[index]
            NavigationLink {
                LineItemEditView(item: itemBinding) { oldKind, newKind in
                    viewModel.recordTypeOverride(from: oldKind, to: newKind)
                }
            } label: {
                lineItemRow(item: viewModel.items[index])
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                kindSwipeButton(title: "Part", kind: .part, color: AppSurfaceStyle.info, at: index)
                kindSwipeButton(title: "Tire", kind: .tire, color: AppSurfaceStyle.warning, at: index)
                kindSwipeButton(title: "Fee", kind: .fee, color: .teal, at: index)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    AppHaptics.warning()
                    viewModel.deleteItems(at: IndexSet(integer: index))
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .moveDisabled(focusNeedsReviewOnly)
        }
        .onDelete(perform: deleteFilteredItems)
        .onMove(perform: moveFilteredItems)
    }

    private var canEditItems: Bool {
        !focusNeedsReviewOnly && viewModel.items.count > 1
    }

    private var canFilterNeedsReview: Bool {
        viewModel.unknownKindCount > 0 || viewModel.suggestedKindCount > 0
    }

    private var filteredItemIndices: [Int] {
        let allIndices = Array(viewModel.items.indices)
        guard focusNeedsReviewOnly, canFilterNeedsReview else { return allIndices }
        return allIndices.filter { index in
            let item = viewModel.items[index]
            return item.kind == .unknown || item.isKindConfidenceMedium
        }
    }

    private func deleteFilteredItems(at offsets: IndexSet) {
        let sourceIndices = offsets.compactMap { offset in
            filteredItemIndices.indices.contains(offset) ? filteredItemIndices[offset] : nil
        }
        let mapped = IndexSet(sourceIndices)
        viewModel.deleteItems(at: mapped)
    }

    private func moveFilteredItems(from source: IndexSet, to destination: Int) {
        guard !focusNeedsReviewOnly else { return }
        viewModel.moveItems(from: source, to: destination)
    }

    private func kindSwipeButton(title: String, kind: POItemKind, color: Color, at index: Int) -> some View {
        Button(title) {
            AppHaptics.selection()
            viewModel.setItemKind(at: index, to: kind)
        }
        .tint(color)
    }

    private func lineItemRow(item: POItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Item" : item.description)
                .font(.body)

            HStack(spacing: 8) {
                Label(item.kind.displayName, systemImage: kindSymbol(for: item.kind))
                    .font(.footnote)
                    .foregroundStyle(kindTint(for: item.kind))

                if item.kind == .unknown {
                    Text("Needs review")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if item.isKindConfidenceMedium {
                    Text("Suggested")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !item.sku.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(item.sku)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack {
                Text("\(quantityString(item.quantity)) x \(item.unitPriceFormatted)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                Text(item.subtotalFormatted)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let feeHint = item.feeInferenceHint {
                Text(feeHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func kindTint(for kind: POItemKind) -> Color {
        switch kind {
        case .part:
            return AppSurfaceStyle.info
        case .tire:
            return AppSurfaceStyle.warning
        case .fee:
            return .teal
        case .unknown:
            return .gray
        }
    }

    private func kindSymbol(for kind: POItemKind) -> String {
        switch kind {
        case .part:
            return "shippingbox"
        case .tire:
            return "circle.grid.cross"
        case .fee:
            return "dollarsign.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private func quantityString(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    private func percentageString(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func vendorContactSummary(for vendor: VendorSummary) -> String? {
        let phone = vendor.phone?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = vendor.email?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let phone, !phone.isEmpty, let email, !email.isEmpty {
            return "\(phone) • \(email)"
        }
        if let phone, !phone.isEmpty {
            return phone
        }
        if let email, !email.isEmpty {
            return email
        }
        return nil
    }

    private var orderIdBinding: Binding<String> {
        Binding(
            get: { viewModel.orderId },
            set: { viewModel.setOrderIdManually($0) }
        )
    }

    private var serviceIdBinding: Binding<String> {
        Binding(
            get: { viewModel.serviceId },
            set: { viewModel.setServiceIdManually($0) }
        )
    }

    private func modeTitle(for mode: ReviewViewModel.ModeUI) -> String {
        switch mode {
        case .attach:
            return "Add to PO"
        case .quickAdd:
            return "Add to Order"
        case .restock:
            return "Restock PO"
        }
    }

    private var submitButtonTitle: String {
        if !experimentalOrderPOLinking {
            return "Add to Purchase Order"
        }

        switch viewModel.modeUI {
        case .attach, .restock:
            return "Add to Purchase Order"
        case .quickAdd:
            return "Add to Order"
        }
    }

    private func advanceKeyboardFocus() {
        switch focusedField {
        case .vendor:
            focusedField = .vendorPhone
        case .vendorPhone:
            focusedField = .vendorEmail
        case .vendorEmail:
            focusedField = .invoice
        case .invoice:
            focusedField = .po
        case .po:
            focusedField = nil
        case .order:
            focusedField = viewModel.modeUI == .quickAdd ? .service : nil
        case .service:
            focusedField = nil
        case .none:
            break
        }
    }
}

#if DEBUG
#Preview("Review") {
    NavigationStack {
        ReviewView(
            environment: PreviewFixtures.makeEnvironment(seedHistory: true),
            parsedInvoice: PreviewFixtures.parsedInvoice
        )
    }
}
#endif
