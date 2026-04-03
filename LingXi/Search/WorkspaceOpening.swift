import AppKit

protocol WorkspaceOpening {
    @discardableResult
    func open(_ url: URL) -> Bool
}

extension NSWorkspace: WorkspaceOpening {}
