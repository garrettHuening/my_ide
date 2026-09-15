import Foundation
import Combine
import CCHMemory

/// Detects whether a session's working directory is a git repo whose `origin` remote points at
/// GitHub. Results are cached per directory; lookups run off the main thread.
final class GitHubDetector: ObservableObject {
    static let shared = GitHubDetector()

    @Published private(set) var githubDirs: Set<String> = []
    private var checked: Set<String> = []
    private let git = GitRunner()
    private let queue = DispatchQueue(label: "cch.github-detect")

    func isGitHub(_ workingDir: String) -> Bool {
        if !checked.contains(workingDir) { detect(workingDir) }
        return githubDirs.contains(workingDir)
    }

    /// Re-checks a directory (e.g. after a remote is added).
    func refresh(_ workingDir: String) {
        queue.async {
            DispatchQueue.main.async { self.checked.remove(workingDir) }
            self.performDetect(workingDir)
        }
    }

    private func detect(_ workingDir: String) {
        checked.insert(workingDir)
        queue.async { self.performDetect(workingDir) }
    }

    private func performDetect(_ workingDir: String) {
        guard FileManager.default.fileExists(atPath: workingDir) else { return }
        let remotes = git.output(["remote", "-v"], in: workingDir) ?? ""
        let isGitHub = remotes.lowercased().contains("github.com")
        DispatchQueue.main.async {
            self.checked.insert(workingDir)
            if isGitHub {
                self.githubDirs.insert(workingDir)
            } else {
                self.githubDirs.remove(workingDir)
            }
        }
    }
}
