import SwiftUI
import BeeBoard

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
    var selectedPinId: String?
    var pinPendingDelete: Pin?
    var errorMessage: String?
    var isLoading = false
    var searchText = ""
    var detailPinId: String?

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
    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]

    init(
        boardRepository: BoardRepository = BoardRepository(),
        pinRepository: PinRepository = PinRepository()
    ) {
        self.boardRepository = boardRepository
        self.pinRepository = pinRepository
    }

    deinit {
        saveTasks.values.forEach { $0.cancel() }
    }

    func load() {
        isLoading = true
        errorMessage = nil

        do {
            let board = try boardRepository.fetchOrCreateDefaultBoard()
            self.board = board
            self.pins = try pinRepository.fetchPins(boardId: board.id)
        } catch {
            errorMessage = "Failed to load BeeBoard: \(error.localizedDescription)"
        }

        isLoading = false
    }

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

    func select(pinId: String) {
        selectedPinId = pinId
    }

    func updatePin(_ pin: Pin) {
        guard let index = pins.firstIndex(where: { $0.id == pin.id }) else { return }
        var updated = pin
        updated.updatedAt = Date()
        pins[index] = updated
        scheduleSave(updated)
    }

    func movePin(id: String, to point: CGPoint) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[index].positionX = Double(max(0, point.x))
        pins[index].positionY = Double(max(0, point.y))
        pins[index].updatedAt = Date()
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
            if selectedPinId == pin.id {
                selectedPinId = nil
            }
            pinPendingDelete = nil
        } catch {
            errorMessage = "Failed to delete pin: \(error.localizedDescription)"
        }
    }

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

    func openDetail(pinId: String) {
        detailPinId = pinId
    }

    func closeDetail() {
        detailPinId = nil
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
