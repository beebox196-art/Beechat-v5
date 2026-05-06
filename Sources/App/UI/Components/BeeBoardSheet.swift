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
        .frame(minWidth: 900, minHeight: 620)
        .background(themeManager.color(.bgSurface))
        .onAppear { viewModel.load() }
        .sheet(
            isPresented: Binding(
                get: { viewModel.detailPinId != nil },
                set: { if !$0 { viewModel.closeDetail() } }
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
                    if !isPresented {
                        viewModel.cancelDelete()
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelDelete()
            }
            Button("Delete", role: .destructive) {
                viewModel.confirmDelete()
            }
        } message: {
            Text("This removes the pin from BeeBoard.")
        }
        .alert(
            "BeeBoard Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack {
            Button(action: { viewModel.createPinAtCenter() }) {
                Image(systemName: "plus.circle")
                    .font(themeManager.font(.subheading))
                    .foregroundColor(themeManager.color(.accentPrimary))
            }
            .buttonStyle(.plain)
            .help("Create Pin")
            .accessibilityLabel("Create Pin")
            .accessibilityHint("Create a new manual pin on the board")

            Spacer()

            Text("BeeBoard")
                .font(themeManager.font(.heading))
                .foregroundColor(themeManager.color(.textPrimary))

            Spacer()

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

            Button("Done") {
                dismiss()
            }
            .font(themeManager.font(.subheading))
            .foregroundColor(themeManager.color(.accentPrimary))
        }
        .padding(.horizontal, themeManager.spacing(.xl))
        .padding(.vertical, themeManager.spacing(.lg))
    }
}

#Preview {
    BeeBoardSheet()
        .environment(ThemeManager())
}
