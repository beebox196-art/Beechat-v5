import SwiftUI
import AppKit

/// NSTextView wrapper for reliable macOS multiline text input.
/// SwiftUI TextEditor has known quirks with .lineLimit ranges on macOS;
/// this wrapper uses NSTextView for proper auto-expand behaviour.
struct MacTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = CustomNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isFieldEditor = false
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 4)

        // Minimum height constraint via text container
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Set initial text
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CustomNSTextView else { return }

        // Avoid update cycles
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newText = textView.string
            if text.wrappedValue != newText {
                text.wrappedValue = newText
            }
        }
    }
}

/// Custom NSTextView that handles Enter key for send (Cmd+Enter = send, Enter = newline).
class CustomNSTextView: NSTextView {
    var onSend: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Cmd+Enter sends the message
        if event.modifierFlags.contains(.command) && event.keyCode == 36 { // 36 = Return
            onSend?()
            return
        }
        super.keyDown(with: event)
    }
}