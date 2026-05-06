import SwiftUI
import BeeBoard

struct BeeBoardPinCard: View {
    @Environment(ThemeManager.self) var themeManager
    @Binding var pin: Pin

    let isSelected: Bool
    let palette: [String]
    let onSelect: () -> Void
    let onMove: (CGPoint) -> Void
    let onRequestDelete: () -> Void

    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: themeManager.spacing(.sm)) {
            header

            if isSelected {
                editFields
                colourPicker
            } else {
                readOnlyBody
            }

            Spacer(minLength: themeManager.spacing(.xs))

            Text(pin.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(themeManager.font(.caption2))
                .foregroundColor(themeManager.color(.textSecondary).opacity(0.75))
        }
        .padding(themeManager.spacing(.md))
        .frame(width: CGFloat(pin.width), height: CGFloat(pin.height), alignment: .topLeading)
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(
            color: themeManager.color(.shadowMedium),
            radius: isSelected ? 8 : 4,
            x: 0,
            y: isSelected ? 4 : 2
        )
        .contentShape(RoundedRectangle(cornerRadius: themeManager.radius(.lg)))
        .onTapGesture {
            onSelect()
        }
        .gesture(dragGesture)
        .contextMenu {
            Button("Delete Pin", role: .destructive) {
                onRequestDelete()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pin.title.isEmpty ? "Untitled pin" : pin.title)
        .accessibilityHint("Click to edit. Drag to move. Right-click for actions.")
    }

    private var header: some View {
        HStack(spacing: themeManager.spacing(.sm)) {
            Circle()
                .fill(Color(hex: pin.colorHex) ?? themeManager.color(.accentPrimary))
                .frame(width: 10, height: 10)

            if isSelected {
                TextField("Title", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(themeManager.font(.subheading))
                    .foregroundColor(themeManager.color(.textPrimary))
            } else {
                Text(pin.title.isEmpty ? "Untitled" : pin.title)
                    .font(themeManager.font(.subheading))
                    .foregroundColor(themeManager.color(.textPrimary))
                    .lineLimit(1)
            }
        }
    }

    private var editFields: some View {
        TextEditor(text: contentBinding)
            .font(themeManager.font(.body))
            .foregroundColor(themeManager.color(.textPrimary))
            .scrollContentBackground(.hidden)
            .background(themeManager.color(.bgElevated).opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: themeManager.radius(.md)))
            .overlay(
                RoundedRectangle(cornerRadius: themeManager.radius(.md))
                    .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
            )
    }

    private var readOnlyBody: some View {
        Group {
            if let content = pin.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(content)
                    .font(themeManager.font(.body))
                    .foregroundColor(themeManager.color(.textSecondary))
                    .lineLimit(3)
            } else {
                Text("No notes yet")
                    .font(themeManager.font(.body))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.65))
                    .italic()
            }
        }
    }

    private var colourPicker: some View {
        HStack(spacing: themeManager.spacing(.xs)) {
            ForEach(palette, id: \.self) { hex in
                Button {
                    pin.colorHex = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex) ?? themeManager.color(.accentPrimary))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(
                                    pin.colorHex == hex
                                        ? themeManager.color(.textPrimary)
                                        : themeManager.color(.borderSubtle),
                                    lineWidth: pin.colorHex == hex ? 2 : 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Set pin colour")
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: themeManager.radius(.lg))
            .fill(themeManager.color(.bgElevated))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: themeManager.radius(.lg))
            .stroke(
                isSelected ? themeManager.color(.accentPrimary) : themeManager.color(.borderSubtle),
                lineWidth: isSelected ? 2 : 1
            )
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil {
                    dragStart = CGPoint(x: pin.positionX, y: pin.positionY)
                    onSelect()
                }

                guard let dragStart else { return }
                let proposed = CGPoint(
                    x: dragStart.x + value.translation.width,
                    y: dragStart.y + value.translation.height
                )
                onMove(proposed)
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { pin.title },
            set: { pin.title = $0 }
        )
    }

    private var contentBinding: Binding<String> {
        Binding(
            get: { pin.content ?? "" },
            set: { pin.content = $0.isEmpty ? nil : $0 }
        )
    }
}

#Preview {
    BeeBoardPinCard(
        pin: .constant(
            Pin(
                boardId: "preview",
                title: "Example pin",
                content: "A manually created BeeBoard note.",
                colorHex: "#f5a623",
                positionX: 120,
                positionY: 100
            )
        ),
        isSelected: true,
        palette: BeeBoardViewModel.warmAuroraPalette,
        onSelect: {},
        onMove: { _ in },
        onRequestDelete: {}
    )
    .padding()
    .environment(ThemeManager())
}
