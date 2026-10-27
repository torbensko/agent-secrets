import AppKit
import SwiftUI
import Testing
@testable import Secrets

/// Saving clears the draft while a text field still has focus; the field then commits through its binding.
@MainActor
struct EditingBindingTests {
    @Observable final class Model {
        var editing: String? = "draft"
    }

    struct Editor: View {
        @Bindable var model: Model

        var body: some View {
            if let current = model.editing {
                TextField("Value", text: Binding(
                    get: { model.editing ?? current },
                    set: { if model.editing != nil { model.editing = $0 } }
                ))
            }
        }
    }

    @Test func endingFieldEditingAfterTheDraftIsClearedDoesNotCrash() throws {
        let model = Model()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Editor(model: model))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()

        let field = try #require(Self.textField(in: window.contentView))
        #expect(window.makeFirstResponder(field))
        window.fieldEditor(false, for: field)?.insertText("typed")

        // What Save does: clear the draft, then let layout run while the field still has focus.
        model.editing = nil
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.1))

        #expect(model.editing == nil)
        window.orderOut(nil)
    }

    private static func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }
}
