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

    @State private var showDeleteAlert = false
    @State private var deleteErrorMsg: String?
    @FocusState private var isNewTopicFieldFocused: Bool

    /// Sidebar selection binding — two-way: reads from and writes to messageViewModel.selectedTopicId.
    /// When the user clicks a topic, this sets the selectedTopicId which triggers
    /// onChange → selectTopic() → message observation starts.
    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { messageViewModel.selectedTopicId },
            set: { newId in
                if let id = newId, id != messageViewModel.selectedTopicId {
                    messageViewModel.selectTopic(id: id)
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            // SIDEBAR — topic list + bottom action bar
            VStack(spacing: 0) {
                List(selection: sidebarSelection) {
                    ForEach(messageViewModel.topics) { topic in
                        SessionRow(topic: topic)
                            .tag(topic.id as String?)
                            .contextMenu {
                                Button("Delete Topic", role: .destructive) {
                                    deleteTopic(topic.id)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(themeManager.color(.bgSurface))
                .frame(maxHeight: .infinity)

                Divider()

                HStack(spacing: 12) {
                    Button(action: { showNewTopicDialog = true }) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .help("New Topic")

                    Spacer()

                    if messageViewModel.selectedTopicId != nil {
                        Button(action: {
                            if let id = messageViewModel.selectedTopicId {
                                deleteTopic(id)
                            }
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 14))
                                .foregroundColor(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .help("Delete Selected Topic")
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .animation(.easeInOut(duration: 0.2), value: messageViewModel.selectedTopicId)
            }
            .navigationSplitViewColumnWidth(220)
            .background(themeManager.color(.bgSurface))
            .onKeyPress(.delete) {
                if let id = messageViewModel.selectedTopicId {
                    deleteTopic(id)
                    return .handled
                }
                return .ignored
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedTopic)) { _ in
                if let id = messageViewModel.selectedTopicId {
                    deleteTopic(id)
                }
            }
        } detail: {
            // DETAIL — chat view
            VStack(spacing: 0) {
                // Thin status bar at top of detail pane
                GatewayStatusBar(connectionState: appState.connectionState)
                Divider()

                if messageViewModel.selectedTopic != nil {
                    MessageCanvas(
                        messages: messageViewModel.messages,
                        isStreaming: syncBridgeObserver.isStreaming
                    )
                } else {
                    Color.clear.frame(maxHeight: .infinity)
                }
                Divider()
                Composer(viewModel: composerViewModel, onSend: composerSend)
            }
            .background(themeManager.color(.bgSurface))
        }
        .navigationSplitViewStyle(.automatic)
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
        .sheet(isPresented: $showNewTopicDialog) {
            VStack(spacing: 16) {
                Text("New Topic")
                    .font(.headline)
                TextField("Topic name", text: $newTopicTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .focused($isNewTopicFieldFocused)
                HStack(spacing: 12) {
                    Button("Cancel") {
                        newTopicTitle = ""
                        showNewTopicDialog = false
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Create") {
                        createNewTopic()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newTopicTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
            .onAppear {
                isNewTopicFieldFocused = true
            }
        }
        .alert("Delete Error", isPresented: $showDeleteAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(deleteErrorMsg ?? "Unknown error")
        }

    }

    // MARK: - Wiring

    private func wireUpObservers() {
        guard !isObserving else { return }
        isObserving = true

        // Unified read path: start local GRDB ValueObservation for sessions.
        // This feeds into the same updateTopics() path regardless of gateway state.
        startLocalSessionObservation()

        // Start local GRDB observation for messages (gateway-independent).
        messageViewModel.startLocalMessageObservation()

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

        // Start messageViewModel gateway-dependent observation
        messageViewModel.start(syncBridge: bridge)

        // Configure composer
        composerViewModel.configure(syncBridge: bridge, messageViewModel: messageViewModel)

        // Re-observe messages for current topic via gateway stream
        if let key = messageViewModel.selectedTopicId {
            messageViewModel.startGatewayMessageObservation(sessionKey: key)
        }
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

    /// Composer send — delegates to ComposerViewModel.send() which handles
    /// text clearing and error recovery internally.
    private func composerSend() {
        Task {
            await composerViewModel.send()
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
        Task { @MainActor in
            do {
                let repo = SessionRepository()
                try repo.deleteCascading(id)
                messageViewModel.removeTopic(id: id)
            } catch {
                print("🔴 Delete topic failed: \(error)")
                deleteErrorMsg = error.localizedDescription
                showDeleteAlert = true
            }
        }
    }
}

extension Notification.Name {
    static let deleteSelectedTopic = Notification.Name("deleteSelectedTopic")
}