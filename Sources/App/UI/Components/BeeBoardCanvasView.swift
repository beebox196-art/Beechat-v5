import SwiftUI
import BeeBoard

struct BeeBoardCanvasView: View {
    @Environment(ThemeManager.self) var themeManager
    @Bindable var viewModel: BeeBoardViewModel

    private let canvasSize = CGSize(width: 1800, height: 1200)

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                canvasBackground

                if viewModel.pins.isEmpty {
                    emptyState
                        .position(x: 420, y: 260)
                }

                ForEach(viewModel.pins) { pin in
                    BeeBoardPinCard(
                        pin: viewModel.binding(for: pin),
                        isSelected: viewModel.selectedPinId == pin.id,
                        palette: BeeBoardViewModel.warmAuroraPalette,
                        onSelect: { viewModel.select(pinId: pin.id) },
                        onMove: { point in viewModel.movePin(id: pin.id, to: point) },
                        onRequestDelete: { viewModel.requestDelete(pinId: pin.id) },
                        onExpand: { viewModel.openDetail(pinId: pin.id) },
                        onAddTag: { tag in viewModel.addTag(pinId: pin.id, tag: tag) },
                        onRemoveTag: { tag in viewModel.removeTag(pinId: pin.id, tag: tag) },
                        onUpdatePriority: { prio in viewModel.updatePriority(pinId: pin.id, priority: prio) }
                    )
                    .position(
                        x: CGFloat(pin.positionX),
                        y: CGFloat(pin.positionY)
                    )
                    .opacity(viewModel.matchingPinIds.contains(pin.id) ? 1.0 : 0.25)
                    .zIndex(viewModel.selectedPinId == pin.id ? 2 : 1)
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
        .background(themeManager.color(.bgSurface))
    }

    private var canvasBackground: some View {
        Rectangle()
            .fill(themeManager.color(.bgSurface))
            .overlay(alignment: .topLeading) {
                subtleGrid
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        viewModel.createPin(at: value.location)
                    }
            )
            .simultaneousGesture(
                TapGesture()
                    .onEnded {
                        viewModel.selectedPinId = nil
                    }
            )
    }

    private var subtleGrid: some View {
        Canvas { context, size in
            let spacing: CGFloat = 40
            let color = themeManager.color(.borderSubtle).opacity(0.35)

            var path = Path()

            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }

            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }

            context.stroke(path, with: .color(color), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private var emptyState: some View {
        VStack(spacing: themeManager.spacing(.md)) {
            Image(systemName: "pin.square")
                .font(.system(size: 36))
                .foregroundColor(themeManager.color(.textSecondary).opacity(0.55))

            Text("Double-click the canvas to create a pin")
                .font(themeManager.font(.subheading))
                .foregroundColor(themeManager.color(.textPrimary))

            Text("Or use the + button above.")
                .font(themeManager.font(.body))
                .foregroundColor(themeManager.color(.textSecondary))
        }
        .padding(themeManager.spacing(.xl))
        .background(
            RoundedRectangle(cornerRadius: themeManager.radius(.xl))
                .fill(themeManager.color(.bgPanel).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: themeManager.radius(.xl))
                .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
        )
        .allowsHitTesting(false)
    }
}

#Preview {
    BeeBoardCanvasView(viewModel: BeeBoardViewModel())
        .environment(ThemeManager())
}
