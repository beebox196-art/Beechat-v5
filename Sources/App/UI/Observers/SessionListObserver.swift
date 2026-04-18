import SwiftUI
import BeeChatPersistence
import BeeChatSyncBridge

/// UI-layer observer for session list changes.
/// Wraps the SyncBridge SessionObserver AsyncStream into @Observable state.
@MainActor
@Observable
final class SessionListObserver {
    var sessions: [Session] = []

    private var streamTask: Task<Void, Never>?
    private var sessionObserver: SessionObserver?

    func startObserving(syncBridge: SyncBridge) {
        // Cancel any existing observation
        streamTask?.cancel()

        streamTask = Task { [weak self] in
            // Use the sessionListStream from SyncBridge which wraps GRDB ValueObservation
            let stream = await syncBridge.sessionListStream()
            for await sessions in stream {
                guard !Task.isCancelled else { return }
                self?.sessions = sessions
            }
        }
    }

    func stopObserving() {
        streamTask?.cancel()
        streamTask = nil
    }

    nonisolated deinit {
        // Can't access MainActor properties in deinit, but Task.cancel() is thread-safe
        // The task will be cancelled when the observer is deallocated
    }
}