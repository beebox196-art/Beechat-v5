import SwiftUI
import BeeChatSyncBridge
import BeeChatPersistence

/// Main chat window — the single-canvas layout container.
/// TopBar + MessageCanvas + Composer.
struct MainWindow: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(AppState.self) var appState
    @State private var messageViewModel = MessageViewModel()
    @State private var composerViewModel = ComposerViewModel()
    @State private var syncBridgeObserver = SyncBridgeObserver()
    @State private var isObserving = false
    @State private var showNewTopicDialog = false
    @State private var newTopicTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            // Top Bar — topic navigation
            TopicBar(
                topics: messageViewModel.topics,
                selectedTopicId: Binding(
                    get: { messageViewModel.selectedTopicId },
                    set: { id in if let id { messageViewModel.selectTopic(id: id) } }
                ),
                onCreateTopic: { showNewTopicDialog = true },
                onDeleteTopic: { id in deleteTopic(id) }
            )

            Divider()

            // Message Canvas — scrollable message list
            if messageViewModel.selectedTopic != nil || messageViewModel.topics.isEmpty == false {
                MessageCanvas(
                    messages: messageViewModel.messages,
                    isStreaming: syncBridgeObserver.isStreaming
                )
            } else {
                // Empty state — no topic selected
                VStack {
                    Spacer()
                    Text("Select a topic to start chatting")
                        .font(themeManager.font(.subheading))
                        .foregroundColor(themeManager.color(.textSecondary))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(themeManager.color(.bgSurface))
            }

            Divider()

            // Composer — text input
            Composer(viewModel: composerViewModel, onSend: sendMessage)
        }
        .background(themeManager.color(.bgSurface))
        .onAppear {
            wireUpObservers()
        }
        .onChange(of: appState.isReady) { _, ready in
            if ready {
                wireUpObservers()
            }
        }
        .onChange(of: appState.connectionState) { _, state in
            syncBridgeObserver.connectionState = state
        }
        .alert("New Topic", isPresented: $showNewTopicDialog) {
            TextField("Topic name", text: $newTopicTitle)
            Button("Cancel", role: .cancel) { newTopicTitle = "" }
            Button("Create") { createNewTopic() }
        }
    }

    // MARK: - Wiring

    private func wireUpObservers() {
        guard !isObserving, let bridge = appState.syncBridge else { return }
        isObserving = true

        // Attach SyncBridgeObserver as delegate
        syncBridgeObserver.attach(bridge)

        // Start messageViewModel observing
        messageViewModel.start(syncBridge: bridge)

        // Configure composer
        composerViewModel.configure(syncBridge: bridge, messageViewModel: messageViewModel)

        // Start observing session list changes
        // This will drive topic updates
        Task {
            let stream = await bridge.sessionListStream()
            for await sessions in stream {
                await MainActor.run {
                    messageViewModel.updateTopics(from: sessions)
                }
            }
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        Task {
            do {
                try await messageViewModel.sendMessage(
                    text: composerViewModel.inputText
                )
                composerViewModel.inputText = ""
            } catch {
                print("[MainWindow] Send failed: \(error)")
            }
        }
    }

    private func createNewTopic() {
        guard !newTopicTitle.isEmpty else { return }
        Task {
            do {
                // Create a new session via SyncBridge, which will appear in the session list stream
                guard let bridge = appState.syncBridge else { return }
                _ = try await bridge.fetchSessions()
                // Sessions are created via gateway — for now, create a local placeholder
                // The gateway will create the session and it'll stream back via sessionListStream
                // For manual topic creation, we add a local session with the user's title
                let newSession = Session(
                    id: "local-\(UUID().uuidString)",
                    agentId: "bee",
                    channel: "beechat",
                    title: newTopicTitle,
                    lastMessageAt: nil,
                    unreadCount: 0,
                    isPinned: false
                )
                // Persist locally
                let repo = SessionRepository()
                try repo.save(newSession)
                // Update UI
                messageViewModel.addLocalTopic(newSession)
                newTopicTitle = ""
            } catch {
                print("[MainWindow] Create topic failed: \(error)")
            }
        }
    }

    private func deleteTopic(_ id: String) {
        Task {
            do {
                // Delete session and its messages (cascading)
                let repo = SessionRepository()
                try repo.deleteCascading(id)
                // Update UI
                messageViewModel.removeTopic(id: id)
            } catch {
                print("[MainWindow] Delete topic failed: \(error)")
            }
        }
    }
}