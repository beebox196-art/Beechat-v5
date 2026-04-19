import SwiftUI
import BeeChatSyncBridge
import BeeChatPersistence
import GRDB

/// Main chat window — NavigationSplitView layout with sidebar + detail.
struct MainWindow: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(AppState.self) var appState
    @State private var messageViewModel = MessageViewModel()
    @State private var composerViewModel = ComposerViewModel()
    @State private var syncBridgeObserver = SyncBridgeObserver()
    @State private var isObserving = false
    @State private var isGatewayWired = false
    @State private var localSessionCancellable: DatabaseCancellable?
    @State private var showNewTopicDialog = false
    @State private var newTopicTitle = ""

    var body: some View {
        NavigationSplitView {
            // SIDEBAR — topic list
            List(selection: $messageViewModel.selectedTopicId) {
                ForEach(messageViewModel.topics) { topic in
                    NavigationLink(value: topic.id) {
                        SessionRow(topic: topic)
                    }
                    .contextMenu {
                        Button("Delete Topic", role: .destructive) {
                            deleteTopic(topic.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                if let id = messageViewModel.selectedTopicId {
                    deleteTopic(id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showNewTopicDialog = true }) {
                        Label("New Topic", systemImage: "plus.circle")
                    }
                }
            }
        } detail: {
            // DETAIL — chat view
            VStack(spacing: 0) {
                if messageViewModel.selectedTopic != nil {
                    MessageCanvas(
                        messages: messageViewModel.messages,
                        isStreaming: syncBridgeObserver.isStreaming
                    )
                    Divider()
                    Composer(viewModel: composerViewModel, onSend: sendMessage)
                } else {
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
            }
        }
        .onAppear {
            wireUpObservers()
        }
        .onDisappear {
            localSessionCancellable?.cancel()
            localSessionCancellable = nil
        }
        .onChange(of: appState.isReady) { _, ready in
            if ready {
                wireUpObservers()
            }
        }
        .onChange(of: appState.connectionState) { _, newState in
            syncBridgeObserver.connectionState = newState
            if newState == .connected, let bridge = appState.syncBridge {
                rewireForGateway(bridge)
            }
            if newState == .disconnected || newState == .error {
                isGatewayWired = false
            }
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

        // Unified read path: start local GRDB ValueObservation for sessions.
        // This feeds into the same updateTopics() path regardless of gateway state.
        startLocalSessionObservation()

        if let bridge = appState.syncBridge {
            rewireForGateway(bridge)
        } else {
            // No gateway — configure composer for local-only mode
            composerViewModel.configure(syncBridge: nil, messageViewModel: messageViewModel)
        }
    }

    /// Re-wire gateway-dependent observers when gateway connects.
    /// Called from onChange(of: connectionState) when state becomes .connected.
    private func rewireForGateway(_ bridge: SyncBridge) {
        guard !isGatewayWired else { return }
        isGatewayWired = true

        // Attach SyncBridgeObserver as delegate
        syncBridgeObserver.attach(bridge)

        // Start messageViewModel observing
        messageViewModel.start(syncBridge: bridge)

        // Configure composer
        composerViewModel.configure(syncBridge: bridge, messageViewModel: messageViewModel)


    }

    /// Start a standalone GRDB ValueObservation on the sessions table.
    /// This provides a unified read path (observer → updateTopics) whether or not
    /// the gateway is connected. Replaces the old loadLocalSessions() direct fetch.
    private func startLocalSessionObservation() {
        let observation = ValueObservation.tracking { db in
            try Session
                .order(Column("lastMessageAt").desc)
                .limit(100)
                .fetchAll(db)
        }

        do {
            let writer = try DatabaseManager.shared.writer
            localSessionCancellable = observation.start(
                in: writer,
                scheduling: .mainActor,
                onError: { error in
                    print("[MainWindow] Local session observation error: \(error)")
                },
                onChange: { [weak messageViewModel] sessions in
                    messageViewModel?.updateTopics(from: sessions)
                }
            )
        } catch {
            print("[MainWindow] Failed to start local session observation: \(error)")
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

                // Persist to database — the ValueObservation will pick it up
                let repo = SessionRepository()
                try repo.save(newSession)
                print("[MainWindow] Created topic: \(title) (\(newSession.id))")

                // Select the new topic (ValueObservation handles the list update)
                await MainActor.run {
                    messageViewModel.addLocalTopic(newSession)
                }
            } catch {
                print("[MainWindow] Create topic failed: \(error)")
                await MainActor.run {
                    // Restore text for retry
                    self.newTopicTitle = title
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
                // ValueObservation will handle the list update
                messageViewModel.removeTopic(id: id)
            } catch {
                print("[MainWindow] Delete topic failed: \(error)")
            }
        }
    }
}