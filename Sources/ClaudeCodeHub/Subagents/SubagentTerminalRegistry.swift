import AppKit
import SwiftUI
import SwiftTerm

/// One SwiftTerm view per subagent, fed from cch-agentd. Kept alive so switching between the main
/// pane and subagents is instant; keystrokes and resizes go back to the subagent's host.
final class SubagentTerminalRegistry: NSObject, TerminalViewDelegate {
    static let shared = SubagentTerminalRegistry()

    private var views: [Int64: TerminalView] = [:]
    /// Subagents whose scrollback request is in flight; output arriving meanwhile is already in it.
    private var attaching: Set<Int64> = []

    func terminal(for agentID: Int64) -> TerminalView {
        if let view = views[agentID] { return view }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = NSColor.black
        view.nativeForegroundColor = NSColor(white: 0.96, alpha: 1.0)
        view.terminalDelegate = self
        views[agentID] = view
        attach(agentID, into: view)
        return view
    }

    /// Re-reads the scrollback, e.g. after reconnecting to the helper.
    func reload(_ agentID: Int64) {
        guard let view = views[agentID] else { return }
        view.getTerminal().resetToInitialState()
        attach(agentID, into: view)
    }

    func receive(_ agentID: Int64, _ data: Data) {
        guard let view = views[agentID], !attaching.contains(agentID) else { return }
        view.feed(byteArray: ArraySlice([UInt8](data)))
    }

    private func attach(_ agentID: Int64, into view: TerminalView) {
        attaching.insert(agentID)
        SubagentsClient.shared.call("app.attach", ["id": Int(agentID)]) { result in
            self.attaching.remove(agentID)
            guard case .success(let value) = result,
                  let base64 = (value as? [String: Any])?["data"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            view.feed(byteArray: ArraySlice([UInt8](data)))
        }
    }

    private func agentID(of source: TerminalView) -> Int64? {
        views.first { $0.value === source }?.key
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let id = agentID(of: source) else { return }
        SubagentsClient.shared.call("app.input", ["id": Int(id), "data": Data(data).base64EncodedString()])
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let id = agentID(of: source) else { return }
        SubagentsClient.shared.call("app.resize", ["id": Int(id), "cols": newCols, "rows": newRows])
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// SwiftUI host for a subagent's cached terminal view.
struct SubagentTerminalHost: NSViewRepresentable {
    let agentID: Int64

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        place(SubagentTerminalRegistry.shared.terminal(for: agentID), in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = SubagentTerminalRegistry.shared.terminal(for: agentID)
        if container.subviews.first !== view {
            container.subviews.forEach { $0.removeFromSuperview() }
            place(view, in: container)
        }
    }

    private func place(_ view: NSView, in container: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6)
        ])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}
