import SwiftUI
import AppKit

/// NSTextField wrapper for macOS — starts as a single line, expands up to ~5 lines.
/// Much simpler and more reliable than NSScrollView+NSTextView for a chat composer.
struct MacTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let textField = AutoExpandingTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.drawsBackground = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.usesSingleLineMode = false // allow multi-line
        textField.lineBreakMode = .byWordWrapping
       textField.maximumNumberOfLines = 5
        textField.font = NSFont.systemFont(ofSize: 14)
        textField.textColor = NSColor.labelColor
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false
        textField.stringValue = text
        textField.placeholderString = "Type a message..."
        textField.focusRingType = .none
        
        // Set minimum height
        textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true

        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            let newText = textField.stringValue
            if text.wrappedValue != newText {
                text.wrappedValue = newText
            }
        }
    }
}

/// Custom NSTextField that auto-expands height with content.
class AutoExpandingTextField: NSTextField {
    override func layout() {
        super.layout()
        // Let intrinsic content size drive the height
        invalidateIntrinsicContentSize()
    }
    
    override var intrinsicContentSize: NSSize {
        // Use the cell's sizing
        let size = cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: frame.width, height: .greatestFiniteMagnitude)) ?? NSSize(width: -1, height: 32)
        return NSSize(width: -1, height: min(max(size.height, 32), 120))
    }
}