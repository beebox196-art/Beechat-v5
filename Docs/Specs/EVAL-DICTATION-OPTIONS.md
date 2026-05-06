# EVAL: Mac Dictation Input Options for BeeChat Composer

**Date:** 2026-05-06  
**Status:** Evaluation only — no implementation  
**Component:** App UI / Composer  
**Goal:** Repurpose the existing Composer mic button so Adam can dictate text into the message field, preferably by using macOS built-in dictation rather than building a full voice pipeline.

---

## Source findings

### Existing Composer mic button

`Sources/App/UI/Components/Composer.swift` already renders a trailing mic button:

- Icon: `mic.fill` when idle, `stop.fill` while recording.
- Action: `toggleRecording()`.
- `toggleRecording()` calls:
  - `viewModel.startRecording()` when idle.
  - `viewModel.stopRecording()` when `isRecording == true`.

The attachment picker also has a `Voice Note` action that calls `viewModel.startRecording()`.

### Existing recording implementation

`Sources/App/UI/ViewModels/ComposerViewModel.swift` currently only stores state:

- `startRecording()` sets `isRecording = true`.
- `stopRecording()` sets `isRecording = false`.
- There is no microphone capture, file recording, speech recognition, transcription, or message insertion yet.

So the mic button is visually wired, but the recording feature is effectively a stub.

### ChatField / text input implementation

BeeChat depends on the local `Vendors/ChatField` package. On macOS, `Vendors/ChatField/Sources/ChatField/BaseTextField.swift` uses:

```swift
TextField(titleKey, text: $text, axis: .vertical)
```

with SwiftUIIntrospect applied to `.textField(axis: .vertical)` to access the underlying AppKit text field and set wrapping.

Implication: BeeChat's composer is ultimately a standard SwiftUI/AppKit text input. When focused, it should already support normal macOS text services, including user-invoked system dictation. The missing piece is whether BeeChat can start that dictation session from its own mic button.

---

## Option A — Trigger macOS system dictation

### What this means

Focus the composer text field, then ask macOS to start its built-in dictation UI so dictated words are inserted directly into the existing `inputText` binding.

### Can a SwiftUI app trigger it directly?

There does not appear to be a supported public AppKit/SwiftUI API whose purpose is “start dictation in this text field”. Standard text fields can receive dictation when the user invokes the system shortcut, but exposing that same activation as an app API is the problem.

There are three possible sub-routes:

#### A1. User invokes macOS dictation manually

This already works if the composer is focused and the user's macOS Dictation is enabled. BeeChat only needs to keep focus in the `ChatField`.

- **Code:** none.
- **Reliability:** high, because macOS owns it.
- **User experience:** not Adam's requested button behavior.

#### A2. Simulate the dictation keyboard shortcut

A button could focus the field and synthesize the configured dictation shortcut with `CGEvent`/`NSEvent`.

Problems:

- The default shortcut varies by macOS version, keyboard type, and user settings.
- Fn/Globe key simulation is not as reliable as ordinary key codes.
- If Adam changes the Dictation shortcut in System Settings, hard-coded events break.
- Posting global keyboard events may require Accessibility/Input Monitoring trust depending on event path and macOS policy.

This is the smallest code path, but it is brittle.

#### A3. Send AppKit's hidden/private dictation action

Runtime header dumps show an internal `startDictation:` selector on `NSApplication`, and macOS apps have an Edit-menu dictation command in text contexts. A hacky implementation could try the responder chain, for example by sending `Selector(("startDictation:"))` to `nil` after focusing the field.

Problems:

- This is not documented as public API in the SDK headers checked locally.
- It may compile only through string selectors, not typed public selectors.
- It may fail App Store review if treated as private API. BeeChat may not be App Store-bound, but private API still creates OS-version risk.
- It needs hands-on testing on Adam's Mac because behavior may depend on first responder/field editor state.

### NSTextInputClient / underlying field support

The `ChatField` path should already be compatible with system dictation because it is a standard SwiftUI `TextField` backed by AppKit text input machinery. `NSTextInputClient` is not something BeeChat needs to implement unless we replace the text field with a custom text editor. It enables input-method integration; it is not a public “start dictation now” control surface.

### Verdict

- **Simplest:** yes, if a private/responder-chain action or keyboard shortcut works.
- **Most reliable:** no.
- **Best use:** quick prototype only.

Recommended experiment before writing a full recognizer:

1. Ensure the composer field is focused.
2. Try sending the dictation action through the responder chain with a string selector.
3. If that fails, try a user-configurable shortcut simulation only as a local/personal build convenience.
4. Do not rely on this as the product-grade implementation.

---

## Option B — Direct dictation with `SFSpeechRecognizer`

### What this means

Ignore macOS keyboard dictation and implement BeeChat's own speech-to-text input:

1. User taps the mic button.
2. BeeChat records microphone audio with `AVAudioEngine`.
3. BeeChat streams buffers into `SFSpeechAudioBufferRecognitionRequest`.
4. `SFSpeechRecognizer` returns partial/final transcripts.
5. BeeChat writes the transcript into `viewModel.inputText`.
6. User edits or presses Send as normal.

This is the input-only subset of the existing `FEAT-005-TALK-MODE.md` Phase 1 idea. It does not need TTS, VAD for conversation, or gateway talk RPCs unless we later expand to Talk Mode.

### Requirements

- `NSMicrophoneUsageDescription` in Info.plist.
- `NSSpeechRecognitionUsageDescription` in Info.plist.
- Request `SFSpeechRecognizer` authorization.
- Handle recognizer availability and errors.
- Decide whether to replace current draft text or append to it.
- Decide how to handle partial results to avoid duplicate text.
- Add visible recording state and a stop/cancel path.

