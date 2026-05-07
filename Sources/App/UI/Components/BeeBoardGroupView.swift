import SwiftUI
import BeeBoard

struct BeeBoardGroupView: View {
    @Environment(ThemeManager.self) var themeManager

    let groupFrame: BeeBoardGroupFrame
    let onMoveBy: (CGSize) -> Void

    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Group container
            RoundedRectangle(cornerRadius: themeManager.radius(.xl))
                .fill(groupColor.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: themeManager.radius(.xl))
                        .stroke(groupColor.opacity(0.55), lineWidth: 1.5)
                )

            // Header pill (draggable)
            header
                .padding(.top, 8)
                .padding(.leading, 12)
        }
        .frame(width: groupFrame.rect.width, height: groupFrame.rect.height)
        .offset(dragOffset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Group \(groupFrame.group.name), \(groupFrame.pinCount) pins")
    }

    private var header: some View {
        HStack(spacing: themeManager.spacing(.xs)) {
            Circle()
                .fill(groupColor)
                .frame(width: 9, height: 9)

            Text(groupFrame.group.name)
                .font(themeManager.font(.caption))
                .foregroundColor(themeManager.color(.textPrimary))
                .lineLimit(1)

            Text("\(groupFrame.pinCount)")
                .font(themeManager.font(.caption2))
                .foregroundColor(themeManager.color(.textSecondary))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(themeManager.color(.bgElevated).opacity(0.75))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(themeManager.color(.bgPanel).opacity(0.9))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(groupColor.opacity(0.45), lineWidth: 1)
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation
                }
                .onEnded { value in
                    onMoveBy(value.translation)
                    dragOffset = .zero
                }
        )
        .help("Drag to move group")
    }

    private var groupColor: Color {
        Color(hex: groupFrame.group.colorHex) ?? themeManager.color(.accentPrimary)
    }
}

#Preview {
    BeeBoardGroupView(
        groupFrame: BeeBoardGroupFrame(
            id: "preview",
            group: PinGroup(boardId: "board1", name: "Ideas", colorHex: "#8fa895"),
            rect: CGRect(x: 0, y: 0, width: 500, height: 400),
            pinCount: 3
        ),
        onMoveBy: { _ in }
    )
    .environment(ThemeManager())
}
