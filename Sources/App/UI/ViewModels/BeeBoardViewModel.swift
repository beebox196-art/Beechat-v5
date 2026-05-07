import SwiftUI
import BeeBoard

enum BeeBoardSortOption: String, CaseIterable, Identifiable {
    case priority = "Priority"
    case age = "Age"
    case alphabetical = "A-Z"
    case colour = "Colour"
    case tag = "Tag"

    var id: String { rawValue }
}

struct BeeBoardGroupFrame: Identifiable {
    let id: String
    let group: PinGroup
    let rect: CGRect
    let pinCount: Int
}

@MainActor
@Observable
final class BeeBoardViewModel {
    static let warmAuroraPalette: [String] = [
        "#f5a623", // amber
        "#d4a574", // warm sand
        "#c77d63", // terracotta
        "#e76f51", // coral
        "#f4a261", // apricot
        "#e9c46a", // honey
        "#8fa895", // sage
        "#2a9d8f", // teal
        "#a78bfa", // soft violet
        "#f472b6"  // rose
    ]

    var board: Board?
    var pins: [Pin] = []
    var groups: [PinGroup] = []
    var selectedPinId: String?
    var selectedPinIds: Set<String> = []
    var isSelectionMode = false
    var isCreatingGroup = false
    var pinPendingDelete: Pin?
    var errorMessage: String?
    var isLoading = false
    var searchText = ""
    var detailPinId: String?
    var activeSortOption: BeeBoardSortOption?
    var canUndoSort = false

    var filteredPins: [Pin] {
        guard !searchText.isEmpty else { return pins }
        let query = searchText.lowercased()
        return pins.filter { pin in
            pin.title.lowercased().contains(query) ||
            (pin.content?.lowercased().contains(query) ?? false) ||
            pin.tags.lowercased().contains(query)
        }
    }

    var matchingPinIds: Set<String> {
        guard !searchText.isEmpty else { return Set(pins.map(\.id)) }
        return Set(filteredPins.map(\.id))
    }

    @ObservationIgnored private let boardRepository: BoardRepository
    @ObservationIgnored private let pinRepository: PinRepository
    @ObservationIgnored private let groupRepository: PinGroupRepository
    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var manualLayoutSnapshot: [String: CGPoint]?

    init(
        boardRepository: BoardRepository = BoardRepository(),
        pinRepository: PinRepository = PinRepository(),
        groupRepository: PinGroupRepository = PinGroupRepository()
    ) {
        self.boardRepository = boardRepository
        self.pinRepository = pinRepository
        self.groupRepository = groupRepository
    }

    deinit {
        saveTasks.values.forEach { $0.cancel() }
    }

    // MARK: - Load

