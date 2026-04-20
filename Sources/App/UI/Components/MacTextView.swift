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

    func makeNSView(context: Context) -> ComposerTextViewWrapper {
        let wrapper = ComposerTextViewWrapper()
        let textView = wrapper.textView

        // Wire delegate
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.wrapper = wrapper

        // Wire onSend
        textView.onSend = onSend

        // Set initial text
        if !text.isEmpty {
            textView.string = text
        }

        return wrapper
    }

    func updateNSView(_ wrapper: ComposerTextViewWrapper, context: Context) {
        let textView = wrapper.textView

        // Update onSend callback
        textView.onSend = onSend

        // Sync text from binding to view (only if different)
        if textView.string != text {
            textView.string = text
            wrapper.recalculateHeight()
        }
    }
}

// MARK: - ComposerTextViewWrapper

/// NSView wrapper that contains an NSTextView and constrains its height.
/// Uses explicit height constraints rather than intrinsicContentSize,
/// which is more reliable for controlling size in SwiftUI.
class ComposerTextViewWrapper: NSView {
    let textView: AutoSizingTextView
    private var heightConstraint: NSLayoutConstraint!

    private let minHeight: CGFloat = 36
    private let maxHeight: CGFloat = 160

    init() {
        textView = AutoSizingTextView()

        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: minHeight))

        // Configure NSTextView
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

        // Auto-sizing configuration
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainerInset = NSSize(width: 8, height: 6)

        // Add text view as subview
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)

        // Constrain text view to fill wrapper
        heightConstraint = textView.heightAnchor.constraint(equalToConstant: minHeight)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Start with minimum height
        self.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        self.heightAnchor.constraint(lessThanOrEqualToConstant: maxHeight).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        // Get current height from the text content
        let height = calculateDesiredHeight()
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    /// Calculate the desired height based on text content
    func recalculateHeight() {
        let desiredHeight = calculateDesiredHeight()
        invalidateIntrinsicContentSize()
        // Force SwiftUI layout update
        frame.size.height = desiredHeight
        textView.frame.size.height = desiredHeight
    }

    private func calculateDesiredHeight() -> CGFloat {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return minHeight
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let textHeight = usedRect.height + textView.textContainerInset.height * 2
        return min(max(textHeight, minHeight), maxHeight)
    }
}

// MARK: - Coordinator

extension MacTextView {
    class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: AutoSizingTextView?
        weak var wrapper: ComposerTextViewWrapper?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? AutoSizingTextView else { return }
            let newText = textView.string
            if text.wrappedValue != newText {
                text.wrappedValue = newText
            }
            // Update wrapper height
            wrapper?.recalculateHeight()
        }
    }
}

// MARK: - AutoSizingTextView

/// NSTextView that handles key events for the composer.
class AutoSizingTextView: NSTextView {
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