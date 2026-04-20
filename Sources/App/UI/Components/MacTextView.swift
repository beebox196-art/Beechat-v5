import SwiftUI
import AppKit

/// Auto-sizing NSTextView for macOS chat composer.
/// Starts at single-line height (~36px), auto-expands up to ~160px (~6 lines).
/// Enter = newline, Cmd+Enter = send (Telegram/WhatsApp/iMessage style).
struct MacTextView: NSViewRepresentable {
    @Binding var text: String
    var onSend: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> ComposerContainer {
        let textView = ComposerTextView()

        // NSTextView config
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
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

        // Auto-sizing: vertical growth, horizontal constrained
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainerInset = NSSize(width: 8, height: 6)

        // Wire onSend
        textView.onSend = onSend

        // Set initial text
        if !text.isEmpty {
            textView.string = text
        }

        // Wire delegate
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        // Create NSScrollView for proper text wrapping
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        scrollView.documentView = textView

        // Pin text view width to scroll view width
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
        ])

        // Create container that provides intrinsicContentSize to SwiftUI
        let container = ComposerContainer(scrollView: scrollView, textView: textView)

        return container
    }

    func updateNSView(_ container: ComposerContainer, context: Context) {
        guard let textView = container.textView else { return }

        // Update onSend callback
        textView.onSend = onSend

        // Sync text from binding to view (only if different)
        if textView.string != text {
            textView.string = text
        }

        // Recalculate height
        container.recalculateHeight()
    }
}

// MARK: - ComposerContainer

/// NSView wrapper that provides intrinsicContentSize to SwiftUI based on text content height.
/// Wraps an NSScrollView containing the NSTextView for proper word wrapping.
class ComposerContainer: NSView {
    let scrollView: NSScrollView
    weak var textView: ComposerTextView?

    private let minHeight: CGFloat = 36
    private let maxHeight: CGFloat = 160
    private var currentHeight: CGFloat = 36

    init(scrollView: NSScrollView, textView: ComposerTextView) {
        self.scrollView = scrollView
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: minHeight))

        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric, height: currentHeight)
    }

    func recalculateHeight() {
        guard let textView = textView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            currentHeight = minHeight
            invalidateIntrinsicContentSize()
            return
        }

        // Force layout to get accurate measurement
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let textHeight = usedRect.height + textView.textContainerInset.height * 2
        currentHeight = min(max(textHeight, minHeight), maxHeight)
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Coordinator

extension MacTextView {
    class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: ComposerTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerTextView else { return }
            let newText = textView.string
            if text.wrappedValue != newText {
                text.wrappedValue = newText
            }
            // Update the container's height
            if let container = textView.enclosingScrollView?.superview as? ComposerContainer {
                container.recalculateHeight()
            }
        }
    }
}

// MARK: - ComposerTextView

/// NSTextView that handles key events and draws placeholder for the composer.
class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    private let placeholderText = "Type a message..."

    override func keyDown(with event: NSEvent) {
        // Enter = newline, Cmd+Enter = send (Telegram/WhatsApp/iMessage style)
        if event.keyCode == 36 { // Return
            if event.modifierFlags.contains(.command) {
                onSend?()
                return
            }
            // Plain Enter inserts newline
            super.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    /// Draw placeholder text when the text view is empty
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? NSFont.systemFont(ofSize: 14)
        ]
        let inset = textContainerInset
        let padding = textContainer?.lineFragmentPadding ?? 0
        let rect = NSRect(
            x: inset.width + padding,
            y: inset.height,
            width: bounds.width - (inset.width * 2) - (padding * 2),
            height: bounds.height - inset.height * 2
        )
        (placeholderText as NSString).draw(in: rect, withAttributes: attrs)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }
}