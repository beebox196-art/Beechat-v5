import SwiftUI
import AppKit

/// Auto-sizing NSTextView for macOS chat composer.
/// Starts at single-line height (~36px), auto-expands up to ~160px (~6 lines).
struct MacTextView: NSViewRepresentable {
    @Binding var text: String
    var onSend: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> ComposerContainer {
        let textView = ComposerTextView()

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

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainerInset = NSSize(width: 8, height: 6)

        textView.onSend = onSend

        if !text.isEmpty {
            textView.string = text
        }

        textView.delegate = context.coordinator
        context.coordinator.textView = textView

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

        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
        ])

        let container = ComposerContainer(scrollView: scrollView, textView: textView)

        return container
    }

    func updateNSView(_ container: ComposerContainer, context: Context) {
        guard let textView = container.textView else { return }

        textView.onSend = onSend

        if textView.string != text {
            textView.string = text
        }

        container.recalculateHeight()
    }
}

// MARK: - ComposerContainer

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
            if let container = textView.enclosingScrollView?.superview as? ComposerContainer {
                container.recalculateHeight()
            }
        }
    }
}

// MARK: - ComposerTextView

class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    private let placeholderText = "Type a message..."

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Return
            if event.modifierFlags.contains(.command) {
                onSend?()
                return
            }
            super.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

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