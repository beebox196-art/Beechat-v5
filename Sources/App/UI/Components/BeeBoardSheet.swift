import SwiftUI
import BeeBoard

struct BeeBoardSheet: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = BeeBoardViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .background(themeManager.color(.borderSubtle))

            ZStack(alignment: .top) {
                BeeBoardCanvasView(viewModel: viewModel)

                if viewModel.isLoading {
                    ProgressView("Loading BeeBoard…")
                        .padding(themeManager.spacing(.lg))
                        .background(themeManager.color(.bgPanel))
                        .clipShape(RoundedRectangle(cornerRadius: themeManager.radius(.lg)))
                        .padding(.top, themeManager.spacing(.xl))
                }
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(themeManager.color(.bgSurface))
        .onAppear { viewModel.load() }
        .sheet(isPresented: $viewModel.isCreatingGroup) {
            BeeBoardCreateGroupSheet(
                palette: BeeBoardViewModel.warmAuroraPalette,
                onCreate: { name, colorHex in
                    viewModel.createGroup(name: name, colorHex: colorHex)
                }
            )
            .environment(themeManager)
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.detailPinId != nil },
                set: { isPresented in
                    if !isPresented { viewModel.closeDetail() }
                }
            )
        ) {
            if let detailPinId = viewModel.detailPinId,
               let pinIndex = viewModel.pins.firstIndex(where: { $0.id == detailPinId }) {
                BeeBoardPinDetailView(pin: viewModel.binding(for: viewModel.pins[pinIndex]))
                    .environment(themeManager)
            }
        }
        .alert(
            "Delete Pin?",
            isPresented: Binding(
                get: { viewModel.pinPendingDelete != nil },
                set: { isPresented in
                    if !isPresented { viewModel.cancelDelete() }
                }
            )
        ) {
            Button("Cancel", role: .cancel) { viewModel.cancelDelete() }
            Button("Delete", role: .destructive) { viewModel.confirmDelete() }
        } message: {
            Text("This removes the pin from BeeBoard.")
        }
        .alert(
            "BeeBoard Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { isPresented in
                    if !isPresented { viewModel.errorMessage = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack(spacing: themeManager.spacing(.md)) {
            Button(action: { viewModel.createPinAtCenter() }) {
                Image(systemName: "plus.circle")
                    .font(themeManager.font(.subheading))
                    .foregroundColor(themeManager.color(.accentPrimary))
            }
            .buttonStyle(.plain)
            .help("Create Pin")

            Button(action: { viewModel.toggleSelectionMode() }) {
                Image(systemName: viewModel.isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(themeManager.font(.subheading))
                    .foregroundColor(viewModel.isSelectionMode ? themeManager.color(.accentPrimary) : themeManager.color(.textSecondary))
            }
            .buttonStyle(.plain)
            .help("Selection Mode")

            Button("Group") {
                viewModel.isCreatingGroup = true
            }
            .disabled(viewModel.selectedPinIds.count < 2)
            .foregroundColor(viewModel.selectedPinIds.count >= 2 ? themeManager.color(.accentPrimary) : themeManager.color(.textSecondary))

            Picker("Sort", selection: sortBinding) {
                Text("Manual").tag(BeeBoardSortOption?.none)
                ForEach(BeeBoardSortOption.allCases) { option in
                    Text(option.rawValue).tag(BeeBoardSortOption?.some(option))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)

            if viewModel.canUndoSort {
                Button("Undo Sort") {
                    viewModel.undoSort()
                }
                .foregroundColor(themeManager.color(.accentPrimary))
            }

            TextField("Search pins…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(themeManager.font(.body))
                .foregroundColor(themeManager.color(.textPrimary))
                .frame(width: 160)
                .padding(.horizontal, themeManager.spacing(.sm))
                .padding(.vertical, themeManager.spacing(.xs))
                .background(
                    RoundedRectangle(cornerRadius: themeManager.radius(.md))
                        .fill(themeManager.color(.bgPanel))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: themeManager.radius(.md))
                        .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
                )

            Spacer()

            Text("BeeBoard")
                .font(themeManager.font(.heading))
                .foregroundColor(themeManager.color(.textPrimary))

            Spacer()

            Button("Done") {
                dismiss()
            }
            .font(themeManager.font(.subheading))
            .foregroundColor(themeManager.color(.accentPrimary))
        }
        .padding(.horizontal, themeManager.spacing(.xl))
        .padding(.vertical, themeManager.spacing(.lg))
    }

    private var sortBinding: Binding<BeeBoardSortOption?> {
        Binding(
            get: { viewModel.activeSortOption },
            set: { option in
                if let option { viewModel.applySort(option) }
            }
        )
    }
}

#Preview {
    BeeBoardSheet()
        .environment(ThemeManager())
}
