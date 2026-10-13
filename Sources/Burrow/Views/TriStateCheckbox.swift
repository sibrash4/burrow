import SwiftUI
import AppKit

enum TriState { case off, on, mixed }

/// Native checkbox with a mixed state, which SwiftUI's Toggle can't show.
struct TriStateCheckbox: NSViewRepresentable {
    var value: TriState
    var label: String
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityLabel(label)
        switch value {
        case .off: button.state = .off
        case .on: button.state = .on
        case .mixed: button.state = .mixed
        }
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked() { action() }
    }
}
