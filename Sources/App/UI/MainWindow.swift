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
    @State private var localTopicCancellable: DatabaseCancellable?
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
                GatewayStatusBar(connectionState: appState.connectionState, detailText: appState.offlineStatus ?? appState.errorMessage)
                Divider()

                if messageViewModel.selectedTopic != nil {
                    // Filter streaming content to only show for the currently active topic
                    let isActiveTopicStreaming = syncBridgeObserver.isStreaming
                        && syncBridgeObserver.streamingSessionKey == messageViewModel.selectedTopicId
                    let activeTopicStreamingContent = isActiveTopicStreaming
                        ? syncBridgeObserver.streamingContent : ""

                    MessageCanvas(
                        messages: messageViewModel.messages,
                        isStreaming: isActiveTopicStreaming,
                        streamingContent: activeTopicStreamingContent
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
            if appState.isReady {
                wireUpObservers()
            }
        }
        .onDisappear {
            localTopicCancellable?.cancel()
            localTopicCancellable = nil
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
        guard appState.isReady else { return }
        guard !isObserving else { return }
        isObserving = true

        // Start local GRDB ValueObservation for TOPICS (not sessions).
        // This feeds into updateTopics() — sidebar shows topics only.
        startLocalTopicObservation()

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
        if let topicId = messageViewModel.selectedTopicId {
            let topicRepo = TopicRepository()
            if let sessionKey = try? topicRepo.resolveSessionKey(topicId: topicId) {
                messageViewModel.startGatewayMessageObservation(sessionKey: sessionKey)
            }
        }
    }

    /// Start a standalone GRDB ValueObservation on the TOPICS table.
    /// This is the sidebar data source — topics only, zero sessions.
    private func startLocalTopicObservation() {
        let observation = ValueObservation.tracking { db in
            try Topic
                .filter(Column("isArchived") == false)
                .order(Column("lastActivityAt").desc)
                .limit(100)
                .fetchAll(db)
        }

        do {
            let writer = try DatabaseManager.shared.writer
            localTopicCancellable = observation.start(
                in: writer,
                scheduling: .mainActor,
                onError: { error in
                    print("[MainWindow] Local topic observation error: \(error)")
                },
                onChange: { [weak messageViewModel] topics in
                    messageViewModel?.updateTopics(from: topics)
                }
            )
        } catch {
            print("[MainWindow] Failed to start local topic observation: \(error)")
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

    /// Create a new topic — persists to the topics table.
    /// If the gateway is connected, sends an initial message to create a session.
    private func createNewTopic() {
        guard !newTopicTitle.isEmpty else { return }
        let title = newTopicTitle
        newTopicTitle = "" // Clear before async work

        Task {
            do {
                // Create a Topic and persist it
                let newTopic = Topic(
                    id: UUID().uuidString,
                    name: title,
                    lastActivityAt: Date()
                )

                let topicRepo = TopicRepository()
                try topicRepo.save(newTopic)
                print("[MainWindow] Created topic: \(title) (\(newTopic.id))")

                // Select the new topic (ValueObservation handles the list update)
                await MainActor.run {
                    messageViewModel.addLocalTopic(newTopic)
                }

                // If gateway is connected, send an initial message to create a gateway session
                if let bridge = appState.syncBridge {
                    do {
                        let runId = try await bridge.sendMessage(
                            sessionKey: newTopic.id,
                            text: "Start",
                            thinking: nil
                        )
                        // Update the topic with the session key (which is the topic id for now)
                        try topicRepo.updateSessionKey(topicId: newTopic.id, sessionKey: newTopic.id)
                        try topicRepo.saveBridge(topicId: newTopic.id, sessionKey: newTopic.id)
                        print("[MainWindow] Gateway session created for topic \(newTopic.id), runId: \(runId)")
                    } catch {
                        // Session creation failed — topic still exists locally
                        print("[MainWindow] Gateway session creation failed (topic still local): \(error)")
                    }
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
                let topicRepo = TopicRepository()
                try topicRepo.deleteCascading(id)
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