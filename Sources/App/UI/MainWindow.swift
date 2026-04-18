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
        guard !isObserving else { return }
        isObserving = true

        // Always load sessions from local DB first (works offline)
        loadLocalSessions()

        if let bridge = appState.syncBridge {
            // Attach SyncBridgeObserver as delegate
            syncBridgeObserver.attach(bridge)

            // Start messageViewModel observing
            messageViewModel.start(syncBridge: bridge)

            // Configure composer
            composerViewModel.configure(syncBridge: bridge, messageViewModel: messageViewModel)

            // Start observing session list changes from gateway
            Task {
                let stream = await bridge.sessionListStream()
                for await sessions in stream {
                    await MainActor.run {
                        messageViewModel.updateTopics(from: sessions)
                    }
                }
            }
        } else {
            // No gateway — configure composer for local-only mode
            composerViewModel.configure(syncBridge: nil, messageViewModel: messageViewModel)
        }
    }

    /// Load sessions from local database (works without gateway).
    private func loadLocalSessions() {
        do {
            let repo = SessionRepository()
            let sessions = try repo.fetchAll(limit: 100, offset: 0)
            if !sessions.isEmpty {
                messageViewModel.updateTopics(from: sessions)
                print("[MainWindow] Loaded \(sessions.count) sessions from local DB")
            }
        } catch {
            print("[MainWindow] Failed to load local sessions: \(error)")
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
        let title = newTopicTitle
        newTopicTitle = "" // Clear before async work
        
        Task {
            do {
                // Create a local session and persist it
                let newSession = Session(
                    id: "local-\(UUID().uuidString)",
                    agentId: "bee",
                    channel: "beechat",
                    title: title,
                    lastMessageAt: Date(),
                    unreadCount: 0,
                    isPinned: false
                )
                
                // Persist to database
                let repo = SessionRepository()
                try repo.save(newSession)
                print("[MainWindow] Created topic: \(title) (\(newSession.id))")
                
                // Update UI directly
                await MainActor.run {
                    messageViewModel.addLocalTopic(newSession)
                    print("[MainWindow] Topic added to UI")
                }
            } catch {
                print("[MainWindow] Create topic failed: \(error)")
                await MainActor.run {
                    // Show error to user
                    self.newTopicTitle = title // Restore text for retry
                }
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