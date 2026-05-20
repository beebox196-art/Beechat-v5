import SwiftUI
import BeeChatSyncBridge
import BeeChatPersistence
import GRDB

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
    @State private var showResetAlert = false
    @State private var resetTargetSessionKey: String? = nil
    @State private var showResetErrorAlert = false
    @State private var resetErrorMsg: String?
    @State private var showThemePicker = false
    @State private var showFolderPicker = false
    @State private var showAgentActivity = false
    @State private var showBeeBoard = false
    @FocusState private var isNewTopicFieldFocused: Bool

    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { messageViewModel.selectedTopicId },
            set: { newId in
                if let id = newId, id != messageViewModel.selectedTopicId {
                    messageViewModel.selectTopic(id: id)
                    let newSessionKey = messageViewModel.selectedTopic?.sessionKey
                    // Update observer's knowledge of which session is selected
                    syncBridgeObserver.currentSelectedSessionKey = newSessionKey
                    // Clear unread for the newly selected topic
                    syncBridgeObserver.clearUnread(for: newSessionKey)
                    // If this topic is already streaming in the background, catch up the UI
                    if let key = newSessionKey, syncBridgeObserver.isStreamingSession(key) {
                        syncBridgeObserver.catchUpStreaming(for: key)
                    }
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarList

                Divider()

                HStack(spacing: 12) {
                    Button(action: { showNewTopicDialog = true }) {
                        Image(systemName: "plus.circle")
                            .font(themeManager.font(.subheading))
                    }
                    .buttonStyle(.plain)
                    .help("New Topic")
                    .accessibilityLabel("New Topic")
                    .accessibilityHint("Create a new conversation topic")

                    Button(action: { showFolderPicker = true }) {
                        Image(systemName: "folder.badge.plus")
                            .font(themeManager.font(.subheading))
                            .foregroundColor(themeManager.color(.textSecondary))
                    }
                    .buttonStyle(.plain)
                    .help("Folders")
                    .accessibilityLabel("Folders")
                    .accessibilityHint("Open favourite folders")

                    Button(action: { showAgentActivity = true }) {
                        Image(systemName: "person.3")
                            .font(themeManager.font(.body))
                            .foregroundColor(
                                syncBridgeObserver.agentActivityTracker.hasWorkingAgents
                                    ? themeManager.color(.accentPrimary)
                                    : themeManager.color(.textSecondary)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Team Activity")
                    .accessibilityLabel("Team Activity")
                    .accessibilityHint("Show which agents are currently working")
                    .animation(themeManager.animation(.micro), value: syncBridgeObserver.agentActivityTracker.hasWorkingAgents)

                    Button(action: { showBeeBoard = true }) {
                        Image(systemName: "pin.square")
                            .font(themeManager.font(.body))
                            .foregroundColor(themeManager.color(.textSecondary))
                    }
                    .buttonStyle(.plain)
                    .help("BeeBoard")
                    .accessibilityLabel("BeeBoard")
                    .accessibilityHint("Open the idea board")

                    Button(action: { showThemePicker = true }) {
                        Image(systemName: "paintpalette")
                            .font(themeManager.font(.body))
                            .foregroundColor(themeManager.color(.textSecondary))
                    }
                    .buttonStyle(.plain)
                    .help("Change Theme")
                    .accessibilityLabel("Appearance")
                    .accessibilityHint("Change app theme")

                    if messageViewModel.selectedTopicId != nil {
                        Button(action: {
                            if let id = messageViewModel.selectedTopicId {
                                deleteTopic(id)
                            }
                        }) {
                            Image(systemName: "trash")
                                .font(themeManager.font(.body))
                                .foregroundColor(themeManager.color(.error).opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .help("Delete Selected Topic")
                        .accessibilityLabel("Delete Topic")
                        .accessibilityHint("Remove selected topic")
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, themeManager.spacing(.lg))
                .padding(.vertical, themeManager.spacing(.sm))
                .animation(themeManager.animation(.micro), value: messageViewModel.selectedTopicId)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 320)
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
            .onReceive(NotificationCenter.default.publisher(for: .newTopic)) { _ in
                showNewTopicDialog = true
            }
        } detail: {
            VStack(spacing: 0) {
                GatewayStatusBar(connectionState: appState.connectionState, detailText: appState.offlineStatus ?? appState.errorMessage)
                Divider()

                if messageViewModel.selectedTopic != nil {
                    let isActiveTopicStreaming = syncBridgeObserver.isStreaming
                        && syncBridgeObserver.streamingSessionKey == messageViewModel.selectedTopic?.sessionKey
                    let activeTopicStreamingContent = isActiveTopicStreaming
                        ? syncBridgeObserver.streamingContent : ""

                    ZStack(alignment: .top) {
                        MessageCanvas(
                            messages: messageViewModel.messages,
                            isStreaming: isActiveTopicStreaming,
                            streamingContent: activeTopicStreamingContent,
                            thinkingState: syncBridgeObserver.thinkingState,
                            canLoadEarlier: messageViewModel.canLoadEarlier,
                            topicId: messageViewModel.selectedTopicId,
                            onLoadEarlier: { messageViewModel.loadEarlierMessages() }
                        )
                        .safeAreaInset(edge: .bottom) {
                            VStack(spacing: 0) {
                                Divider()
                                Composer(viewModel: composerViewModel, onSend: composerSend)
                            }
                            .background(themeManager.color(.bgSurface))
                        }
                        resetIndicator
                            .padding(.top, 4)
                    }
                } else {
                    Color.clear.frame(maxHeight: .infinity)
                }
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
        .onChange(of: messageViewModel.selectedTopicId) { _, _ in
            // Clear stale pending reset context when switching topics
            if let bridge = appState.syncBridge {
                Task {
                    await bridge.clearPendingResetContext(except: messageViewModel.selectedTopic?.sessionKey)
                }
            }
        }
        .onChange(of: appState.connectionState) { _, newState in
            BeeChatLogger.log("[ThinkingBee] connectionState changed to \(newState)")
            syncBridgeObserver.connectionState = newState
            if newState == .connected, let bridge = appState.syncBridge {
                rewireForGateway(bridge)
            }
            if newState == .disconnected || newState == .error {
                BeeChatLogger.log("[ThinkingBee] connection lost — resetting isGatewayWired")
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
        .alert("Reset Failed", isPresented: $showResetErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(resetErrorMsg ?? "Could not reset session. Please check your connection.")
        }
        .resetSessionAlert(isPresented: $showResetAlert, resetError: $resetErrorMsg, showError: $showResetErrorAlert, sessionKey: resetTargetSessionKey, bridge: appState.syncBridge)
        .sheet(isPresented: $showThemePicker) {
            ThemePicker()
                .environment(themeManager)
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker()
                .environment(themeManager)
        }
        .sheet(isPresented: $showAgentActivity) {
            AgentActivityPanel(tracker: syncBridgeObserver.agentActivityTracker)
                .environment(themeManager)
        }
        .sheet(isPresented: $showBeeBoard) {
            BeeBoardSheet()
                .environment(themeManager)
        }

    }


    private func wireUpObservers() {
        guard appState.isReady else { return }
        guard !isObserving else { return }
        isObserving = true

        startLocalTopicObservation()

        messageViewModel.startLocalMessageObservation()

        if let bridge = appState.syncBridge {
            rewireForGateway(bridge)
        } else {
            composerViewModel.configure(syncBridge: nil, messageViewModel: messageViewModel)
        }
    }

    private func rewireForGateway(_ bridge: SyncBridge) {
        BeeChatLogger.log("[ThinkingBee] rewireForGateway called — isGatewayWired=\(isGatewayWired)")
        guard !isGatewayWired else { return }
        isGatewayWired = true

        syncBridgeObserver.attach(bridge)

        messageViewModel.start(syncBridge: bridge)

        // One-time fix: migrate pre-existing topics with bare UUID sessionKeys to gateway keys
        Task {
            do {
                let topicRepo = TopicRepository()
                let topics = try topicRepo.fetchAllActive()
                for topic in topics {
                    guard let rawKey = topic.sessionKey, !rawKey.contains(":") else { continue }
                    let gatewayKey = "agent:main:" + rawKey.lowercased()
                    try topicRepo.updateSessionKey(topicId: topic.id, sessionKey: gatewayKey)
                    try topicRepo.saveBridge(topicId: topic.id, sessionKey: gatewayKey)
                    print("[MainWindow] Migrated topic \(topic.id) sessionKey: \(rawKey) → \(gatewayKey)")
                }
            } catch {
                print("[MainWindow] SessionKey migration error: \(error)")
            }
        }

        composerViewModel.configure(syncBridge: bridge, messageViewModel: messageViewModel)
        composerViewModel.onMessageSent = { [weak syncBridgeObserver] in
            // Always transition to .thinking on send, even if currently .streaming.
            // If streaming is genuinely active, didStartStreaming will override back to .streaming.
            // If streaming is stuck (didStopStreaming never fired), this unblocks the indicator.
            let currentState = syncBridgeObserver?.thinkingState ?? .idle
            BeeChatLogger.log("[ThinkingBee] onMessageSent fired — current state: \(currentState)")
            syncBridgeObserver?.thinkingState = .thinking
            BeeChatLogger.log("[ThinkingBee] Transition: \(currentState) → .thinking")
            // Start thinking timeout — if didStartStreaming never fires within 30s,
            // the bee auto-resets to idle instead of spinning forever
            syncBridgeObserver?.startThinkingTimeout()
        }

        if let topicId = messageViewModel.selectedTopicId {
            let topicRepo = TopicRepository()
            do {
                if let sessionKey = try topicRepo.resolveSessionKey(topicId: topicId) {
                    messageViewModel.startGatewayMessageObservation(sessionKey: sessionKey)
                    messageViewModel.startUsagePolling(for: sessionKey)
                }
            } catch {
                print("[MainWindow] Failed to resolve session key for gateway observation: \(error)")
            }
        }
    }

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
                let topicId = UUID().uuidString
                // Phase 4: gateway keys are native. Generate a gateway-format key upfront.
                let gatewayKey = "agent:main:\(topicId.lowercased())"

                let newTopic = Topic(
                    id: topicId,
                    name: title,
                    lastActivityAt: Date(),
                    sessionKey: gatewayKey
                )

                messageViewModel.selectedTopicId = newTopic.id

                let topicRepo = TopicRepository()
                try topicRepo.save(newTopic)
                try topicRepo.saveBridge(topicId: topicId, sessionKey: gatewayKey)
                print("[MainWindow] Created topic: \(title) (id=\(topicId), gatewayKey=\(gatewayKey))")

                if let bridge = appState.syncBridge {
                    let newTopicForContext = Topic(id: topicId, name: title, sessionKey: gatewayKey)
                    do {
                        let runId = try await bridge.sendMessage(
                            sessionKey: gatewayKey,
                            text: "Start",
                            thinking: nil,
                            topic: newTopicForContext
                        )
                        print("[MainWindow] Gateway session created for topic \(topicId), runId: \(runId)")
                    } catch {
                        print("[MainWindow] Gateway session creation failed (topic still local): \(error)")
                    }
                }
            } catch {
                print("[MainWindow] Create topic failed: \(error)")
                await MainActor.run {
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

    // MARK: - Sidebar List

    @ViewBuilder
    private var sidebarList: some View {
        List(selection: sidebarSelection) {
            ForEach(messageViewModel.topics) { topic in
                let usage = messageViewModel.usage(for: topic.sessionKey)
                let normalizedKey = topic.sessionKey.map { SessionKeyNormalizer.stripPrefix($0).lowercased() } ?? ""
                let unreadCount = syncBridgeObserver.unreadCounts[normalizedKey] ?? 0
                let topicThinkingState: ThinkingState = syncBridgeObserver.isStreamingSession(topic.sessionKey) ? syncBridgeObserver.thinkingState : .idle
                SessionRow(
                    topic: topic,
                    thinkingState: topicThinkingState,
                    sessionUsage: usage,
                    unreadCount: unreadCount,
                    onReset: {
                        resetTargetSessionKey = topic.sessionKey
                        showResetAlert = true
                    }
                )
                    .tag(topic.id as String?)
                    .contextMenu {
                        Button("Reset Session") {
                            resetTargetSessionKey = topic.sessionKey
                            showResetAlert = true
                        }

                        Divider()

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
    }

    // MARK: - Reset Indicator

    @ViewBuilder
    private var resetIndicator: some View {
        if syncBridgeObserver.autoResetting {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing context...")
                    .font(.caption)
                    .foregroundColor(themeManager.color(.textSecondary))
            }
            .padding(.horizontal, themeManager.spacing(.md))
            .padding(.vertical, themeManager.spacing(.xs))
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .transition(.opacity)
        } else if syncBridgeObserver.manualResetting {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Resetting session...")
                    .font(.caption)
                    .foregroundColor(themeManager.color(.textSecondary))
            }
            .padding(.horizontal, themeManager.spacing(.md))
            .padding(.vertical, themeManager.spacing(.xs))
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .transition(.opacity)
        } else if syncBridgeObserver.showAutoResetToast {
            Text("Session refreshed")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .cornerRadius(8)
                .transition(.opacity)
        }
    }
}

extension Notification.Name {
    static let deleteSelectedTopic = Notification.Name("deleteSelectedTopic")
    static let newTopic = Notification.Name("newTopic")
}

// MARK: - Reset Session Alert Modifier

struct ResetSessionAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var resetError: String?
    @Binding var showError: Bool
    let sessionKey: String?
    let bridge: SyncBridge?

    func body(content: Content) -> some View {
        content.alert("Reset Session?", isPresented: $isPresented) {
            Button("Cancel", role: .cancel) { }
            Button("Reset") {
                if let key = sessionKey, let bridge = bridge {
                    Task {
                        do {
                            _ = try await bridge.manualReset(sessionKey: key)
                        } catch {
                            resetError = "Could not reset session. Please check your connection."
                            showError = true
                        }
                    }
                }
            }
        } message: {
            Text("The last 30 messages will be carried forward as context for the next reply.")
        }
    }
}

extension View {
    func resetSessionAlert(isPresented: Binding<Bool>, resetError: Binding<String?>, showError: Binding<Bool>, sessionKey: String?, bridge: SyncBridge?) -> some View {
        modifier(ResetSessionAlertModifier(isPresented: isPresented, resetError: resetError, showError: showError, sessionKey: sessionKey, bridge: bridge))
    }
}