//
//  EditorWindowAccessor.swift
//  macSCP
//
//  Manages window titlebar styling, document dirty state, and close confirmation for FileEditor
//

import SwiftUI
import AppKit

struct EditorWindowAccessor: NSViewRepresentable {
    @Bindable var viewModel: FileEditorViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.setup(window: window, viewModel: viewModel)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(viewModel: viewModel)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        weak var window: NSWindow?
        weak var previousDelegate: NSWindowDelegate?
        var viewModel: FileEditorViewModel?
        var isForceClosing = false

        func setup(window: NSWindow, viewModel: FileEditorViewModel) {
            self.window = window
            self.viewModel = viewModel

            // Always enforce crisp titlebar separator line
            window.titlebarSeparatorStyle = .line

            // Synchronize native document dirty state
            window.isDocumentEdited = viewModel.hasChanges

            // Hook close confirmation if not already hooked
            if window.delegate !== self {
                self.previousDelegate = window.delegate
                window.delegate = self
            }
        }

        func update(viewModel: FileEditorViewModel) {
            self.viewModel = viewModel
            if let window = window {
                window.titlebarSeparatorStyle = .line
                window.isDocumentEdited = viewModel.hasChanges
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if isForceClosing {
                return true
            }

            guard let viewModel = viewModel, viewModel.hasChanges else {
                return true
            }

            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes made to the document “\(viewModel.fileName)”?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.alertStyle = .warning

            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")

            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[1].keyEquivalent = "\u{1b}" // Esc
            alert.buttons[2].keyEquivalent = "d"
            alert.buttons[2].keyEquivalentModifierMask = .command

            alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
                guard let self = self, let sender = sender else { return }

                switch response {
                case .alertFirstButtonReturn: // Save
                    Task { @MainActor in
                        await viewModel.save()
                        if viewModel.error == nil {
                            self.isForceClosing = true
                            sender.close()
                        }
                    }
                case .alertSecondButtonReturn: // Cancel
                    break
                case .alertThirdButtonReturn: // Don't Save
                    self.isForceClosing = true
                    sender.close()
                default:
                    break
                }
            }

            return false
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if aSelector == #selector(windowShouldClose(_:)) {
                return true
            }
            if super.responds(to: aSelector) {
                return true
            }
            return previousDelegate?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let prev = previousDelegate, prev.responds(to: aSelector) {
                return prev
            }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
