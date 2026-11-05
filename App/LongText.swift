import AppKit
import SwiftUI

/// Large text in an NSTextView, which lays out lazily, so multi-MB results stay responsive.
struct LongText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.textColor = .labelColor
            tv.drawsBackground = false
            tv.layoutManager?.allowsNonContiguousLayout = true
            tv.string = text
        }
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
