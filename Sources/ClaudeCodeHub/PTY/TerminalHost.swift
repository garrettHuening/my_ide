import SwiftUI
import AppKit
import SwiftTerm

/// SwiftUI host for a cached SwiftTerm view. The actual NSView is owned by
/// `TerminalRegistry` so it survives session-switch teardown.
struct TerminalHost: NSViewRepresentable {
    let session: Session

    func makeNSView(context: Context) -> NSView {
        let container = TerminalDropContainer()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        let sessionID = session.id
        container.onDrop = { urls in
            let payload = urls
                .map { shellQuote($0.path) }
                .joined(separator: " ")
            // Trailing space so the user can keep typing without joining the next char.
            TerminalRegistry.shared.sendInput(payload + " ", to: sessionID)
        }
        attach(session: session, into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let term = TerminalRegistry.shared.terminal(for: session)
        if container.subviews.first !== term {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(view: term, into: container)
        }
    }

    private func attach(session: Session, into container: NSView) {
        let term = TerminalRegistry.shared.terminal(for: session)
        attach(view: term, into: container)
    }

    private func attach(view: NSView, into container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        // Small top inset so SwiftTerm's first row doesn't clip against the topbar.
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6)
        ])
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }

    /// Minimal shell-quote: leave path alone if it contains only "safe" chars,
    /// otherwise wrap in single quotes (escaping any embedded single quotes).
    private func shellQuote(_ s: String) -> String {
        let safe: Set<Character> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-+@")
        if s.allSatisfy({ safe.contains($0) }) { return s }
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

/// Container that accepts file URL drops and forwards them to the PTY.
/// SwiftTerm's `TerminalView` (the subview) does not register for `.fileURL`,
/// so drops fall through to this container.
final class TerminalDropContainer: NSView {
    var onDrop: (([URL]) -> Void)?

    private let highlightLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        registerForDraggedTypes([.fileURL])
        // Drop-zone highlight (hidden until a drag enters).
        highlightLayer.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        highlightLayer.borderWidth = 0
        highlightLayer.cornerRadius = 6
        highlightLayer.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        highlightLayer.opacity = 0
        wantsLayer = true
        layer?.addSublayer(highlightLayer)
    }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds.insetBy(dx: 2, dy: 2)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if hasFileURLs(sender) {
            setHighlight(true)
            return .copy
        }
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHighlight(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHighlight(false)
        let pb = sender.draggingPasteboard
        guard let items = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !items.isEmpty else {
            return false
        }
        onDrop?(items)
        return true
    }

    private func hasFileURLs(_ info: NSDraggingInfo) -> Bool {
        let pb = info.draggingPasteboard
        return pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func setHighlight(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        highlightLayer.opacity = on ? 1 : 0
        highlightLayer.borderWidth = on ? 1.5 : 0
        CATransaction.commit()
    }
}