### Effort

Likely ~100–250 lines for a minimal local `DictationManager` plus ComposerViewModel integration, depending on how polished the partial-result handling is.

Minimal shape:

- `DictationManager` owns `SFSpeechRecognizer`, recognition request/task, and `AVAudioEngine`.
- `ComposerViewModel.startRecording()` starts dictation instead of just setting a flag.
- Partial transcript is displayed while listening.
- `stopRecording()` stops audio, finalizes text, resets `isRecording`.

### Risks / gotchas

- User permission prompts are unavoidable.
- Apple documents recognition availability as dynamic; creating a recognizer does not guarantee service availability.
- Some languages or modes may require an internet connection unless on-device recognition is supported and requested.
- Apple documents practical recognition limits, including short-form/roughly one-minute task constraints.
- SFSpeech gives recognition results; it does not provide a complete dictation UI, automatic punctuation behavior identical to system dictation, or the same personal dictionary behavior.

### Verdict

- **Simplest:** no.
- **Most reliable programmatic option:** yes.
- **Best use:** recommended implementation if the button must reliably start dictation from inside BeeChat.

---

## Option C — `NSTextInputContext` / `NSTextInputClient`

### What this means

Use AppKit's text input system directly to activate dictation through `NSTextInputContext` or related APIs.

### Evaluation

`NSTextInputContext` coordinates input methods and communicates with an `NSTextInputClient`. It is relevant for composed text, IMEs, marked ranges, candidate windows, and custom text controls.

It does not appear to expose a public method for starting macOS dictation. The composer already uses a standard SwiftUI/AppKit text field, so BeeChat should not need to implement `NSTextInputClient` itself.

SwiftUI has newer dictation-related APIs such as `TextInputDictationActivation`, but Apple's docs describe them in the context of `.searchable` search fields, not arbitrary app text fields or a custom Composer button.

### Verdict

- **Simplest:** no.
- **Reliable:** no clear path.
- **Best use:** not recommended; dead end for this feature.

---

## Option D — `NSSpeechRecognizer`

### What this means

Use AppKit's older `NSSpeechRecognizer` API.

### Evaluation

`NSSpeechRecognizer` is command-and-control recognition: the app defines a list of phrases/commands and listens for those commands. It is not a general dictation/transcription API for arbitrary free-form message text.

### Verdict

Not suitable for Composer dictation. Use `SFSpeechRecognizer` or a newer Speech framework transcription API instead.

---

## Option E — Newer Speech framework APIs (`SpeechAnalyzer`)

Apple has newer speech-to-text APIs beyond `SFSpeechRecognizer`. They may become the better long-term path for richer transcription on newer macOS versions.

For BeeChat right now, this is probably overkill:

- The project targets macOS 14 in `Package.swift`.
- `SFSpeechRecognizer` is available and sufficient for short composer dictation.
- The ask is to repurpose the existing mic button, not build a full transcription subsystem.

Keep this in mind only if `SFSpeechRecognizer` proves unreliable or if BeeChat later needs long-form transcription.

---

## Long-press / alternate tap UX

Possible UI mapping:

### Recommended simple UX

- **Tap mic:** start/stop BeeChat dictation via `SFSpeechRecognizer`.
- **Send button:** unchanged.
- **While recording:** show red mic/stop state using the existing `isRecording` UI.

### If we want to preserve future voice-note semantics

- **Tap mic:** dictate into composer.
- **Long press mic:** voice note / audio recording later.
- **Attachment > Voice Note:** keep reserved for future audio attachment recording.

Because the current recording code is a stub, repurposing the mic tap for dictation does not remove working functionality.

---

## Recommendation

### Best immediate path

Run a tiny local experiment with the native dictation action before implementing speech recognition:

1. Keep `ChatField` focused (`isTextFieldFocused = true`).
2. Try the AppKit responder-chain/private selector route for `startDictation:`.
3. If it works reliably on Adam's Mac, the implementation is tiny and gives the exact native macOS dictation behavior.
4. If it fails or feels flaky, discard it quickly.

This experiment should be time-boxed because it relies on undocumented behavior.

### Best reliable product path

Implement input-only dictation with `SFSpeechRecognizer`.

Why:

- It is public API.
- It is controlled by BeeChat, not by the user's hidden Dictation shortcut settings.
- It fits the existing `ComposerViewModel.startRecording()` / `stopRecording()` shape.
- It can be developed as a small precursor to future Talk Mode without committing to full voice conversation now.

### What not to do

- Do not build around `NSTextInputContext`; it is the wrong layer.
- Do not use `NSSpeechRecognizer` for free-form message dictation.
- Do not make keyboard-shortcut simulation the default product behavior unless Adam accepts it as a personal, best-effort hack.

---

## Final ranking

| Option | Code size | Reliability | Native macOS feel | Permissions | Recommendation |
|---|---:|---:|---:|---:|---|
| A1 manual system dictation | none | high | high | system-managed | Useful fallback, not button-driven |
| A2 shortcut simulation | tiny | low-medium | high if it works | possible Accessibility/Input Monitoring | Personal hack only |
| A3 `startDictation:` responder/private action | tiny | unknown | high if it works | system-managed/private-risk | Time-boxed experiment |
| B `SFSpeechRecognizer` | medium | medium-high | medium | Microphone + Speech | Recommended reliable implementation |
| C `NSTextInputContext` | unknown | low | unknown | unknown | Do not pursue |
| D `NSSpeechRecognizer` | small | low for dictation | low | Microphone | Wrong API |

---

## Confidence

**Moderate-high** on the source-code findings and API direction.  
**Moderate** on the native dictation action route because it requires hands-on validation on the target macOS environment.