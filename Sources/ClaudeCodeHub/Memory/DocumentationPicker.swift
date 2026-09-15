import AppKit

/// Asks for documentation to ingest into core memory (URL, files or a folder).
enum DocumentationPicker {
    static func askForURL(workingDir: String) {
        let alert = NSAlert()
        alert.messageText = "Add Documentation URL"
        alert.informativeText = "Claude reads the documentation site and records API, design and workflow memories for this project."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://docs.example.com/guide"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return }
        MemoryJobs.shared.ingestDocs(source: url, workingDir: workingDir)
    }

    static func askForFiles(workingDir: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose documentation files or folders to add to core memory"
        panel.directoryURL = URL(fileURLWithPath: workingDir)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            MemoryJobs.shared.ingestDocs(source: url.path, workingDir: workingDir)
        }
    }
}