    func load() {
        isLoading = true
        errorMessage = nil

        do {
            let board = try boardRepository.fetchOrCreateDefaultBoard()
            self.board = board
            self.pins = try pinRepository.fetchPins(boardId: board.id)
            self.groups = try groupRepository.fetchGroups(boardId: board.id)
        } catch {
            errorMessage = "Failed to load BeeBoard: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Pin CRUD

    func createPinAtCenter() {
        createPin(at: CGPoint(x: 420, y: 260))
    }

    func createPin(at point: CGPoint) {
        guard let board else { return }

        let x = max(120, point.x)
        let y = max(80, point.y)
        let now = Date()
        let pin = Pin(
            boardId: board.id,
            title: "",
            content: nil,
            colorHex: Self.warmAuroraPalette[0],
            positionX: Double(x),
            positionY: Double(y),
            width: 220,
            height: 132,
            groupId: nil,
            priority: 0,
            tags: "[]",
            createdAt: now,
            updatedAt: now
        )

        do {
            try pinRepository.insert(pin)
            pins.append(pin)
            selectedPinId = pin.id
            selectedPinIds = [pin.id]
        } catch {
            errorMessage = "Failed to create pin: \(error.localizedDescription)"
        }
    }

    func binding(for pin: Pin) -> Binding<Pin> {
        Binding(
            get: { [weak self] in
                self?.pins.first { $0.id == pin.id } ?? pin
            },
            set: { [weak self] updatedPin in
                self?.updatePin(updatedPin)
            }
        )
    }

    func binding(for id: String) -> Binding<Pin> {
        Binding(
            get: { [weak self] in
                self?.pins.first { $0.id == id } ?? Pin(boardId: "missing", title: "Missing")
            },
            set: { [weak self] updatedPin in
                self?.updatePin(updatedPin)
            }
        )
    }

    // MARK: - Selection

    func select(pinId: String) {
        if isSelectionMode {
            if selectedPinIds.contains(pinId) {
                selectedPinIds.remove(pinId)
                if selectedPinId == pinId {
                    selectedPinId = selectedPinIds.first
                }
            } else {
                selectedPinIds.insert(pinId)
                selectedPinId = pinId
            }
        } else {
            selectedPinId = pinId
            selectedPinIds = [pinId]
        }
    }

    func clearSelection() {
        selectedPinId = nil
        selectedPinIds.removeAll()
    }

    func toggleSelectionMode() {
        isSelectionMode.toggle()
        if !isSelectionMode, let selectedPinId {
            selectedPinIds = [selectedPinId]
        }
    }

    // MARK: - Pin Updates

    func updatePin(_ pin: Pin) {
        guard let index = pins.firstIndex(where: { $0.id == pin.id }) else { return }
        var updated = pin
        updated.priority = min(max(updated.priority, 0), 4)
        updated.updatedAt = Date()
        pins[index] = updated
        scheduleSave(updated)
    }

    func movePin(id: String, to point: CGPoint) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }

        let oldGroupId = pins[index].groupId
        let oldGroupFrame = oldGroupId.flatMap { groupFrame(for: $0)?.rect }

        pins[index].positionX = Double(max(0, point.x))
        pins[index].positionY = Double(max(0, point.y))
        pins[index].updatedAt = Date()

        applyGroupDropRules(for: id, oldGroupId: oldGroupId, oldGroupFrame: oldGroupFrame)
        schedulePositionSave(pins[index])
    }

    func requestDelete(pinId: String) {
        pinPendingDelete = pins.first { $0.id == pinId }
    }

    func cancelDelete() {
        pinPendingDelete = nil
    }

    func confirmDelete() {
        guard let pin = pinPendingDelete else { return }

        do {
            try pinRepository.delete(id: pin.id)
            pins.removeAll { $0.id == pin.id }
            selectedPinIds.remove(pin.id)
            if selectedPinId == pin.id {
                selectedPinId = nil
            }
            pinPendingDelete = nil
        } catch {
            errorMessage = "Failed to delete pin: \(error.localizedDescription)"
        }
    }

    // MARK: - Tags & Priority

    func updatePriority(pinId: String, priority: Int) {
        guard let index = pins.firstIndex(where: { $0.id == pinId }) else { return }
        pins[index].priority = priority
        pins[index].updatedAt = Date()
        scheduleSave(pins[index])
    }

    func addTag(pinId: String, tag: String) {
        guard let index = pins.firstIndex(where: { $0.id == pinId }) else { return }
        var currentTags = (try? JSONDecoder().decode([String].self, from: Data(pins[index].tags.utf8))) ?? []
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !currentTags.contains(trimmed) else { return }
        currentTags.append(trimmed)
        if let encoded = try? JSONEncoder().encode(currentTags),
           let string = String(data: encoded, encoding: .utf8) {
            pins[index].tags = string
            pins[index].updatedAt = Date()
            scheduleSave(pins[index])
        }
    }

    func removeTag(pinId: String, tag: String) {
        guard let index = pins.firstIndex(where: { $0.id == pinId }) else { return }
        var currentTags = (try? JSONDecoder().decode([String].self, from: Data(pins[index].tags.utf8))) ?? []
        currentTags.removeAll { $0 == tag }
        if let encoded = try? JSONEncoder().encode(currentTags),
           let string = String(data: encoded, encoding: .utf8) {
            pins[index].tags = string
            pins[index].updatedAt = Date()
            scheduleSave(pins[index])
        }
    }

