import SwiftUI
import BeeBoard

struct BeeBoardSheet: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = BeeBoardViewModel()
    @State private var archivedToastPinId: String?
    @State private var archiveUndoTimer: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .background(themeManager.color(.borderSubtle))

            ZStack(alignment: .top) {
                BeeBoardCanvasView(viewModel: viewModel, onPinArchived: triggerArchive)

                if viewModel.isLoading {
                    ProgressView("Loading BeeBoard…")
                        .padding(themeManager.spacing(.lg))
                        .background(themeManager.color(.bgPanel))
                        .clipShape(RoundedRectangle(cornerRadius: themeManager.radius(.lg)))
                        .padding(.top, themeManager.spacing(.xl))
                }
            }
        }
        .overlay(alignment: .bottom) {
            archiveToast
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(themeManager.color(.bgSurface))
        .onAppear { viewModel.load() }
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
                BeeBoardPinDetailView(
                    pin: viewModel.binding(for: viewModel.pins[pinIndex]),
                    onAddAttachment: { url in viewModel.addAttachment(from: url, to: detailPinId) },
                    onRemoveAttachment: { id in viewModel.removeAttachment(id: id, from: detailPinId) },
                    onAddLink: { url in viewModel.addLink(url: url, to: detailPinId) },
                    onRemoveLink: { id in viewModel.removeLink(id: id, from: detailPinId) }
                )
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
            .disabled(viewModel.showArchived)

            Picker("", selection: $viewModel.showArchived.animation(.easeInOut(duration: 0.25))) {
                Text("Active").tag(false)
                Text("Archived").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

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

    private var archiveToast: some View {
        Group {
            if let pinId = archivedToastPinId,
               let pin = viewModel.pins.first(where: { $0.id == pinId }) {
                HStack(spacing: themeManager.spacing(.md)) {
                    Image(systemName: "archivebox.fill")
                        .foregroundColor(themeManager.color(.accentPrimary))
                    Text("Archived \"\(pin.title.isEmpty ? "Untitled" : pin.title)\"")
                        .font(themeManager.font(.body))
                        .foregroundColor(themeManager.color(.textPrimary))
                    Spacer()
                    Button("Undo") {
                        archiveUndoTimer?.cancel()
                        archiveUndoTimer = nil
                        viewModel.restorePin(id: pinId)
                        withAnimation(.easeOut(duration: 0.2)) {
                            archivedToastPinId = nil
                        }
                    }
                    .font(themeManager.font(.subheading))
                    .foregroundColor(themeManager.color(.accentPrimary))
                }
                .padding(.horizontal, themeManager.spacing(.lg))
                .padding(.vertical, themeManager.spacing(.md))
                .background(
                    RoundedRectangle(cornerRadius: themeManager.radius(.lg))
                        .fill(themeManager.color(.bgPanel))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: themeManager.radius(.lg))
                        .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
                )
                .shadow(color: themeManager.color(.shadowMedium), radius: 8, x: 0, y: 4)
                .padding(.horizontal, themeManager.spacing(.xl))
                .padding(.bottom, themeManager.spacing(.lg))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func triggerArchive(pinId: String) {
        viewModel.archivePin(id: pinId)

        archiveUndoTimer?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) {
            archivedToastPinId = pinId
        }

        archiveUndoTimer = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    if archivedToastPinId == pinId {
                        archivedToastPinId = nil
                    }
                }
                archiveUndoTimer = nil
            }
        }
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
