import SwiftUI
import AppKit

/// Auto-sizing NSTextView for macOS chat composer.
/// Starts at single-line height (~32px), auto-expands up to ~120px (5 lines).
/// Enter = send, Shift+Enter = newline, Cmd+Enter = send.
struct MacTextView: NSViewRepresentable {
    @Binding var text: String
    var onSend: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> AutoSizingTextView {
        let textView = AutoSizingTextView()

        // Bare NSTextView config (no scroll view)
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .clear
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.focusRingType = .none
        textView.isRichText = false
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        // Auto-sizing configuration
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.minSize = NSSize(width: 0, height: 32)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 120)
        textView.textContainerInset = NSSize(width: 0, height: 4)

        // Placeholder is handled via custom draw override in AutoSizingTextView

        // Wire onSend
        textView.onSend = onSend

        // Set initial text
        if !text.isEmpty {
            textView.string = text
        }

        // Wire delegate
        textView.delegate = context.coordinator

        return textView
    }

    func updateNSView(_ textView: AutoSizingTextView, context: Context) {
        // Update onSend callback
        textView.onSend = onSend

        // Sync text from binding to view (only if different)
        if textView.string != text {
            textView.string = text
            textView.invalidateIntrinsicContentSize()
        }
    }
}

// MARK: - Coordinator

extension MacTextView {
    class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? AutoSizingTextView else { return }
            let newText = textView.string
            if text.wrappedValue != newText {
                text.wrappedValue = newText
            }
            textView.invalidateIntrinsicContentSize()
        }
    }
}

// MARK: - AutoSizingTextView

/// Bare NSTextView that auto-sizes based on text content.
/// No NSScrollView — the text view IS the document view.
class AutoSizingTextView: NSTextView {
    var onSend: (() -> Void)?
    private var minHeight: CGFloat = 32
    private var maxHeight: CGFloat = 120
    private let placeholderText = "Type a message..."

    override var intrinsicContentSize: NSSize {
        let containerWidth = textContainer?.containerSize.width ?? frame.width
        let rect = layoutManager?.usedRect(for: textContainer!) ?? NSRect(x: 0, y: 0, width: containerWidth, height: minHeight)
        let height = min(max(rect.height + textContainerInset.height * 2, minHeight), maxHeight)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func keyDown(with event: NSEvent) {
        // Enter = send (no modifier), Shift+Enter = newline, Cmd+Enter = send
        if event.keyCode == 36 { // Return
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event) // insert newline
                return
            }
            onSend?()
            return
        }
        super.keyDown(with: event)
    }

    /// Draw placeholder text when the text view is empty and not focused
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !isFirstResponder else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? NSFont.systemFont(ofSize: 14)
        ]
        let inset = textContainerInset
        let rect = NSRect(x: inset.width, y: inset.height, width: bounds.width - inset.width * 2, height: bounds.height - inset.height * 2)
        (placeholderText as NSString).draw(in: rect, withAttributes: attrs)
    }

    private var isFirstResponder: Bool {
        window?.firstResponder === self
    }
}