    func tags(for pin: Pin) -> [String] {
        guard let data = pin.tags.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    func setTags(_ tags: [String], for pinId: String) {
        guard let index = pins.firstIndex(where: { $0.id == pinId }),
              let data = try? JSONEncoder().encode(tags),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        pins[index].tags = string
        pins[index].updatedAt = Date()
        scheduleSave(pins[index])
    }

    // MARK: - Search

    func matchesSearch(_ pin: Pin) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        if pin.title.lowercased().contains(query) { return true }
        if (pin.content ?? "").lowercased().contains(query) { return true }
        return tags(for: pin).contains { $0.lowercased().contains(query) }
    }

    func isDimmedBySearch(_ pin: Pin) -> Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !matchesSearch(pin)
    }

    // MARK: - Detail

    func openDetail(pinId: String) {
        detailPinId = pinId
    }

    func closeDetail() {
        detailPinId = nil
    }

    // MARK: - Groups

    func createGroup(name: String, colorHex: String) {
        guard let board else { return }
        let selectedIds = Array(selectedPinIds)
        guard selectedIds.count >= 2 else { return }

        let group = PinGroup(boardId: board.id, name: name, colorHex: colorHex)

        do {
            try groupRepository.insert(group)
            try pinRepository.updateGroupAssignments(pinIds: selectedIds, groupId: group.id)
            groups.append(group)

            for index in pins.indices where selectedIds.contains(pins[index].id) {
                pins[index].groupId = group.id
                pins[index].updatedAt = Date()
            }

            isSelectionMode = false
            selectedPinIds.removeAll()
            selectedPinId = nil
        } catch {
            errorMessage = "Failed to create group: \(error.localizedDescription)"
        }
    }

    func moveGroup(id: String, by translation: CGSize) {
        let memberIndexes = pins.indices.filter { pins[$0].groupId == id }
        guard !memberIndexes.isEmpty else { return }

        var updates: [(id: String, x: Double, y: Double)] = []

        for index in memberIndexes {
            pins[index].positionX = Double(max(0, CGFloat(pins[index].positionX) + translation.width))
            pins[index].positionY = Double(max(0, CGFloat(pins[index].positionY) + translation.height))
            pins[index].updatedAt = Date()
            updates.append((id: pins[index].id, x: pins[index].positionX, y: pins[index].positionY))
        }

        do {
            try pinRepository.updatePositions(updates)
        } catch {
            errorMessage = "Failed to move group: \(error.localizedDescription)"
        }
    }

    func groupFrames() -> [BeeBoardGroupFrame] {
        groups.compactMap { groupFrame(for: $0.id) }
    }

    // MARK: - Sort

    func applySort(_ option: BeeBoardSortOption) {
        if manualLayoutSnapshot == nil {
            manualLayoutSnapshot = Dictionary(
                uniqueKeysWithValues: pins.map { pin in
                    (pin.id, CGPoint(x: pin.positionX, y: pin.positionY))
                }
            )
        }

        activeSortOption = option
        canUndoSort = true

        let sortedPins: [Pin]
        switch option {
        case .priority:
            sortedPins = pins.sorted { lhs, rhs in
                if lhs.priority == rhs.priority { return lhs.createdAt < rhs.createdAt }
                return lhs.priority > rhs.priority
            }
        case .age:
            sortedPins = pins.sorted { $0.createdAt < $1.createdAt }
        case .alphabetical:
            sortedPins = pins.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .colour:
            sortedPins = pins.sorted { $0.colorHex < $1.colorHex }
        case .tag:
            sortedPins = pins.sorted { firstTag($0) < firstTag($1) }
        }

        applyGridLayout(to: sortedPins)
    }

    func undoSort() {
        guard let snapshot = manualLayoutSnapshot else { return }

        var updates: [(id: String, x: Double, y: Double)] = []
        for index in pins.indices {
            guard let point = snapshot[pins[index].id] else { continue }
            pins[index].positionX = Double(point.x)
            pins[index].positionY = Double(point.y)
            pins[index].updatedAt = Date()
            updates.append((id: pins[index].id, x: pins[index].positionX, y: pins[index].positionY))
        }

        persistPositionUpdates(updates, errorPrefix: "Failed to undo sort")
        manualLayoutSnapshot = nil
        activeSortOption = nil
        canUndoSort = false
    }

    // MARK: - Private

    private func applyGridLayout(to sortedPins: [Pin]) {
        let startX: CGFloat = 150
        let startY: CGFloat = 130
        let columnWidth: CGFloat = 260
        let rowHeight: CGFloat = 180
        let columns = 4

        var updates: [(id: String, x: Double, y: Double)] = []

        for (offset, sortedPin) in sortedPins.enumerated() {
            guard let index = pins.firstIndex(where: { $0.id == sortedPin.id }) else { continue }
            let column = offset % columns
            let row = offset / columns
            let x = startX + CGFloat(column) * columnWidth
            let y = startY + CGFloat(row) * rowHeight
            pins[index].positionX = Double(x)
            pins[index].positionY = Double(y)
            pins[index].updatedAt = Date()
            updates.append((id: pins[index].id, x: pins[index].positionX, y: pins[index].positionY))
        }

        persistPositionUpdates(updates, errorPrefix: "Failed to sort pins")
    }

    private func persistPositionUpdates(_ updates: [(id: String, x: Double, y: Double)], errorPrefix: String) {
        do {
            try pinRepository.updatePositions(updates)
        } catch {
            errorMessage = "\(errorPrefix): \(error.localizedDescription)"
        }
    }

    private func firstTag(_ pin: Pin) -> String {
        tags(for: pin).first?.lowercased() ?? "~"
    }

    private func applyGroupDropRules(for pinId: String, oldGroupId: String?, oldGroupFrame: CGRect?) {
        guard let index = pins.firstIndex(where: { $0.id == pinId }) else { return }
        let point = CGPoint(x: pins[index].positionX, y: pins[index].positionY)

        // If pin was in a group and now dragged outside its bounds
        if let oldGroupId {
            if let oldGroupFrame, !oldGroupFrame.insetBy(dx: -24, dy: -24).contains(point) {
                pins[index].groupId = nil
                persistGroupAssignment(pinId: pinId, groupId: nil)
            } else {
                pins[index].groupId = oldGroupId
            }
            return
        }

        // If pin was ungrouped and dragged into a group's bounds
        if let target = groupFrames().last(where: { $0.rect.contains(point) }) {
            pins[index].groupId = target.group.id
            persistGroupAssignment(pinId: pinId, groupId: target.group.id)
        }
    }

    private func persistGroupAssignment(pinId: String, groupId: String?) {
        do {
            try pinRepository.updateGroup(id: pinId, groupId: groupId)
        } catch {
            errorMessage = "Failed to update group: \(error.localizedDescription)"
        }
    }

    private func groupFrame(for groupId: String) -> BeeBoardGroupFrame? {
        guard let group = groups.first(where: { $0.id == groupId }) else { return nil }
        let members = pins.filter { $0.groupId == groupId }
        guard !members.isEmpty else { return nil }

        let minX = members.map { $0.positionX - ($0.width / 2) }.min() ?? 0
        let maxX = members.map { $0.positionX + ($0.width / 2) }.max() ?? 0
        let minY = members.map { $0.positionY - ($0.height / 2) }.min() ?? 0
        let maxY = members.map { $0.positionY + ($0.height / 2) }.max() ?? 0

        let paddingX: Double = 28
        let paddingTop: Double = 54
        let paddingBottom: Double = 28

        let rect = CGRect(
            x: minX - paddingX,
            y: minY - paddingTop,
            width: (maxX - minX) + (paddingX * 2),
            height: (maxY - minY) + paddingTop + paddingBottom
        )

        return BeeBoardGroupFrame(id: group.id, group: group, rect: rect, pinCount: members.count)
    }

    private func scheduleSave(_ pin: Pin) {
        saveTasks[pin.id]?.cancel()
        saveTasks[pin.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.save(pin)
            }
        }
    }

    private func schedulePositionSave(_ pin: Pin) {
        saveTasks[pin.id]?.cancel()
        saveTasks[pin.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.savePosition(pin)
            }
        }
    }

    private func save(_ pin: Pin) {
        do {
            try pinRepository.update(pin)
        } catch {
            errorMessage = "Failed to save pin: \(error.localizedDescription)"
        }
    }

    private func savePosition(_ pin: Pin) {
        do {
            try pinRepository.updatePosition(
                id: pin.id,
                x: pin.positionX,
                y: pin.positionY
            )
        } catch {
            errorMessage = "Failed to save pin position: \(error.localizedDescription)"
        }
    }
}
