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
    @FocusState private var isNewTopicFieldFocused: Bool

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
                            .font(themeManager.font(.subheading))
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
                                .font(themeManager.font(.body))
                                .foregroundColor(themeManager.color(.error).opacity(0.7))
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
            VStack(spacing: 0) {
                GatewayStatusBar(connectionState: appState.connectionState, detailText: appState.offlineStatus ?? appState.errorMessage)
                Divider()

                if messageViewModel.selectedTopic != nil {
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
        guard !isGatewayWired else { return }
        isGatewayWired = true

        syncBridgeObserver.attach(bridge)

        messageViewModel.start(syncBridge: bridge)

        composerViewModel.configure(syncBridge: bridge, messageViewModel: messageViewModel)

        if let topicId = messageViewModel.selectedTopicId {
            let topicRepo = TopicRepository()
            do {
                if let sessionKey = try topicRepo.resolveSessionKey(topicId: topicId) {
                    messageViewModel.startGatewayMessageObservation(sessionKey: sessionKey)
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
                let newTopic = Topic(
                    id: UUID().uuidString,
                    name: title,
                    lastActivityAt: Date()
                )

                let topicRepo = TopicRepository()
                try topicRepo.save(newTopic)
                print("[MainWindow] Created topic: \(title) (\(newTopic.id))")

                await MainActor.run {
                    messageViewModel.addLocalTopic(newTopic)
                }

                if let bridge = appState.syncBridge {
                    do {
                        let runId = try await bridge.sendMessage(
                            sessionKey: newTopic.id,
                            text: "Start",
                            thinking: nil
                        )
                        try topicRepo.updateSessionKey(topicId: newTopic.id, sessionKey: newTopic.id)
                        try topicRepo.saveBridge(topicId: newTopic.id, sessionKey: newTopic.id)
                        print("[MainWindow] Gateway session created for topic \(newTopic.id), runId: \(runId)")
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
}

extension Notification.Name {
    static let deleteSelectedTopic = Notification.Name("deleteSelectedTopic")
}