import Foundation
import AppKit

@MainActor
protocol PanelContext: AnyObject {
    var previousApp: NSRunningApplication? { get }
    func pasteAndActivate()
    func hidePanel()
}
