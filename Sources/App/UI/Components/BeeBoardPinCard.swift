import SwiftUI
import BeeBoard

struct BeeBoardPinCard: View {
    @Environment(ThemeManager.self) var themeManager
    @Binding var pin: Pin

    let isSelected: Bool
    let isMultiSelected: Bool
    let isSearchMatch: Bool
    let isDimmed: Bool
    let tags: [String]
    let palette: [String]
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
            // Priority stripe
            if pin.priority > 0 {
                RoundedRectangle(cornerRadius: 2)
                    .fill(priorityColor)
                    .frame(width: 4)
            }

            VStack(alignment: .leading, spacing: themeManager.spacing(.sm)) {
                header

                if isSelected {
                    editFields
                    priorityPicker
                    tagEditor
                    colourPicker
                } else {
                    readOnlyBody
                    tagPills
                }

                Spacer(minLength: themeManager.spacing(.xs))

                Text(pin.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.75))
            }
            .padding(themeManager.spacing(.md))
        }
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
                .frame(width: 10, height: 10)

            if isSelected {
                TextField("Title", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(themeManager.font(.subheading))
                    .foregroundColor(themeManager.color(.textPrimary))
                    .focused($isTitleFocused)
            } else {
                Text(pin.title.isEmpty ? "Untitled" : pin.title)
                    .font(themeManager.font(.subheading))
                    .foregroundColor(themeManager.color(.textPrimary))
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10))
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
                    .font(themeManager.font(.body))
                    .foregroundColor(themeManager.color(.textSecondary))
                    .lineLimit(2)
            } else {
                Text("No notes yet")
                    .font(themeManager.font(.body))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.65))
                    .italic()
            }
        }
    }

    private var tagPills: some View {
        HStack(spacing: themeManager.spacing(.xs)) {
            ForEach(tags.prefix(3), id: \.self) { tag in
                Text(tag)
                    .font(themeManager.font(.caption2))
                    .foregroundColor(tagColor(for: tag))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tagColor(for: tag).opacity(0.2)))
            }
        }
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
            }
        }
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
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: themeManager.radius(.lg))
            .stroke(
                borderColor,
                lineWidth: isSelected || isMultiSelected ? 2 : 1
            )
    }

    private var borderColor: Color {
        if isSelected { return themeManager.color(.accentPrimary) }
        if isMultiSelected { return themeManager.color(.accentSecondary) }
        return themeManager.color(.borderSubtle)
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
        let index = abs(tag.hashValue) % max(palette.count, 1)
        return Color(hex: palette[index]) ?? themeManager.color(.accentPrimary)
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
        isMultiSelected: false,
        isSearchMatch: true,
        isDimmed: false,
        tags: ["sales", "ai"],
        palette: BeeBoardViewModel.warmAuroraPalette,
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
