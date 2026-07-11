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
    @State private var topicCancellable: DatabaseCancellable?
    @State private var showNewTopicDialog = false
    @State private var newTopicTitle = ""

    @State private var showDeleteAlert = false
    @State private var deleteErrorMsg: String?
    // FR-004: confirm-gate state for the 3 delete paths (trash, keyboard, notification).
    // Separate from `showDeleteAlert`/`deleteErrorMsg` (which are for *post-delete* error reporting).
    @State private var pendingDeleteTopicId: String? = nil
    @State private var showDeleteConfirmAlert: Bool = false
    // Topic Archiving: segmented Active/Archived toggle and sidebar error state.
    // `sidebarErrorTitle` / `sidebarErrorMessage` are intentionally separate from
    // `showDeleteAlert` / `deleteErrorMsg` so the alert title accurately reflects the
    // operation (Archive Error / Restore Error) instead of misleadingly showing "Delete Error".
    @State private var showArchived: Bool = false
    @State private var sidebarErrorTitle: String = ""
    @State private var sidebarErrorMessage: String = ""
    @State private var showSidebarError: Bool = false
    @State private var showResetAlert = false
    @State private var resetTargetSessionKey: String? = nil
    @State private var showResetErrorAlert = false
    @State private var resetErrorMsg: String?
    @State private var showThemePicker = false
    @State private var showFolderPicker = false
    @State private var showAgentActivity = false
    @State private var showBeeBoard = false
    @State private var showResearchPanel = false
    /// Wrapper for sheet(item:) presentation — avoids stale capture issues with .sheet(isPresented:)
    struct EditTopicTarget: Identifiable {
        let id: String
    }
    @State private var editTopicTarget: EditTopicTarget? = nil
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

    // FR-004 (Kieran re-review): single source of truth for the pending-delete topic lookup.
    // Used by the `.deleteTopicConfirmAlert(...)` modifier in `body` below for both `topicName`
    // and `messageCount` — keeps the predicate in one place and the O(n) topics scan out of
    // duplicated argument lists.
    private var pendingTopic: TopicViewModel? {
        messageViewModel.topics.first(where: { $0.id == pendingDeleteTopicId })
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Topic Archiving: segmented Active/Archived toggle above sidebarList.
                // `.onChange(of: showArchived)` cancels the prior topic observer and
                // starts a new one filtered to active or archived topics. A single
                // cancellable prevents dual-observer races.
                Picker("", selection: $showArchived) {
                    Text("Active").tag(false)
                    Text("Archived").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, themeManager.spacing(.md))
                .padding(.vertical, themeManager.spacing(.xs))
                .onChange(of: showArchived) { _, newValue in
                    startTopicObservation(archived: newValue)
                }
                .accessibilityLabel("Topic view filter")
                .accessibilityHint("Show active or archived topics")

                sidebarList

                Divider()

                HStack(spacing: 12) {
                    Button(action: { requestNewTopic() }) {
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

                    Button(action: { showResearchPanel = true }) {
                        Image(systemName: "magnifyingglass")
                            .font(themeManager.font(.body))
                            .foregroundColor(themeManager.color(.textSecondary))
                    }
                    .buttonStyle(.plain)
                    .help("Research")
                    .accessibilityLabel("Research")
                    .accessibilityHint("Open research panel")
                    .disabled(messageViewModel.selectedTopicId == nil)
                    .keyboardShortcut("r", modifiers: [.command, .shift])

                    if messageViewModel.selectedTopicId != nil && !showArchived {
                        // Topic Archiving: trash button hidden in Archived view
                        // (delete is a destructive action; archived = dormant).
                        Button(action: {
                            if let id = messageViewModel.selectedTopicId {
                                requestDeleteTopic(id)
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
            .navigationSplitViewColumnWidth(
                min: 180,
                // FR-004: ideal scales with fontScale so the sidebar grows
                // alongside body text. At 1.0 it's unchanged (240).
                // Max 480 accommodates fontScale 2.0 where body = 28pt.
                ideal: 240 + 60 * (themeManager.fontScale - 1.0),
                max: 480
            )
            .background(themeManager.color(.bgSurface))
            .onKeyPress(.delete) {
                // Topic Archiving: Delete key disabled in Archived view (v1 decision —
                // no destructive actions in Archived view).
                if showArchived { return .ignored }
                if let id = messageViewModel.selectedTopicId {
                    requestDeleteTopic(id)
                    return .handled
                }
                return .ignored
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedTopic)) { _ in
                // Same guard for the notification path: archived = read-only.
                if showArchived { return }
                if let id = messageViewModel.selectedTopicId {
                    requestDeleteTopic(id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newTopic)) { _ in
                requestNewTopic()
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
                        // Fix 2 + 3a: macOS 15+ chrome applies scrollPosition binding
                        // and anchor roles. On macOS 14 the chrome is unavailable and
                        // MessageCanvas uses its built-in ScrollViewProxy fallback.
                        canvasWithMacOS15Chrome(
                            messages: messageViewModel.messages,
                            isStreaming: isActiveTopicStreaming,
                            streamingContent: activeTopicStreamingContent,
                            completedContent: syncBridgeObserver.completedContent,
                            thinkingState: syncBridgeObserver.thinkingState,
                            canLoadEarlier: messageViewModel.canLoadEarlier,
                            topicId: messageViewModel.selectedTopicId,
                            onLoadEarlier: { messageViewModel.loadEarlierMessages() }
                        )
                        resetIndicator
                            .padding(.top, 4)
                    }
                } else {
                    Color.clear.frame(maxHeight: .infinity)
                }
                Divider()
                // Topic Archiving: Composer is read-only in Archived view (v1 decision).
                // Wrapping in `.disabled(showArchived)` greys out all interactive controls.
                Composer(viewModel: composerViewModel, onSend: composerSend)
                    .disabled(showArchived)
                    .opacity(showArchived ? 0.5 : 1.0)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(showArchived ? "Composer disabled — archived view is read-only" : "Message input")
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
            topicCancellable?.cancel()
            topicCancellable = nil
        }
        .onChange(of: appState.isReady) { _, ready in
            if ready {
                wireUpObservers()
            }
        }
        .onChange(of: messageViewModel.selectedTopicId) { _, _ in
            // Clear stale completedContent bridge when switching topics
            syncBridgeObserver.completedContent = ""
            // Clear stale pending reset context when switching topics
            if let bridge = appState.syncBridge {
                Task {
                    // H1: Resolve canonical key so both local and gateway key forms
                    // are preserved in the pending context
                    var additionalExcept: Set<String>? = nil
                    if let localKey = messageViewModel.selectedTopic?.sessionKey,
                       let canonicalKey = await bridge.resolveToCanonicalKey(localKey: localKey) {
                        additionalExcept = [canonicalKey]
                    }
                    await bridge.clearPendingResetContext(except: messageViewModel.selectedTopic?.sessionKey, exceptAdditional: additionalExcept)
                }
            }
        }
        // Clear completedContent bridge when GRDB delivers the settled message.
        // When messages change and the last assistant message has content,
        // the bridge is stale and should be cleared.
        .onChange(of: messageViewModel.messages) { _, messages in
            if !syncBridgeObserver.completedContent.isEmpty {
                if let lastAssistant = messages.last(where: { $0.role == "assistant" }),
                   let content = lastAssistant.content, !content.isEmpty {
                    syncBridgeObserver.completedContent = ""
                }
            }
        }
        // Clear completedContent bridge when streaming starts — the new stream
        // replaces any stale bridge content from a previous response.
        .onChange(of: syncBridgeObserver.isStreaming) { _, streaming in
            if streaming {
                syncBridgeObserver.completedContent = ""
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
                    .font(themeManager.font(.subheading))
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
        // Sidebar error alert (Topic Archiving): generic title set by the handler
        // ("Archive Error" / "Restore Error"). Kept separate from `showDeleteAlert`
        // so the title accurately reflects the operation (Fix 2).
        .alert(sidebarErrorTitle, isPresented: $showSidebarError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(sidebarErrorMessage)
        }
        .alert("Reset Failed", isPresented: $showResetErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(resetErrorMsg ?? "Could not reset session. Please check your connection.")
        }
        .resetSessionAlert(isPresented: $showResetAlert, resetError: $resetErrorMsg, showError: $showResetErrorAlert, sessionKey: resetTargetSessionKey, bridge: appState.syncBridge)
        .deleteTopicConfirmAlert(
            isPresented: $showDeleteConfirmAlert,
            // FR-004 (Kieran re-review): `pendingTopic` is a single computed lookup — see the
            // private computed property below. It binds to the *pending* delete target
            // (`pendingDeleteTopicId`), not the live sidebar selection: if Adam switches
            // selection while the alert is open, the alert text must still describe the
            // topic that will actually be deleted.
            topicName: pendingTopic?.title,
            messageCount: pendingTopic?.messageCount ?? 0,
            onConfirm: {
                if let id = pendingDeleteTopicId {
                    deleteTopic(id)
                    pendingDeleteTopicId = nil
                }
            }
        )
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
        .sheet(isPresented: $showResearchPanel) {
            ResearchPanel(composerViewModel: composerViewModel)
                .environment(themeManager)
        }
        .sheet(item: $editTopicTarget) { target in
            EditTopicSheetWrapper(topicId: target.id, onSave: saveTopicEdits)
                .environment(themeManager)
        }

    }


    private func wireUpObservers() {
        guard appState.isReady else { return }
        guard !isObserving else { return }
        isObserving = true

        startTopicObservation(archived: showArchived)

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

    /// Single-cancellable topic observation. `archived: true` shows archived
    /// topics; `archived: false` shows active topics. The active filter uses
    /// COALESCE(isArchived, 0) == 0 to keep legacy NULL rows visible (Fix
    /// for the `isArchived` column not being NOT NULL). Cancels any prior
    /// observation so the active/archived toggle swaps atomically.
    /// Replaces the previous `startLocalTopicObservation()` and its
    /// `localTopicCancellable` — single cancellable prevents dual-observer
    /// leaks (Fix 1 / R2).
    private func startTopicObservation(archived: Bool) {
        topicCancellable?.cancel()
        topicCancellable = nil

        let observation = ValueObservation.tracking { db -> [Topic] in
            if archived {
                return try Topic
                    .filter(Column("isArchived") == true)
                    .order(Column("lastActivityAt").desc)
                    .limit(100)
                    .fetchAll(db)
            } else {
                // COALESCE guard: schema defines `.defaults(to: false)` but
                // without `.notNull()`, so legacy rows can be NULL and would
                // disappear from the active view without this.
                return try Topic
                    .filter(sql: "COALESCE(isArchived, 0) = 0")
                    .order(Column("lastActivityAt").desc)
                    .limit(100)
                    .fetchAll(db)
            }
        }

        do {
            let writer = try DatabaseManager.shared.writer
            topicCancellable = observation.start(
                in: writer,
                scheduling: .mainActor,
                onError: { error in
                    BeeChatLogger.log("[MainWindow] Topic observation error: \(error)")
                },
                onChange: { [weak messageViewModel] topics in
                    messageViewModel?.updateTopics(from: topics)
                }
            )
        } catch {
            BeeChatLogger.log("[MainWindow] Failed to start topic observation: \(error)")
        }
    }


    private func composerSend() {
        Task {
            await composerViewModel.send()
        }
    }

    /// Opens the New Topic dialog. If we're in the Archived view, force a
    /// switch back to Active first (v1 decision — Archived is view-only,
    /// so creating a new topic from there would be surprising).
    private func requestNewTopic() {
        if showArchived {
            showArchived = false
            startTopicObservation(archived: false)
            // Clear orphaned selection: archived topic is no longer visible in Active view
            if let selected = messageViewModel.selectedTopicId,
               !messageViewModel.topics.contains(where: { $0.id == selected }) {
                messageViewModel.selectedTopicId = nil
            }
        }
        showNewTopicDialog = true
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
                        // Topic sync now via REST endpoint (see TopicServer.swift)
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

    // FR-004: Gate the delete behind a native SwiftUI confirmation alert.
    // The alert is wired in body via `.deleteTopicConfirmAlert(...)`; on confirm it calls `deleteTopic(_:)`.
    private func requestDeleteTopic(_ id: String) {
        pendingDeleteTopicId = id
        showDeleteConfirmAlert = true
    }

    private func deleteTopic(_ id: String) {
        Task { @MainActor in
            do {
                let topicRepo = TopicRepository()
                // Clear gateway metadata before local delete
                if let topic = try topicRepo.fetchById(id),
                   let sessionKey = topic.sessionKey,
                   let bridge = appState.syncBridge {
                    _ = bridge // silence unused warning
                }
                try topicRepo.deleteCascading(id)
                messageViewModel.removeTopic(id: id)
                // Topic sync now via REST endpoint (see TopicServer.swift)
            } catch {
                print("🔴 Delete topic failed: \(error)")
                deleteErrorMsg = error.localizedDescription
                showDeleteAlert = true
            }
        }
    }

    // MARK: - Topic Archiving (handlers)

    /// Archive the topic with the given ID. If the archived topic is currently
    /// selected, fall back to the first remaining topic (mirrors delete behaviour
    /// — see R1 in the spec). ValueObservation refreshes the sidebar automatically;
    /// `removeTopic(id:)` is only called to keep selection valid mid-frame.
    private func archiveTopic(_ id: String) {
        Task { @MainActor in
            do {
                let topicRepo = TopicRepository()
                try topicRepo.archive(topicId: id)
                if messageViewModel.selectedTopicId == id {
                    messageViewModel.removeTopic(id: id)
                }
            } catch {
                BeeChatLogger.log("🔴 Archive topic failed: \(error)")
                sidebarErrorTitle = "Archive Error"
                sidebarErrorMessage = "Could not archive topic: \(error.localizedDescription)"
                showSidebarError = true
            }
        }
    }

    /// Restore the archived topic with the given ID. The sidebar refreshes
    /// automatically via the active-topic ValueObservation when the row
    /// reappears in the Active view.
    private func restoreTopic(_ id: String) {
        Task { @MainActor in
            do {
                let topicRepo = TopicRepository()
                try topicRepo.restore(topicId: id)
                // ValueObservation refreshes sidebar automatically
            } catch {
                BeeChatLogger.log("🔴 Restore topic failed: \(error)")
                sidebarErrorTitle = "Restore Error"
                sidebarErrorMessage = "Could not restore topic: \(error.localizedDescription)"
                showSidebarError = true
            }
        }
    }

    private func saveTopicEdits(_ updatedTopic: Topic) {
        Task { @MainActor in
            do {
                // Detect project path change so we can re-inject context
                let repo = TopicRepository()
                let oldTopic = try repo.fetchById(updatedTopic.id)
                let oldProjectPath = oldTopic?.projectPath
                let newProjectPath = updatedTopic.projectPath

                // Save the topic (name + metadataJSON with projectPath already set via setProjectPath)
                try repo.save(updatedTopic)

                // If project binding changed, requeue context injection so next message gets [PROJECT-CONTEXT]
                if oldProjectPath != newProjectPath, let sessionKey = updatedTopic.sessionKey, let bridge = appState.syncBridge {
                    await bridge.requeueContextInjection(sessionKey: sessionKey)
                }

                // Topic sync now via REST endpoint (see TopicServer.swift)

                // Force a refresh of the topics list so the sidebar updates
                startTopicObservation(archived: showArchived)
            } catch {
                print("🔴 Save topic edits failed: \(error)")
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
                let projectState: SessionRow.ProjectContextState = {
                    guard let path = topic.projectPath else { return .none }
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    return .linked(projectName: name)
                }()
                SessionRow(
                    topic: topic,
                    thinkingState: topicThinkingState,
                    sessionUsage: usage,
                    unreadCount: unreadCount,
                    onReset: {
                        resetTargetSessionKey = topic.sessionKey
                        showResetAlert = true
                    },
                    onSelect: {
                        editTopicTarget = EditTopicTarget(id: topic.id)
                    },
                    onMarkUnread: { markUnread in
                        syncBridgeObserver.setUnread(for: topic.sessionKey, count: markUnread ? 1 : 0)
                    },
                    onArchive: showArchived ? nil : { archiveTopic(topic.id) },
                    onRestore: showArchived ? { restoreTopic(topic.id) } : nil,
                    // Topic Archiving: archived view hides Reset Session and Save Topic
                    // Summary (v1 decision — archived = dormant). The SessionRow receives
                    // nil handlers and the menu items disappear.
                    isArchived: showArchived,
                    isSelected: sidebarSelection.wrappedValue == topic.id,
                    projectContextState: projectState,
                    bridge: appState.syncBridge
                )
                    .tag(topic.id as String?)
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
                    .font(themeManager.font(.caption))
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
                    .font(themeManager.font(.caption))
                    .foregroundColor(themeManager.color(.textSecondary))
            }
            .padding(.horizontal, themeManager.spacing(.md))
            .padding(.vertical, themeManager.spacing(.xs))
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .transition(.opacity)
        } else if syncBridgeObserver.showAutoResetToast {
            Text("Session refreshed")
                .font(themeManager.font(.caption))
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

// MARK: - Edit Topic Sheet Wrapper

/// Fetches the actual Topic from the database before presenting the edit sheet.
struct EditTopicSheetWrapper: View {
    let topicId: String?
    let onSave: (Topic) -> Void
    @Environment(ThemeManager.self) var themeManager
    @State private var topic: Topic? = nil
    @State private var isLoading = true
    @State private var loadError: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let topic = topic {
                EditTopicSheet(topic: topic, onSave: onSave)
            } else if let error = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(themeManager.font(.heading))
                        .foregroundColor(themeManager.color(.error))
                    Text("Could not load topic")
                        .font(themeManager.font(.heading))
                        .foregroundColor(themeManager.color(.textPrimary))
                    Text(error)
                        .font(themeManager.font(.caption))
                        .foregroundColor(themeManager.color(.textSecondary))
                    Button("Dismiss") {
                        dismiss()
                    }
                    .font(themeManager.font(.body))
                    .foregroundColor(themeManager.color(.accentPrimary))
                }
                .padding(24)
                .frame(minWidth: 400, minHeight: 300)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading topic...")
                        .font(themeManager.font(.body))
                        .foregroundColor(themeManager.color(.textSecondary))
                }
                .frame(minWidth: 400, minHeight: 300)
            }
        }
        .onAppear {
            loadTopic()
        }
    }

    private func loadTopic() {
        guard let id = topicId else {
            loadError = "No topic selected."
            isLoading = false
            print("[EditTopicSheetWrapper] loadTopic: topicId is nil")
            return
        }
        print("[EditTopicSheetWrapper] loadTopic: fetching topic id=\(id)")
        Task { @MainActor in
            do {
                print("[EditTopicSheetWrapper] loadTopic: fetching from database...")
                let repo = TopicRepository()
                topic = try repo.fetchById(id)
                if let t = topic {
                    print("[EditTopicSheetWrapper] Loaded topic: \(t.name) (id=\(t.id))")
                } else {
                    print("[EditTopicSheetWrapper] Topic not found for id=\(id)")
                    loadError = "Topic not found."
                }
            } catch {
                print("[EditTopicSheetWrapper] Failed to load topic \(id): \(error)")
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }
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

// MARK: - Delete Topic Confirm Modifier (FR-004)

struct DeleteTopicConfirmAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    let topicName: String?
    let messageCount: Int
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.alert("Delete \(topicName ?? "topic")?", isPresented: $isPresented) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                onConfirm()
            }
        } message: {
            if messageCount == 0 {
                Text("This topic is empty. This cannot be undone.")
            } else if messageCount == 1 {
                Text("This topic has 1 message. This cannot be undone.")
            } else {
                Text("This topic has \(messageCount) messages. This cannot be undone.")
            }
        }
    }
}

extension View {
    func deleteTopicConfirmAlert(
        isPresented: Binding<Bool>,
        topicName: String?,
        messageCount: Int,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(DeleteTopicConfirmAlertModifier(
            isPresented: isPresented,
            topicName: topicName,
            messageCount: messageCount,
            onConfirm: onConfirm
        ))
    }
}

/// Wraps MessageCanvas in the macOS 15+ scroll-position chrome when available.
/// On macOS 14 the chrome is absent and MessageCanvas uses its ScrollViewProxy
/// fallback (jump button hidden, single-arg `.defaultScrollAnchor(.bottom)`).
@ViewBuilder
func canvasWithMacOS15Chrome(
    messages: [Message],
    isStreaming: Bool,
    streamingContent: String,
    completedContent: String,
    thinkingState: ThinkingState,
    canLoadEarlier: Bool,
    topicId: String?,
    onLoadEarlier: @escaping () -> Void
) -> some View {
    let canvas = MessageCanvas(
        messages: messages,
        isStreaming: isStreaming,
        streamingContent: streamingContent,
        completedContent: completedContent,
        thinkingState: thinkingState,
        canLoadEarlier: canLoadEarlier,
        topicId: topicId,
        onLoadEarlier: onLoadEarlier
    )
    if #available(macOS 15.0, *) {
        MacOS15ScrollPositionChrome(topicId: topicId) { canvas }
    } else {
        canvas
    }
}
