# BeeChat Diagnostic Logging Standard

Diagnostic events belong in unified logging (`Logger` / os.log). Every diagnostic
event is mirrored there unconditionally using private/default privacy and must use
event metadata only: never tokens, secrets, user message content, or personally
identifying information.

File logs are exceptional and follow one implementation: `BoundedFileLog` in the
`BeeChatLogging` target.

- File output is gated by `BEE_DEBUG_LOG=1` and is disabled by default.
- Paths are home-relative and outside Desktop. The gateway alone retains the
  explicit `BEE_DEBUG_LOG_PATH` diagnostic override.
- Each sink uses one file, mode `0600`, with a 1 MB cap and in-place retention of
  the last 256 KB. It never creates numbered or dated generations. A single
  oversized record is suffix-trimmed so the file itself still cannot exceed cap.
- Production code, seeds, and new migrations must not introduce hardcoded absolute
  user paths. The sole historical exception is an exact cleanup predicate in
  `Migration016_RemovePristineOversightBookmark`; it identifies and removes the
  old defective seed and is not used as a runtime destination.
- Adding a file sink requires a justification comment and behavioural tests for
  default-off gating, bounded growth, one-file generation count, and permissions.

Default diagnostic paths:

- Gateway: `~/Library/Logs/BeeChat-debug.log`
- App diagnostics: `~/Library/Logs/BeeChat-diagnostics.log`

## Sink inventory verification (2026-09-24)

The release source was checked by name, beyond the absolute-path guard:

- URLSession `EventMonitor` / `cURLDescription`: absent. `WebSocketTransport` uses
  `URLSessionWebSocketDelegate` directly and does not dump requests.
- GRDB `.trace`: absent.
- `os_log` `%{public}` with sensitive arguments: absent. Existing `Logger` sites
  remain unified-log sinks; the new mirrors use `.private` interpolation.
- Crash reporters and signal sinks (Sentry, Crashlytics,
  `NSSetUncaughtExceptionHandler`, and `signal`): absent.
- `TopicSummaryWriter` and `ProjectScaffolder`: present, reviewed as user-requested
  content writers rather than diagnostic-log sinks. They remain outside this
  logging change.

Verification searches:

```sh
rg -n 'EventMonitor|cURLDescription' Sources Package.swift
rg -n '\.trace\b' Sources
rg -n 'os_log|%\{public\}' Sources
rg -n 'Sentry|Crashlytics|NSSetUncaughtExceptionHandler|signal\(' Sources Package.swift
rg -n 'TopicSummaryWriter|ProjectScaffolder' Sources
```

## Bookmark consumer check

The actual reader of `bookmarks` is `BookmarkRepository.fetchAll()`, called by
`FolderPicker.loadBookmarks()`. It returns an ordinary empty array when no rows
exist. `FolderPicker` renders that empty array and does not force-unwrap a bookmark,
call `try!`, or assume a `sortOrder == 4` row. Migration fixtures exercise this
empty-reader behaviour as well as pristine deletion and modified-row retention.
