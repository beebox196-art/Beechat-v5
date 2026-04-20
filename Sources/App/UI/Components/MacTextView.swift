import SwiftUI
import AppKit

/// Auto-sizing NSTextView for macOS chat composer.
/// Starts at single-line height (~36px), auto-expands up to ~160px (~6 lines).
/// Enter = send, Shift+Enter = newline, Cmd+Enter = send.
/// Wraps NSTextView in NSScrollView for internal scrolling past maxHeight.
struct MacTextView: NSViewRepresentable {
    @Binding var text: String
    var onSend: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> IntrinsicSizeScrollView {
        let textView = AutoSizingTextView()

        // Bare NSTextView config
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
        textView.minSize = NSSize(width: 0, height: 36)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 4)

        // Wire onSend
        textView.onSend = onSend

        // Set initial text
        if !text.isEmpty {
            textView.string = text
        }

        // Wire delegate
        textView.delegate = context.coordinator

        // Wrap in NSScrollView
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        // Use flipped document view so text flows top-down
        let clipView = scrollView.contentView
        clipView.drawsBackground = false

        scrollView.documentView = textView

        // Pin text view width to scroll view width
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
        ])

        // Store reference for coordinator updates
        context.coordinator.textView = textView

        // Wrap in IntrinsicSizeScrollView so SwiftUI sees the correct intrinsic size
        let container = IntrinsicSizeScrollView(scrollView: scrollView, textView: textView)

        return container
    }

    func updateNSView(_ container: IntrinsicSizeScrollView, context: Context) {
        guard let textView = container.textView else { return }

        // Update onSend callback
        textView.onSend = onSend

        // Sync text from binding to view (only if different)
        if textView.string != text {
            textView.string = text
            textView.invalidateIntrinsicContentSize()
        }

        // Recompute intrinsic content size for the container
        textView.invalidateIntrinsicContentSize()
        container.invalidateIntrinsicContentSize()
    }
}

// MARK: - IntrinsicSizeScrollView

/// NSView container that wraps an NSScrollView and forwards intrinsicContentSize
/// from the document view (AutoSizingTextView). This is necessary because
/// NSScrollView returns noIntrinsicMetric for both dimensions, so SwiftUI
/// cannot determine the correct size for the text input.
class IntrinsicSizeScrollView: NSView {
    let scrollView: NSScrollView
    weak var textView: AutoSizingTextView?

    private let minHeight: CGFloat = 36
    private let maxHeight: CGFloat = 160

    init(scrollView: NSScrollView, textView: AutoSizingTextView) {
        self.scrollView = scrollView
        self.textView = textView
        super.init(frame: .zero)
        addSubview(scrollView)

        // Pin scroll view to container edges
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
        guard let textView = textView else {
            return NSSize(width: NSView.noIntrinsicMetric, height: minHeight)
        }
        let textViewSize = textView.intrinsicContentSize
        let height = min(max(textViewSize.height, minHeight), maxHeight)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }
}

// MARK: - Coordinator

extension MacTextView {
    class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: AutoSizingTextView?

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
            // Invalidate the IntrinsicSizeScrollView container
            if let container = textView.enclosingScrollView?.superview as? IntrinsicSizeScrollView {
                container.invalidateIntrinsicContentSize()
            }
        }
    }
}

// MARK: - AutoSizingTextView

/// Bare NSTextView that auto-sizes based on text content.
/// Used as the document view inside an NSScrollView.
class AutoSizingTextView: NSTextView {
    var onSend: (() -> Void)?
    private let minHeight: CGFloat = 36
    private let maxHeight: CGFloat = 160
    private let placeholderText = "Type a message..."

    override var intrinsicContentSize: NSSize {
        guard let textContainer = textContainer,
              let layoutManager = layoutManager else {
            return NSSize(width: NSView.noIntrinsicMetric, height: minHeight)
        }
        let usedRect = layoutManager.usedRect(for: textContainer)
        let textHeight = usedRect.height + textContainerInset.height * 2
        let height = min(max(textHeight, minHeight), maxHeight)
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
        let rect = NSRect(
            x: inset.width,
            y: inset.height,
            width: bounds.width - inset.width * 2,
            height: bounds.height - inset.height * 2
        )
        (placeholderText as NSString).draw(in: rect, withAttributes: attrs)
    }

    private var isFirstResponder: Bool {
        window?.firstResponder === self
    }
}