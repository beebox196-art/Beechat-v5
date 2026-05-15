import SwiftUI
import BeeBoard

struct BeeBoardPinCard: View {
    @Environment(ThemeManager.self) var themeManager
    @Binding var pin: Pin

    let isSelected: Bool
    let isDimmed: Bool
    let tags: [String]
    let tagPalette: [String]
    let onSelect: () -> Void
    let onMove: (CGPoint) -> Void
    let onRequestDelete: () -> Void
    let onExpand: () -> Void
    let onTagsChange: ([String]) -> Void
    let onUpdatePriority: (Int) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragOffset: CGSize = .zero
    @State private var tagInput = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: themeManager.spacing(.xs)) {
                header

                if isSelected {
                    editFields
                    priorityPicker
                    tagEditor
                } else {
                    readOnlyBody
                    tagPills
                }

                Spacer(minLength: themeManager.spacing(.xs))

                Text(pin.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.75))
            }
            .padding(themeManager.spacing(.sm))
        }
        .frame(width: CGFloat(pin.width), height: CGFloat(pin.height), alignment: .topLeading)
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(
            color: themeManager.color(.shadowMedium),
            radius: isSelected ? 8 : 3,
            x: 0,
            y: isSelected ? 4 : 1
        )
        .contentShape(RoundedRectangle(cornerRadius: themeManager.radius(.lg)))
        .offset(dragOffset)
        .onTapGesture {
            onSelect()
        }
        .onChange(of: isSelected) { _, selected in
            if selected && pin.title.isEmpty {
                isTitleFocused = true
            }
        }
        .gesture(dragGesture)
        .contextMenu {
            Menu("Priority") {
                ForEach([(0, "None"), (1, "Low"), (2, "Medium"), (3, "High"), (4, "Urgent")], id: \.0) { value, label in
                    Button(label) { onUpdatePriority(value) }
                }
            }
            Button("Expand Pin") { onExpand() }
            Divider()
            Button("Delete Pin", role: .destructive) { onRequestDelete() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pin.title.isEmpty ? "Untitled pin" : pin.title)
        .accessibilityHint("Click to edit. Drag to move. Right-click for actions.")
    }

    private var header: some View {
        HStack(spacing: themeManager.spacing(.sm)) {
            Circle()
                .fill(Color(hex: pin.colorHex) ?? themeManager.color(.accentPrimary))
                .frame(width: 8, height: 8)

            if pin.pinType == "rich" {
                Image(systemName: "paperclip")
                    .font(.system(size: 8))
                    .foregroundColor(themeManager.color(.textSecondary))
            }

            if isSelected {
                TextField("Title", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(themeManager.font(.body))
                    .foregroundColor(themeManager.color(.textPrimary))
                    .focused($isTitleFocused)
            } else {
                Text(pin.title.isEmpty ? "Untitled" : pin.title)
                    .font(themeManager.font(.body))
                    .foregroundColor(themeManager.color(.textPrimary))
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Expand pin")
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
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary))
                    .lineLimit(3)
            } else {
                Text("No notes yet")
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.65))
                    .italic()
            }
        }
    }

    private var tagPills: some View {
        HStack(spacing: themeManager.spacing(.xs)) {
            ForEach(tags.prefix(4), id: \.self) { tag in
                Text(tag)
                    .font(themeManager.font(.caption2))
                    .foregroundColor(tagColor(for: tag))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(tagColor(for: tag).opacity(0.2)))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: themeManager.spacing(.xs)) {
            tagPills

            HStack(spacing: themeManager.spacing(.xs)) {
                TextField("Add tag", text: $tagInput)
                    .textFieldStyle(.plain)
                    .font(themeManager.font(.caption))
                    .onSubmit {
                        if !tagInput.isEmpty {
                            var updated = tags
                            let trimmed = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && !updated.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                                updated.append(trimmed)
                                onTagsChange(updated)
                            }
                            tagInput = ""
                        }
                    }

                Button(action: {
                    if !tagInput.isEmpty {
                        var updated = tags
                        let trimmed = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty && !updated.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                            updated.append(trimmed)
                            onTagsChange(updated)
                        }
                        tagInput = ""
                    }
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(themeManager.font(.caption))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var priorityPicker: some View {
        Picker("Priority", selection: priorityBinding) {
            Text("None").tag(0)
            Text("Low").tag(1)
            Text("Medium").tag(2)
            Text("High").tag(3)
            Text("Urgent").tag(4)
        }
        .pickerStyle(.menu)
        .font(themeManager.font(.caption))
    }

    private var priorityColor: Color {
        switch pin.priority {
        case 1: return Color(hex: "#60a5fa") ?? .blue
        case 2: return Color(hex: "#e9c46a") ?? .yellow
        case 3: return Color(hex: "#f4a261") ?? .orange
        case 4: return Color(hex: "#e76f51") ?? .red
        default: return .clear
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: themeManager.radius(.lg))
            .fill(themeManager.color(.bgElevated))
            .overlay(
                RoundedRectangle(cornerRadius: themeManager.radius(.lg))
                    .fill(priorityColor.opacity(tintOpacity))
            )
    }

    private var tintOpacity: Double {
        switch pin.priority {
        case 0: return 0.06
        case 1: return 0.12
        case 2: return 0.15
        case 3: return 0.18
        case 4: return 0.22
        default: return 0.06
        }
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
                dragOffset = value.translation
            }
            .onEnded { value in
                if let start = dragStart {
                    let final = CGPoint(
                        x: start.x + value.translation.width,
                        y: start.y + value.translation.height
                    )
                    onMove(final)
                }
                dragStart = nil
                dragOffset = .zero
            }
    }

    private func tagColor(for tag: String) -> Color {
        let index = abs(tag.hashValue) % max(tagPalette.count, 1)
        return Color(hex: tagPalette[index]) ?? themeManager.color(.accentPrimary)
    }

    private var titleBinding: Binding<String> {
        Binding(get: { pin.title }, set: { pin.title = $0 })
    }

    private var contentBinding: Binding<String> {
        Binding(get: { pin.content ?? "" }, set: { pin.content = $0.isEmpty ? nil : $0 })
    }

    private var priorityBinding: Binding<Int> {
        Binding(get: { pin.priority }, set: { pin.priority = min(max($0, 0), 4) })
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
                positionY: 100,
                priority: 3,
                tags: "[\"sales\",\"ai\"]"
            )
        ),
        isSelected: true,
        isDimmed: false,
        tags: ["sales", "ai"],
        tagPalette: BeeBoardViewModel.groupColorPalette,
        onSelect: {},
        onMove: { _ in },
        onRequestDelete: {},
        onExpand: {},
        onTagsChange: { _ in },
        onUpdatePriority: { _ in }
    )
    .padding()
    .environment(ThemeManager())
}
