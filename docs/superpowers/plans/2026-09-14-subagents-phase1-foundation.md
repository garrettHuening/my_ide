# Subagents Phase 1 — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the project under git, replace the manual rebuild cycle with `scripts/bundle.sh`, and create the `CCHCore` library holding every pure rule the subagent system needs (state machine, naming, merge gate/order, recovery planner, hook policy, model resolution), fully unit-tested.

**Architecture:** `CCHCore` is a SwiftPM library target with no AppKit/SwiftUI/SwiftTerm dependency, so the app, `cch-agentd`, `cch-agent-host` and `cch-mcp` (later phases) can all link it. Every function here is pure: inputs in, decision out. Side effects (SQLite, git, processes, XPC) come in Phase 2+ and call these rules. `ClaudeLocator` moves from the app into `CCHCore` and gains a `CCH_CLAUDE_PATH` override for tests.

**Tech Stack:** Swift 6.3.3 toolchain, `swift-tools-version:5.9` (Swift 5 language mode), XCTest via `swift test`, CryptoKit, bash, `codesign`.

**Spec:** `docs/superpowers/specs/2026-09-14-subagents-design.md` (§2 states/recovery/status reporting, §3 naming, §5 merge gate/order)

## Global Constraints

- Platform floor: macOS 14 (`.macOS(.v14)`); package stays `swift-tools-version:5.9`.
- `CCHCore` imports only `Foundation` and `CryptoKit`.
- Tests use XCTest (`import XCTest`, `@testable import CCHCore`) and run with `swift test` from `ClaudeCodeHub/`.
- Stored raw values must match the spec's DB strings exactly: categories `task|bug|feature|helper`; states `starting|running|idle|needs_input|complete|merging|merged|interrupted|stopped|failed|discarded`; merge substates `awaiting_commit|awaiting_main`.
- Slash command names: `task`, `bugfix`, `feature`, `helper` (`bug` ships as `bugfix`).
- Branch: `cch/<category>/<id>-<slug>`; slug is lowercase ASCII alphanumerics with single `-` separators, max 32 chars, fallback `subagent`.
- Worktree path: `<worktreesRoot>/<repo basename>-<first 8 hex of SHA-1(repoRoot)>/<id>-<slug>`.
- Tunables: status reminder after 10 min (600 s); crash loop = 3 resumes within 30 min (1800 s).
- Model values: `nil`/blank = CLI default (no `--model` flag); accepted values are the aliases `fable`, `opus`, `sonnet`, `haiku` (optionally suffixed `[1m]`) or a full name starting `claude-` made of ASCII letters, digits, `-`, `.` (optionally suffixed `[1m]`). Pref keys: `model.<category rawValue>`.
- The app must be launched from the bundle (`build/ClaudeCodeHub.app`), never from `.build/debug/ClaudeCodeHub`. Bundle id `dev.cch.ClaudeCodeHub`.
- All paths below are relative to `/Users/robertoppenheimer/Documents/Claude/CCH/ClaudeCodeHub`.
- End every commit message with the attribution trailer your harness specifies, if any.

---

### Task 1: Initialize git

**Precondition:** the user approved `git init` for this directory. If not, skip every "Commit" step in this plan.

**Files:**
- Create: `.gitignore`

**Interfaces:**
- Produces: a `main` branch with the current app as the first commit.

- [ ] **Step 1: Create `.gitignore`**

```gitignore
.DS_Store
.build/
build/
.swiftpm/
spikes/claude-plugin/work/
*.raw
```

- [ ] **Step 2: Initialize and verify nothing generated is staged**

Run:
```bash
git init -b main
git add .
git status --short | grep -E "\.build/|(^|/)build/|\.DS_Store" || echo "clean: no generated files staged"
```
Expected: `clean: no generated files staged`.

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: initialize repository"
```

---

### Task 2: Bundle script

**Files:**
- Create: `Support/Info.plist`
- Create: `scripts/bundle.sh`

**Interfaces:**
- Produces: `scripts/bundle.sh [--run]` — builds, assembles `build/ClaudeCodeHub.app`, ad-hoc signs, clears quarantine, optionally relaunches. Later phases extend it with helper binaries, the LaunchAgent plist and plugins.

- [ ] **Step 1: Move the Info.plist into source control**

`Support/Info.plist` (identical to the one currently in `build/ClaudeCodeHub.app/Contents/Info.plist`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClaudeCodeHub</string>
  <key>CFBundleIdentifier</key><string>dev.cch.ClaudeCodeHub</string>
  <key>CFBundleName</key><string>Claude Code Hub</string>
  <key>CFBundleDisplayName</key><string>Claude Code Hub</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
```

- [ ] **Step 2: Write the script**

`scripts/bundle.sh`:

```bash
#!/bin/bash
# Build Claude Code Hub and assemble a signed .app bundle in build/.
# Usage: scripts/bundle.sh [--run]     CONFIG=release scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-debug}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG"
APP="build/ClaudeCodeHub.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/ClaudeCodeHub" "$APP/Contents/MacOS/ClaudeCodeHub"

codesign --force --sign - "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "Built $APP ($CONFIG)"

if [[ "${1:-}" == "--run" ]]; then
  pkill -f "ClaudeCodeHub.app/Contents/MacOS/ClaudeCodeHub" || true
  sleep 1
  open "$APP"
fi
```

- [ ] **Step 3: Run it and verify the bundle**

Run:
```bash
chmod +x scripts/bundle.sh
scripts/bundle.sh --run
sleep 3
codesign --verify --strict build/ClaudeCodeHub.app && echo "signature ok"
pgrep -fl "ClaudeCodeHub.app/Contents/MacOS/ClaudeCodeHub"
```
Expected: `Built build/ClaudeCodeHub.app (debug)`, `signature ok`, and a pgrep line whose path is inside `ClaudeCodeHub/build/` (not `AppTranslocation`). The app window shows the sessions sidebar.

- [ ] **Step 4: Commit**

```bash
git add Support/Info.plist scripts/bundle.sh
git commit -m "build: add bundle script and tracked Info.plist"
```

---

### Task 3: `CCHCore` target, test target, `ClaudeLocator` move

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CCHCore/ClaudeLocator.swift`
- Delete: `Sources/ClaudeCodeHub/PTY/ClaudeLocator.swift`
- Modify: `Sources/ClaudeCodeHub/PTY/TerminalRegistry.swift:1-4` (add `import CCHCore`)
- Test: `Tests/CCHCoreTests/ClaudeLocatorTests.swift`

**Interfaces:**
- Produces:
  - `public enum ClaudeLocator`
  - `static let overrideVariable = "CCH_CLAUDE_PATH"`
  - `static func findExecutable(environment: [String: String] = ProcessInfo.processInfo.environment, candidates: [String]? = nil) -> String?`
  - `static func env(base: [String: String] = ProcessInfo.processInfo.environment, extraPath: String? = nil) -> [String]`

- [ ] **Step 1: Add the targets**

Replace `Package.swift` with:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeCodeHub",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "CForkpty",
            path: "Sources/CForkpty",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CCHCore",
            path: "Sources/CCHCore"
        ),
        .executableTarget(
            name: "ClaudeCodeHub",
            dependencies: [
                "CForkpty",
                "CCHCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/ClaudeCodeHub",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CCHCoreTests",
            dependencies: ["CCHCore"],
            path: "Tests/CCHCoreTests"
        )
    ]
)
```

- [ ] **Step 2: Write the failing tests**

`Tests/CCHCoreTests/ClaudeLocatorTests.swift`:

```swift
import XCTest
@testable import CCHCore

final class ClaudeLocatorTests: XCTestCase {
    func testOverrideFromEnvironmentWins() {
        let found = ClaudeLocator.findExecutable(environment: ["CCH_CLAUDE_PATH": "/bin/echo"], candidates: [])
        XCTAssertEqual(found, "/bin/echo")
    }

    func testFallsBackToPATH() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let claude = dir.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        let found = ClaudeLocator.findExecutable(environment: ["PATH": "/nonexistent:\(dir.path)"], candidates: [])
        XCTAssertEqual(found, claude.path)
    }

    func testReturnsNilWhenNothingFound() {
        let found = ClaudeLocator.findExecutable(
            environment: ["CCH_CLAUDE_PATH": "/nonexistent/claude", "PATH": "/nonexistent"],
            candidates: []
        )
        XCTAssertNil(found)
    }

    func testEnvSetsTermAndKeepsExistingLang() {
        let env = ClaudeLocator.env(base: ["LANG": "fr_FR.UTF-8", "PATH": "/usr/bin"])
        XCTAssertTrue(env.contains("TERM=xterm-256color"))
        XCTAssertTrue(env.contains("LANG=fr_FR.UTF-8"))
        XCTAssertTrue(env.contains("PATH=/usr/bin"))
    }

    func testEnvDefaultsLangAndPrependsExtraPath() {
        let env = ClaudeLocator.env(base: ["PATH": "/usr/bin"], extraPath: "/opt/x")
        XCTAssertTrue(env.contains("LANG=en_US.UTF-8"))
        XCTAssertTrue(env.contains("PATH=/opt/x:/usr/bin"))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter CCHCoreTests.ClaudeLocatorTests`
Expected: FAIL — build error (`CCHCore` has no sources / `ClaudeLocator` not found).

- [ ] **Step 4: Move and extend `ClaudeLocator`**

Create `Sources/CCHCore/ClaudeLocator.swift`:

```swift
import Foundation

/// Find the `claude` CLI on disk. The user's shell alias isn't visible to a non-login
/// process, so we probe well-known locations before falling back to PATH.
public enum ClaudeLocator {
    /// Tests and fake-claude integration runs point this at a stand-in executable.
    public static let overrideVariable = "CCH_CLAUDE_PATH"

    public static func findExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidates: [String]? = nil
    ) -> String? {
        let fm = FileManager.default
        if let override = environment[overrideVariable], fm.isExecutableFile(atPath: override) {
            return override
        }
        let home = NSHomeDirectory()
        let probes = candidates ?? [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        for path in probes where fm.isExecutableFile(atPath: path) {
            return path
        }
        // PATH fallback (from our own env, which inherits the launching user's PATH).
        if let pathEnv = environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/claude"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// Build the environment array passed to claude's PTY child.
    /// We start from our own env (which contains PATH, HOME, etc.) and overlay TERM/LANG.
    public static func env(
        base: [String: String] = ProcessInfo.processInfo.environment,
        extraPath: String? = nil
    ) -> [String] {
        var env = base
        env["TERM"] = "xterm-256color"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if let extraPath {
            let current = env["PATH"] ?? ""
            env["PATH"] = "\(extraPath):\(current)"
        }
        return env.map { "\($0.key)=\($0.value)" }
    }
}
```

Run: `rm Sources/ClaudeCodeHub/PTY/ClaudeLocator.swift`

In `Sources/ClaudeCodeHub/PTY/TerminalRegistry.swift`, change the imports at the top of the file to:

```swift
import Foundation
import AppKit
import SwiftTerm
import Combine
import CCHCore
```

- [ ] **Step 5: Run tests and the app build**

Run: `swift test --filter CCHCoreTests.ClaudeLocatorTests && swift build`
Expected: `Executed 5 tests, with 0 failures`; build succeeds with no errors.

- [ ] **Step 6: Commit**

```bash
git add -A Package.swift Sources Tests
git commit -m "refactor: add CCHCore library and move ClaudeLocator into it"
```

---

### Task 4: Subagent models and state machine

**Files:**
- Create: `Sources/CCHCore/Models/SubagentCategory.swift`
- Create: `Sources/CCHCore/Models/SubagentState.swift`
- Create: `Sources/CCHCore/Models/Subagent.swift`
- Create: `Sources/CCHCore/Rules/SubagentStateMachine.swift`
- Create: `Tests/CCHCoreTests/Fixtures.swift`
- Test: `Tests/CCHCoreTests/ModelTests.swift`
- Test: `Tests/CCHCoreTests/SubagentStateMachineTests.swift`

**Interfaces:**
- Produces:
  - `public enum SubagentCategory: String, CaseIterable, Codable, Sendable { case task, bug, feature, helper }` with `commandName: String`, `displayName: String`, `init?(commandName:)`
  - `public enum SubagentState: String, CaseIterable, Codable, Sendable` (11 cases; `needsInput` raw `needs_input`)
  - `public enum MergeSubstate: String, Codable, Sendable { case awaitingCommit = "awaiting_commit", awaitingMain = "awaiting_main" }`
  - `public struct SubagentPhase: Hashable, Sendable` — `init(_ state: SubagentState, _ substate: MergeSubstate? = nil)`, `state`, `substate`
  - `public struct Subagent: Equatable, Identifiable, Sendable` — all spec §2 `subagents` columns as properties, plus `phase: SubagentPhase { get set }`
  - `public enum SubagentEvent: Equatable, Sendable` — `promptSubmitted, toolUsed, permissionPrompt, turnStopped, markedComplete, mergeRequested(needsCommit: Bool), commitLanded, mergeCancelled(wasComplete: Bool), mergeVerified, mergedWithNewerCommits, archivedNothingToMerge, hostDied, relaunched, userStopped, userDiscarded, spawnFailed, crashLoop`
  - `public struct IllegalTransition: Error, Equatable { let from: SubagentPhase; let event: SubagentEvent }`
  - `public enum SubagentStateMachine { static func apply(_ event: SubagentEvent, to phase: SubagentPhase) throws -> SubagentPhase }`
  - Test helper (test target only): `func makeSubagent(id: Int64 = 1, category: SubagentCategory = .task, state: SubagentState = .idle, substate: MergeSubstate? = nil, groupID: Int64? = nil, index: Int? = nil) -> Subagent` and `let epoch: Date`

- [ ] **Step 1: Write the test fixture**

`Tests/CCHCoreTests/Fixtures.swift`:

```swift
import Foundation
@testable import CCHCore

/// Fixed reference time so tests never depend on the wall clock.
let epoch = Date(timeIntervalSince1970: 1_800_000_000)

func makeSubagent(
    id: Int64 = 1,
    category: SubagentCategory = .task,
    state: SubagentState = .idle,
    substate: MergeSubstate? = nil,
    groupID: Int64? = nil,
    index: Int? = nil
) -> Subagent {
    Subagent(
        id: id,
        sessionID: 1,
        category: category,
        title: "Subagent \(id)",
        state: state,
        mergeSubstate: substate,
        mergeGroupID: groupID,
        mergeIndex: index,
        createdAt: epoch,
        updatedAt: epoch
    )
}
```

- [ ] **Step 2: Write the failing model tests**

`Tests/CCHCoreTests/ModelTests.swift`:

```swift
import XCTest
@testable import CCHCore

final class ModelTests: XCTestCase {
    func testCommandNamesShipBugAsBugfix() {
        XCTAssertEqual(SubagentCategory.allCases.map(\.commandName), ["task", "bugfix", "feature", "helper"])
    }

    func testInitFromCommandName() {
        XCTAssertEqual(SubagentCategory(commandName: "bugfix"), .bug)
        XCTAssertEqual(SubagentCategory(commandName: "helper"), .helper)
        XCTAssertNil(SubagentCategory(commandName: "bug"))
    }

    func testDisplayNames() {
        XCTAssertEqual(SubagentCategory.allCases.map(\.displayName), ["Task", "Bug", "Feature", "Helper"])
    }

    func testRawValuesMatchSpecColumns() {
        XCTAssertEqual(SubagentCategory.allCases.map(\.rawValue), ["task", "bug", "feature", "helper"])
        XCTAssertEqual(SubagentState.needsInput.rawValue, "needs_input")
        XCTAssertEqual(SubagentState.allCases.count, 11)
        XCTAssertEqual(MergeSubstate.awaitingCommit.rawValue, "awaiting_commit")
        XCTAssertEqual(MergeSubstate.awaitingMain.rawValue, "awaiting_main")
    }

    func testPhaseReadsAndWritesStateAndSubstate() {
        var s = makeSubagent(state: .idle)
        XCTAssertEqual(s.phase, SubagentPhase(.idle))
        s.phase = SubagentPhase(.merging, .awaitingMain)
        XCTAssertEqual(s.state, .merging)
        XCTAssertEqual(s.mergeSubstate, .awaitingMain)
    }
}
```

- [ ] **Step 3: Write the failing state machine tests**

`Tests/CCHCoreTests/SubagentStateMachineTests.swift`:

```swift
import XCTest
@testable import CCHCore

final class SubagentStateMachineTests: XCTestCase {
    private func p(_ state: SubagentState, _ substate: MergeSubstate? = nil) -> SubagentPhase {
        SubagentPhase(state, substate)
    }

    private func expect(_ from: SubagentPhase, _ event: SubagentEvent, _ to: SubagentPhase,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try SubagentStateMachine.apply(event, to: from), to, file: file, line: line)
    }

    private func expectIllegal(_ from: SubagentPhase, _ event: SubagentEvent,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SubagentStateMachine.apply(event, to: from), file: file, line: line) { error in
            XCTAssertEqual(error as? IllegalTransition, IllegalTransition(from: from, event: event),
                           file: file, line: line)
        }
    }

    func testHooksDriveRunningIdleAndNeedsInput() {
        expect(p(.starting), .promptSubmitted, p(.running))
        expect(p(.running), .permissionPrompt, p(.needsInput))
        expect(p(.needsInput), .toolUsed, p(.running))
        expect(p(.running), .turnStopped, p(.idle))
        expect(p(.idle), .promptSubmitted, p(.running))
        expect(p(.interrupted), .promptSubmitted, p(.running))
        expect(p(.starting), .turnStopped, p(.idle))
    }

    func testCompleteSurvivesTrailingHooksButReopensOnNewPrompt() {
        expect(p(.complete), .toolUsed, p(.complete))
        expect(p(.complete), .turnStopped, p(.complete))
        expect(p(.complete), .promptSubmitted, p(.running))
    }

    func testHooksAreIgnoredWhileMergingAndAfterArchive() {
        let hookEvents: [SubagentEvent] = [.promptSubmitted, .toolUsed, .permissionPrompt, .turnStopped]
        for state in [SubagentState.merged, .stopped, .failed, .discarded] {
            for event in hookEvents {
                expect(p(state), event, p(state))
            }
        }
        for event in hookEvents {
            expect(p(.merging, .awaitingCommit), event, p(.merging, .awaitingCommit))
            expect(p(.merging, .awaitingMain), event, p(.merging, .awaitingMain))
        }
    }

    func testMarkComplete() {
        expect(p(.running), .markedComplete, p(.complete))
        expect(p(.idle), .markedComplete, p(.complete))
        expect(p(.complete), .markedComplete, p(.complete))
        expect(p(.merging, .awaitingCommit), .markedComplete, p(.merging, .awaitingCommit))
        expectIllegal(p(.merging, .awaitingMain), .markedComplete)
        expectIllegal(p(.merged), .markedComplete)
        expectIllegal(p(.stopped), .markedComplete)
    }

    func testMergeRequest() {
        expect(p(.idle), .mergeRequested(needsCommit: true), p(.merging, .awaitingCommit))
        expect(p(.complete), .mergeRequested(needsCommit: false), p(.merging, .awaitingMain))
        expect(p(.merging, .awaitingMain), .mergeRequested(needsCommit: false), p(.merging, .awaitingMain))
        expectIllegal(p(.running), .mergeRequested(needsCommit: false))
        expectIllegal(p(.merging, .awaitingCommit), .mergeRequested(needsCommit: true))
        expectIllegal(p(.merged), .mergeRequested(needsCommit: false))
    }

    func testCommitLandedAndCancel() {
        expect(p(.merging, .awaitingCommit), .commitLanded, p(.merging, .awaitingMain))
        expectIllegal(p(.merging, .awaitingMain), .commitLanded)
        expect(p(.merging, .awaitingCommit), .mergeCancelled(wasComplete: false), p(.idle))
        expect(p(.merging, .awaitingMain), .mergeCancelled(wasComplete: true), p(.complete))
        expectIllegal(p(.idle), .mergeCancelled(wasComplete: false))
    }

    func testMergeVerification() {
        expect(p(.merging, .awaitingMain), .mergeVerified, p(.merged))
        expect(p(.merging, .awaitingMain), .mergedWithNewerCommits, p(.idle))
        expectIllegal(p(.merging, .awaitingCommit), .mergeVerified)
        expectIllegal(p(.merging, .awaitingCommit), .mergedWithNewerCommits)
        expect(p(.idle), .archivedNothingToMerge, p(.merged))
        expect(p(.complete), .archivedNothingToMerge, p(.merged))
        expectIllegal(p(.running), .archivedNothingToMerge)
    }

    func testHostDeath() {
        expect(p(.starting), .hostDied, p(.interrupted))
        expect(p(.running), .hostDied, p(.interrupted))
        expect(p(.needsInput), .hostDied, p(.interrupted))
        expect(p(.idle), .hostDied, p(.idle))
        expect(p(.complete), .hostDied, p(.complete))
        expect(p(.merging, .awaitingCommit), .hostDied, p(.merging, .awaitingCommit))
        expect(p(.interrupted), .hostDied, p(.interrupted))
    }

    func testRelaunch() {
        expect(p(.interrupted), .relaunched, p(.running))
        expect(p(.stopped), .relaunched, p(.idle))
        expect(p(.idle), .relaunched, p(.idle))
        expect(p(.complete), .relaunched, p(.complete))
        expect(p(.merging, .awaitingCommit), .relaunched, p(.merging, .awaitingCommit))
        expectIllegal(p(.merged), .relaunched)
        expectIllegal(p(.discarded), .relaunched)
        expectIllegal(p(.failed), .relaunched)
    }

    func testUserStopAndDiscard() {
        for state in [SubagentState.starting, .running, .idle, .needsInput, .complete, .interrupted] {
            expect(p(state), .userStopped, p(.stopped))
        }
        expect(p(.stopped), .userStopped, p(.stopped))
        expectIllegal(p(.merging, .awaitingMain), .userStopped)
        expectIllegal(p(.merged), .userStopped)

        expect(p(.failed), .userDiscarded, p(.discarded))
        expect(p(.merging, .awaitingCommit), .userDiscarded, p(.discarded))
        expectIllegal(p(.merged), .userDiscarded)
        expectIllegal(p(.discarded), .userDiscarded)
    }

    func testFailures() {
        expect(p(.starting), .spawnFailed, p(.failed))
        expectIllegal(p(.running), .spawnFailed)
        expect(p(.interrupted), .crashLoop, p(.failed))
        expectIllegal(p(.idle), .crashLoop)
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter "CCHCoreTests.(ModelTests|SubagentStateMachineTests)"`
Expected: FAIL — build errors (`SubagentCategory`, `Subagent`, `SubagentStateMachine` not found).

- [ ] **Step 5: Implement the models**

`Sources/CCHCore/Models/SubagentCategory.swift`:

```swift
import Foundation

/// The four kinds of subagent. Raw values are stored in agents.db.
public enum SubagentCategory: String, CaseIterable, Codable, Sendable {
    case task
    case bug
    case feature
    case helper

    /// Slash command that spawns this category, without the leading slash.
    /// `bug` ships as `bugfix` because Claude Code has a built-in `/bug`.
    public var commandName: String {
        switch self {
        case .task: return "task"
        case .bug: return "bugfix"
        case .feature: return "feature"
        case .helper: return "helper"
        }
    }

    /// Section header and filter chip label.
    public var displayName: String {
        switch self {
        case .task: return "Task"
        case .bug: return "Bug"
        case .feature: return "Feature"
        case .helper: return "Helper"
        }
    }

    public init?(commandName: String) {
        guard let match = Self.allCases.first(where: { $0.commandName == commandName }) else { return nil }
        self = match
    }
}
```

`Sources/CCHCore/Models/SubagentState.swift`:

```swift
import Foundation

/// Lifecycle state of a subagent (spec §2). Raw values are stored in agents.db.
public enum SubagentState: String, CaseIterable, Codable, Sendable {
    case starting
    case running
    case idle
    case needsInput = "needs_input"
    case complete
    case merging
    case merged
    case interrupted
    case stopped
    case failed
    case discarded
}

/// Which step of the merge flow a `.merging` subagent is in.
public enum MergeSubstate: String, Codable, Sendable {
    case awaitingCommit = "awaiting_commit"
    case awaitingMain = "awaiting_main"
}

/// A state plus its merge substate, the unit the state machine works on.
public struct SubagentPhase: Hashable, Sendable, CustomStringConvertible {
    public var state: SubagentState
    public var substate: MergeSubstate?

    public init(_ state: SubagentState, _ substate: MergeSubstate? = nil) {
        self.state = state
        self.substate = substate
    }

    public var description: String {
        substate.map { "\(state.rawValue)/\($0.rawValue)" } ?? state.rawValue
    }
}
```

`Sources/CCHCore/Models/Subagent.swift`:

```swift
import Foundation

/// One row of agents.db `subagents` (spec §2).
public struct Subagent: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var sessionID: Int64
    public var sessionDir: String
    public var repoRoot: String
    public var category: SubagentCategory
    public var title: String
    public var brief: String
    public var model: String?
    public var state: SubagentState
    public var mergeSubstate: MergeSubstate?
    public var claudeSessionID: String
    public var worktreePath: String
    public var branch: String
    public var baseCommit: String
    public var baseBranch: String?
    public var mergeTip: String?
    public var mergeGroupID: Int64?
    public var mergeIndex: Int?
    public var hostPID: Int32?
    public var hostStartedAt: Date?
    public var resumeCount: Int
    public var lastResumeAt: Date?
    public var turnsStarted: Int
    public var lastReportTurn: Int
    public var lastReportAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var mergedAt: Date?
    public var failureReason: String?

    public init(
        id: Int64,
        sessionID: Int64,
        sessionDir: String = "",
        repoRoot: String = "",
        category: SubagentCategory,
        title: String,
        brief: String = "",
        model: String? = nil,
        state: SubagentState = .starting,
        mergeSubstate: MergeSubstate? = nil,
        claudeSessionID: String = "",
        worktreePath: String = "",
        branch: String = "",
        baseCommit: String = "",
        baseBranch: String? = nil,
        mergeTip: String? = nil,
        mergeGroupID: Int64? = nil,
        mergeIndex: Int? = nil,
        hostPID: Int32? = nil,
        hostStartedAt: Date? = nil,
        resumeCount: Int = 0,
        lastResumeAt: Date? = nil,
        turnsStarted: Int = 0,
        lastReportTurn: Int = -1,
        lastReportAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        mergedAt: Date? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sessionDir = sessionDir
        self.repoRoot = repoRoot
        self.category = category
        self.title = title
        self.brief = brief
        self.model = model
        self.state = state
        self.mergeSubstate = mergeSubstate
        self.claudeSessionID = claudeSessionID
        self.worktreePath = worktreePath
        self.branch = branch
        self.baseCommit = baseCommit
        self.baseBranch = baseBranch
        self.mergeTip = mergeTip
        self.mergeGroupID = mergeGroupID
        self.mergeIndex = mergeIndex
        self.hostPID = hostPID
        self.hostStartedAt = hostStartedAt
        self.resumeCount = resumeCount
        self.lastResumeAt = lastResumeAt
        self.turnsStarted = turnsStarted
        self.lastReportTurn = lastReportTurn
        self.lastReportAt = lastReportAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.mergedAt = mergedAt
        self.failureReason = failureReason
    }

    public var phase: SubagentPhase {
        get { SubagentPhase(state, mergeSubstate) }
        set {
            state = newValue.state
            mergeSubstate = newValue.substate
        }
    }
}
```

- [ ] **Step 6: Implement the state machine**

`Sources/CCHCore/Rules/SubagentStateMachine.swift`:

```swift
import Foundation

/// Everything that can move a subagent between states (spec §2 state table).
public enum SubagentEvent: Equatable, Sendable {
    case promptSubmitted            // UserPromptSubmit hook
    case toolUsed                   // PostToolUse hook
    case permissionPrompt           // Notification hook, permission_prompt
    case turnStopped                // Stop hook
    case markedComplete             // mark_complete tool
    case mergeRequested(needsCommit: Bool)
    case commitLanded               // clean tree + mark_complete while awaiting_commit
    case mergeCancelled(wasComplete: Bool) // commit timeout or merge_failed
    case mergeVerified              // mark_merged verified, branch tip unchanged
    case mergedWithNewerCommits     // mark_merged verified, but the branch moved on
    case archivedNothingToMerge     // Done button: no commits, clean tree
    case hostDied
    case relaunched                 // Resume / Reopen / recovery relaunch
    case userStopped
    case userDiscarded
    case spawnFailed
    case crashLoop
}

public struct IllegalTransition: Error, Equatable {
    public let from: SubagentPhase
    public let event: SubagentEvent
}

public enum SubagentStateMachine {
    /// States whose hook events are late arrivals from a process we no longer track.
    private static let archived: Set<SubagentState> = [.merged, .stopped, .failed, .discarded]

    public static func apply(_ event: SubagentEvent, to phase: SubagentPhase) throws -> SubagentPhase {
        let state = phase.state
        let illegal = IllegalTransition(from: phase, event: event)

        switch event {
        case .promptSubmitted:
            if archived.contains(state) || state == .merging { return phase }
            return SubagentPhase(.running)

        case .toolUsed:
            // mark_complete itself triggers PostToolUse; it must not undo `complete`.
            if archived.contains(state) || state == .merging || state == .complete { return phase }
            return SubagentPhase(.running)

        case .permissionPrompt:
            if archived.contains(state) || state == .merging { return phase }
            return SubagentPhase(.needsInput)

        case .turnStopped:
            if archived.contains(state) || state == .merging || state == .complete { return phase }
            return SubagentPhase(.idle)

        case .markedComplete:
            switch state {
            case .starting, .running, .idle, .needsInput, .complete:
                return SubagentPhase(.complete)
            case .merging where phase.substate == .awaitingCommit:
                return phase
            default:
                throw illegal
            }

        case .mergeRequested(let needsCommit):
            switch state {
            case .idle, .complete:
                return SubagentPhase(.merging, needsCommit ? .awaitingCommit : .awaitingMain)
            case .merging where phase.substate == .awaitingMain:
                return phase
            default:
                throw illegal
            }

        case .commitLanded:
            guard state == .merging, phase.substate == .awaitingCommit else { throw illegal }
            return SubagentPhase(.merging, .awaitingMain)

        case .mergeCancelled(let wasComplete):
            guard state == .merging else { throw illegal }
            return SubagentPhase(wasComplete ? .complete : .idle)

        case .mergeVerified:
            guard state == .merging, phase.substate == .awaitingMain else { throw illegal }
            return SubagentPhase(.merged)

        case .mergedWithNewerCommits:
            guard state == .merging, phase.substate == .awaitingMain else { throw illegal }
            return SubagentPhase(.idle)

        case .archivedNothingToMerge:
            guard state == .idle || state == .complete else { throw illegal }
            return SubagentPhase(.merged)

        case .hostDied:
            switch state {
            case .starting, .running, .needsInput:
                return SubagentPhase(.interrupted)
            default:
                return phase
            }

        case .relaunched:
            switch state {
            case .interrupted: return SubagentPhase(.running)
            case .stopped: return SubagentPhase(.idle)
            case .idle, .complete, .merging: return phase
            default: throw illegal
            }

        case .userStopped:
            switch state {
            case .starting, .running, .idle, .needsInput, .complete, .interrupted:
                return SubagentPhase(.stopped)
            case .stopped:
                return phase
            default:
                throw illegal
            }

        case .userDiscarded:
            switch state {
            case .merged, .discarded: throw illegal
            default: return SubagentPhase(.discarded)
            }

        case .spawnFailed:
            guard state == .starting else { throw illegal }
            return SubagentPhase(.failed)

        case .crashLoop:
            guard state == .interrupted else { throw illegal }
            return SubagentPhase(.failed)
        }
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter "CCHCoreTests.(ModelTests|SubagentStateMachineTests)"`
Expected: `Executed 16 tests, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add Sources/CCHCore/Models Sources/CCHCore/Rules/SubagentStateMachine.swift Tests/CCHCoreTests/Fixtures.swift Tests/CCHCoreTests/ModelTests.swift Tests/CCHCoreTests/SubagentStateMachineTests.swift
git commit -m "feat(core): subagent models and lifecycle state machine"
```

---

### Task 5: Branch, slug and worktree naming

**Files:**
- Create: `Sources/CCHCore/Rules/SubagentNaming.swift`
- Test: `Tests/CCHCoreTests/SubagentNamingTests.swift`

**Interfaces:**
- Consumes: `SubagentCategory` (Task 4).
- Produces:
  - `public enum SubagentNaming`
  - `static func slug(_ title: String, maxLength: Int = 32) -> String`
  - `static func branch(category: SubagentCategory, id: Int64, title: String) -> String`
  - `static func worktreePath(worktreesRoot: String, repoRoot: String, id: Int64, title: String) -> String`
  - `static func workingDirectory(worktreePath: String, sessionDir: String, repoRoot: String) -> String`

- [ ] **Step 1: Write the failing tests**

`Tests/CCHCoreTests/SubagentNamingTests.swift`:

```swift
import XCTest
@testable import CCHCore

final class SubagentNamingTests: XCTestCase {
    func testSlugBasics() {
        XCTAssertEqual(SubagentNaming.slug("Add dark mode toggle!"), "add-dark-mode-toggle")
        XCTAssertEqual(SubagentNaming.slug("  Fix: crash on EMPTY folder  "), "fix-crash-on-empty-folder")
        XCTAssertEqual(SubagentNaming.slug("Zelda's Room"), "zelda-s-room")
    }

    func testSlugFallsBackWhenNoASCIIAlphanumerics() {
        XCTAssertEqual(SubagentNaming.slug("日本語"), "subagent")
        XCTAssertEqual(SubagentNaming.slug("!!!"), "subagent")
    }

    func testSlugTruncatesTo32WithoutTrailingDash() {
        XCTAssertEqual(
            SubagentNaming.slug("implement the entire settings screen redesign with tokens"),
            "implement-the-entire-settings-sc"
        )
        let cutAtDash = SubagentNaming.slug(String(repeating: "a", count: 31) + " b")
        XCTAssertEqual(cutAtDash, String(repeating: "a", count: 31))
    }

    func testBranch() {
        XCTAssertEqual(
            SubagentNaming.branch(category: .bug, id: 7, title: "Crash on empty folder"),
            "cch/bug/7-crash-on-empty-folder"
        )
    }

    func testWorktreePathIsNamespacedByRepoHash() {
        let path = SubagentNaming.worktreePath(
            worktreesRoot: "/wt", repoRoot: "/Users/x/Code/milegacy", id: 7, title: "Dark mode"
        )
        // SHA-1("/Users/x/Code/milegacy") starts with 59d39a64
        XCTAssertEqual(path, "/wt/milegacy-59d39a64/7-dark-mode")

        let sameNameElsewhere = SubagentNaming.worktreePath(
            worktreesRoot: "/wt", repoRoot: "/Users/x/Other/milegacy", id: 7, title: "Dark mode"
        )
        XCTAssertNotEqual(path, sameNameElsewhere)
    }

    func testWorkingDirectoryKeepsSessionSubfolder() {
        XCTAssertEqual(
            SubagentNaming.workingDirectory(worktreePath: "/wt/r/7-x", sessionDir: "/repo", repoRoot: "/repo"),
            "/wt/r/7-x"
        )
        XCTAssertEqual(
            SubagentNaming.workingDirectory(worktreePath: "/wt/r/7-x", sessionDir: "/repo/app/ios", repoRoot: "/repo"),
            "/wt/r/7-x/app/ios"
        )
    }

    func testWorkingDirectoryIgnoresLookalikePrefixAndOutsideDirs() {
        XCTAssertEqual(
            SubagentNaming.workingDirectory(worktreePath: "/wt/r/7-x", sessionDir: "/repo2/app", repoRoot: "/repo"),
            "/wt/r/7-x"
        )
        XCTAssertEqual(
            SubagentNaming.workingDirectory(worktreePath: "/wt/r/7-x", sessionDir: "/elsewhere", repoRoot: "/repo"),
            "/wt/r/7-x"
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CCHCoreTests.SubagentNamingTests`
Expected: FAIL — `cannot find 'SubagentNaming' in scope`.

- [ ] **Step 3: Implement**

`Sources/CCHCore/Rules/SubagentNaming.swift`:

```swift
import CryptoKit
import Foundation

/// Branch, worktree and working-directory names for a subagent (spec §3 spawn steps 4–7).
public enum SubagentNaming {
    /// Lowercase ASCII alphanumerics joined by single dashes, at most `maxLength` characters.
    public static func slug(_ title: String, maxLength: Int = 32) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in title.lowercased().unicodeScalars {
            if scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > maxLength {
            out = String(out.prefix(maxLength))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? "subagent" : out
    }

    public static func branch(category: SubagentCategory, id: Int64, title: String) -> String {
        "cch/\(category.rawValue)/\(id)-\(slug(title))"
    }

    /// `<worktreesRoot>/<repo basename>-<sha1(repoRoot) prefix>/<id>-<slug>`. The hash keeps two
    /// repos with the same folder name apart.
    public static func worktreePath(worktreesRoot: String, repoRoot: String, id: Int64, title: String) -> String {
        let repoName = (repoRoot as NSString).lastPathComponent
        let digest = Insecure.SHA1.hash(data: Data(repoRoot.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(worktreesRoot)/\(repoName)-\(hash)/\(id)-\(slug(title))"
    }

    /// If the session was opened in a subfolder of the repo, the subagent starts in the same
    /// subfolder of its worktree.
    public static func workingDirectory(worktreePath: String, sessionDir: String, repoRoot: String) -> String {
        let root = repoRoot.hasSuffix("/") ? String(repoRoot.dropLast()) : repoRoot
        guard sessionDir.hasPrefix(root + "/") else { return worktreePath }
        let relative = sessionDir.dropFirst(root.count + 1)
        return relative.isEmpty ? worktreePath : "\(worktreePath)/\(relative)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CCHCoreTests.SubagentNamingTests`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CCHCore/Rules/SubagentNaming.swift Tests/CCHCoreTests/SubagentNamingTests.swift
git commit -m "feat(core): subagent branch, slug and worktree naming"
```

---

### Task 6: Merge gate and merge order

**Files:**
- Create: `Sources/CCHCore/Rules/MergeGate.swift`
- Create: `Sources/CCHCore/Rules/MergeOrder.swift`
- Test: `Tests/CCHCoreTests/MergeGateTests.swift`
- Test: `Tests/CCHCoreTests/MergeOrderTests.swift`

**Interfaces:**
- Consumes: `Subagent`, `SubagentState`, `MergeSubstate`; test helper `makeSubagent` (Task 4).
- Produces:
  - `public enum MergeAction: Equatable, Sendable { case merge, archiveNothingToMerge, resend }`
  - `public enum MergeBlock: Error, Equatable, Sendable { case busy, waitsOn(index: Int), notMergeable }`
  - `public enum MergeGate { static func evaluate(_ subagent: Subagent, groupMembers: [Subagent], hasCommits: Bool, isDirty: Bool) -> Result<MergeAction, MergeBlock> }`
  - `public enum MergeOrder` — each returns `[Int64: Int]` (subagent id → 1-based index for every non-discarded member):
    - `static func appending(_ newID: Int64, to members: [Subagent]) -> [Int64: Int]`
    - `static func inserting(_ newID: Int64, at position: Int, into members: [Subagent]) -> [Int64: Int]`
    - `static func reordering(_ members: [Subagent], requested: [Int64]) -> [Int64: Int]`
    - `static func removing(_ id: Int64, from members: [Subagent]) -> [Int64: Int]`

- [ ] **Step 1: Write the failing gate tests**

`Tests/CCHCoreTests/MergeGateTests.swift`:

```swift
import XCTest
@testable import CCHCore

final class MergeGateTests: XCTestCase {
    private func gate(_ s: Subagent, members: [Subagent] = [], commits: Bool = true, dirty: Bool = false)
        -> Result<MergeAction, MergeBlock> {
        MergeGate.evaluate(s, groupMembers: members, hasCommits: commits, isDirty: dirty)
    }

    func testUngroupedIdleWithCommitsMerges() {
        XCTAssertEqual(gate(makeSubagent(state: .idle)), .success(.merge))
    }

    func testDirtyTreeWithoutCommitsStillMerges() {
        XCTAssertEqual(gate(makeSubagent(state: .idle), commits: false, dirty: true), .success(.merge))
    }

    func testNothingToMergeArchives() {
        XCTAssertEqual(gate(makeSubagent(state: .complete), commits: false, dirty: false),
                       .success(.archiveNothingToMerge))
    }

    func testBusyStates() {
        for state in [SubagentState.starting, .running, .needsInput] {
            XCTAssertEqual(gate(makeSubagent(state: state)), .failure(.busy))
        }
        XCTAssertEqual(gate(makeSubagent(state: .merging, substate: .awaitingCommit)), .failure(.busy))
    }

    func testAwaitingMainResends() {
        XCTAssertEqual(gate(makeSubagent(state: .merging, substate: .awaitingMain)), .success(.resend))
    }

    func testNotMergeableStates() {
        for state in [SubagentState.interrupted, .stopped, .failed, .merged, .discarded] {
            XCTAssertEqual(gate(makeSubagent(state: state)), .failure(.notMergeable))
        }
    }

    func testGroupWaitsOnLowestUnmergedPredecessor() {
        let first = makeSubagent(id: 1, state: .idle, groupID: 9, index: 1)
        let second = makeSubagent(id: 2, state: .complete, groupID: 9, index: 2)
        XCTAssertEqual(gate(second, members: [first, second]), .failure(.waitsOn(index: 1)))
    }

    func testGroupPredecessorsMergedOrDiscardedUnblock() {
        let first = makeSubagent(id: 1, state: .merged, groupID: 9, index: 1)
        let second = makeSubagent(id: 2, state: .discarded, groupID: 9, index: 2)
        let third = makeSubagent(id: 3, state: .idle, groupID: 9, index: 3)
        XCTAssertEqual(gate(third, members: [first, second, third]), .success(.merge))
    }

    func testGroupBlockedBySecondWhenFirstMerged() {
        let first = makeSubagent(id: 1, state: .merged, groupID: 9, index: 1)
        let second = makeSubagent(id: 2, state: .running, groupID: 9, index: 2)
        let third = makeSubagent(id: 3, state: .idle, groupID: 9, index: 3)
        XCTAssertEqual(gate(third, members: [first, second, third]), .failure(.waitsOn(index: 2)))
    }

    func testMembersOfOtherGroupsAreIgnored() {
        let other = makeSubagent(id: 1, state: .idle, groupID: 4, index: 1)
        let mine = makeSubagent(id: 2, state: .idle, groupID: 9, index: 2)
        XCTAssertEqual(gate(mine, members: [other, mine]), .success(.merge))
    }
}
```

- [ ] **Step 2: Write the failing order tests**

`Tests/CCHCoreTests/MergeOrderTests.swift`:

```swift
import XCTest
@testable import CCHCore

final class MergeOrderTests: XCTestCase {
    private let a = makeSubagent(id: 1, state: .merged, groupID: 9, index: 1)
    private let b = makeSubagent(id: 2, state: .idle, groupID: 9, index: 2)
    private let c = makeSubagent(id: 3, state: .running, groupID: 9, index: 3)

    func testAppending() {
        XCTAssertEqual(MergeOrder.appending(4, to: [a, b, c]), [1: 1, 2: 2, 3: 3, 4: 4])
        XCTAssertEqual(MergeOrder.appending(9, to: []), [9: 1])
    }

    func testAppendingDropsDiscardedAndClosesGaps() {
        let gone = makeSubagent(id: 1, state: .discarded, groupID: 9, index: 1)
        XCTAssertEqual(MergeOrder.appending(4, to: [gone, b]), [2: 1, 4: 2])
    }

    func testInsertingNeverJumpsAheadOfMerged() {
        XCTAssertEqual(MergeOrder.inserting(4, at: 1, into: [a, b, c]), [1: 1, 4: 2, 2: 3, 3: 4])
    }

    func testInsertingInTheMiddleAndPastTheEnd() {
        XCTAssertEqual(MergeOrder.inserting(4, at: 3, into: [a, b, c]), [1: 1, 2: 2, 4: 3, 3: 4])
        XCTAssertEqual(MergeOrder.inserting(4, at: 99, into: [a, b, c]), [1: 1, 2: 2, 3: 3, 4: 4])
    }

    func testReorderingKeepsMergedFirstAndAppendsUnmentioned() {
        XCTAssertEqual(MergeOrder.reordering([c, b, a], requested: [3, 2]), [1: 1, 3: 2, 2: 3])
        XCTAssertEqual(MergeOrder.reordering([a, b, c], requested: [3]), [1: 1, 3: 2, 2: 3])
    }

    func testReorderingAcceptsNewIDsAndIgnoresDuplicatesAndMerged() {
        XCTAssertEqual(MergeOrder.reordering([a, b, c], requested: [4, 1, 4, 2]), [1: 1, 4: 2, 2: 3, 3: 4])
    }

    func testRemoving() {
        XCTAssertEqual(MergeOrder.removing(2, from: [a, b, c]), [1: 1, 3: 2])
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter "CCHCoreTests.(MergeGateTests|MergeOrderTests)"`
Expected: FAIL — `cannot find 'MergeGate' in scope`, `cannot find 'MergeOrder' in scope`.

- [ ] **Step 4: Implement the gate**

`Sources/CCHCore/Rules/MergeGate.swift`:

```swift
import Foundation

public enum MergeAction: Equatable, Sendable {
    case merge                  // start the merge flow (spec §5 steps 3–5)
    case archiveNothingToMerge  // Done button: no commits, clean tree (D9)
    case resend                 // Re-send Merge while awaiting main
}

public enum MergeBlock: Error, Equatable, Sendable {
    case busy                   // mid-turn or waiting on its own commit
    case waitsOn(index: Int)    // an earlier group member isn't merged yet (R11)
    case notMergeable           // interrupted, stopped, failed, merged, discarded
}

/// Whether the Merge button may act, enforced in agentd as well as the UI (spec §5 step 1).
public enum MergeGate {
    public static func evaluate(
        _ subagent: Subagent,
        groupMembers: [Subagent],
        hasCommits: Bool,
        isDirty: Bool
    ) -> Result<MergeAction, MergeBlock> {
        switch subagent.state {
        case .merging:
            return subagent.mergeSubstate == .awaitingMain ? .success(.resend) : .failure(.busy)
        case .starting, .running, .needsInput:
            return .failure(.busy)
        case .interrupted, .stopped, .failed, .merged, .discarded:
            return .failure(.notMergeable)
        case .idle, .complete:
            break
        }

        if let groupID = subagent.mergeGroupID, let index = subagent.mergeIndex {
            let blocker = groupMembers
                .filter { $0.id != subagent.id && $0.mergeGroupID == groupID }
                .filter { $0.state != .merged && $0.state != .discarded }
                .compactMap(\.mergeIndex)
                .filter { $0 < index }
                .min()
            if let blocker { return .failure(.waitsOn(index: blocker)) }
        }

        return (!hasCommits && !isDirty) ? .success(.archiveNothingToMerge) : .success(.merge)
    }
}
```

- [ ] **Step 5: Implement the order rules**

`Sources/CCHCore/Rules/MergeOrder.swift`:

```swift
import Foundation

/// Index assignment for merge groups (spec §5 "Merge groups"). Every function returns the
/// complete new numbering, 1…n with no gaps, for all non-discarded members. Merged members
/// always stay ahead of unmerged ones.
public enum MergeOrder {
    public static func appending(_ newID: Int64, to members: [Subagent]) -> [Int64: Int] {
        number(ordered(members).map(\.id).filter { $0 != newID } + [newID])
    }

    /// `position` is 1-based over the whole group and is clamped so the new member never
    /// lands before an already merged one.
    public static func inserting(_ newID: Int64, at position: Int, into members: [Subagent]) -> [Int64: Int] {
        let current = ordered(members).filter { $0.id != newID }
        let merged = current.filter { $0.state == .merged }.map(\.id)
        var unmerged = current.filter { $0.state != .merged }.map(\.id)
        let slot = min(max(position - 1 - merged.count, 0), unmerged.count)
        unmerged.insert(newID, at: slot)
        return number(merged + unmerged)
    }

    /// `requested` may include ids not yet in the group (they are being moved in). Merged ids
    /// and duplicates in `requested` are ignored; unmentioned unmerged members keep their
    /// relative order after the requested ones.
    public static func reordering(_ members: [Subagent], requested: [Int64]) -> [Int64: Int] {
        let current = ordered(members)
        let merged = current.filter { $0.state == .merged }.map(\.id)
        let mergedSet = Set(merged)
        var seen = Set<Int64>()
        let front = requested.filter { !mergedSet.contains($0) && seen.insert($0).inserted }
        let rest = current.map(\.id).filter { !mergedSet.contains($0) && !seen.contains($0) }
        return number(merged + front + rest)
    }

    public static func removing(_ id: Int64, from members: [Subagent]) -> [Int64: Int] {
        number(ordered(members).map(\.id).filter { $0 != id })
    }

    private static func ordered(_ members: [Subagent]) -> [Subagent] {
        members
            .filter { $0.state != .discarded }
            .sorted { ($0.mergeIndex ?? Int.max, $0.id) < ($1.mergeIndex ?? Int.max, $1.id) }
    }

    private static func number(_ ids: [Int64]) -> [Int64: Int] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset + 1) })
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter "CCHCoreTests.(MergeGateTests|MergeOrderTests)"`
Expected: `Executed 17 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Sources/CCHCore/Rules/MergeGate.swift Sources/CCHCore/Rules/MergeOrder.swift Tests/CCHCoreTests/MergeGateTests.swift Tests/CCHCoreTests/MergeOrderTests.swift
git commit -m "feat(core): merge gate and merge-group ordering rules"
```

---

### Task 7: Recovery planner

**Files:**
- Create: `Sources/CCHCore/Rules/RecoveryPlanner.swift`
- Test: `Tests/CCHCoreTests/RecoveryPlannerTests.swift`

**Interfaces:**
- Consumes: `Subagent`, `SubagentState`, `MergeSubstate`; `makeSubagent`, `epoch` (Task 4).
- Produces:
  - `public enum RecoveryNudge: Equatable, Sendable { case none, continueWork, commitRequest }`
  - `public enum RecoveryAction: Equatable, Sendable { case nothing, reattach, relaunch(RecoveryNudge), awaitManualResume, fail(reason: String) }`
  - `public struct RecoveryPolicy: Equatable, Sendable { var autoResume: Bool; var maxResumes: Int; var window: TimeInterval; init(autoResume: Bool = true, maxResumes: Int = 3, window: TimeInterval = 1800) }`
  - `public enum RecoveryPlanner { static let crashLoopReason = "crash loop"; static func plan(for subagent: Subagent, hostAlive: Bool, now: Date, policy: RecoveryPolicy = RecoveryPolicy()) -> RecoveryAction }`

- [ ] **Step 1: Write the failing tests (one per spec §2 recovery row, plus crash loop)**

`Tests/CCHCoreTests/RecoveryPlannerTests.swift`:

```swift
import XCTest
@testable import CCHCore

final class RecoveryPlannerTests: XCTestCase {
    private func plan(_ s: Subagent, alive: Bool, auto: Bool = true) -> RecoveryAction {
        RecoveryPlanner.plan(for: s, hostAlive: alive, now: epoch, policy: RecoveryPolicy(autoResume: auto))
    }

    func testLiveHostsReattach() {
        for state in [SubagentState.starting, .running, .needsInput, .idle, .interrupted, .complete] {
            XCTAssertEqual(plan(makeSubagent(state: state), alive: true), .reattach, "\(state)")
        }
        XCTAssertEqual(plan(makeSubagent(state: .merging, substate: .awaitingMain), alive: true), .reattach)
    }

    func testDeadWorkingSubagentsResumeWithNudge() {
        for state in [SubagentState.starting, .running, .needsInput, .interrupted] {
            XCTAssertEqual(plan(makeSubagent(state: state), alive: false), .relaunch(.continueWork), "\(state)")
        }
    }

    func testManualResumePolicyWaitsForClick() {
        XCTAssertEqual(plan(makeSubagent(state: .running), alive: false, auto: false), .awaitManualResume)
        XCTAssertEqual(plan(makeSubagent(state: .interrupted), alive: false, auto: false), .awaitManualResume)
    }

    func testDeadIdleSubagentRelaunchesSilentlyEvenWhenManual() {
        XCTAssertEqual(plan(makeSubagent(state: .idle), alive: false), .relaunch(.none))
        XCTAssertEqual(plan(makeSubagent(state: .idle), alive: false, auto: false), .relaunch(.none))
    }

    func testMergingSubstates() {
        XCTAssertEqual(plan(makeSubagent(state: .merging, substate: .awaitingCommit), alive: false),
                       .relaunch(.commitRequest))
        XCTAssertEqual(plan(makeSubagent(state: .merging, substate: .awaitingMain), alive: false), .nothing)
    }

    func testFinishedSubagentsNeverRestart() {
        for state in [SubagentState.complete, .merged, .stopped, .failed, .discarded] {
            XCTAssertEqual(plan(makeSubagent(state: state), alive: false), .nothing, "\(state)")
        }
    }

    func testStrayHostForArchivedSubagentIsLeftAlone() {
        for state in [SubagentState.merged, .stopped, .failed, .discarded] {
            XCTAssertEqual(plan(makeSubagent(state: state), alive: true), .nothing, "\(state)")
        }
    }

    func testCrashLoopFails() {
        var s = makeSubagent(state: .running)
        s.resumeCount = 3
        s.lastResumeAt = epoch.addingTimeInterval(-60)
        XCTAssertEqual(plan(s, alive: false), .fail(reason: "crash loop"))
    }

    func testOldResumesDoNotCount() {
        var s = makeSubagent(state: .running)
        s.resumeCount = 3
        s.lastResumeAt = epoch.addingTimeInterval(-3600)
        XCTAssertEqual(plan(s, alive: false), .relaunch(.continueWork))
    }

    func testBelowLimitStillResumes() {
        var s = makeSubagent(state: .interrupted)
        s.resumeCount = 2
        s.lastResumeAt = epoch.addingTimeInterval(-60)
        XCTAssertEqual(plan(s, alive: false), .relaunch(.continueWork))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CCHCoreTests.RecoveryPlannerTests`
Expected: FAIL — `cannot find 'RecoveryPlanner' in scope`.

- [ ] **Step 3: Implement**

`Sources/CCHCore/Rules/RecoveryPlanner.swift`:

```swift
import Foundation

/// What to type into a relaunched subagent.
public enum RecoveryNudge: Equatable, Sendable {
    case none            // resume silently
    case continueWork    // "You were interrupted… continue from Next"
    case commitRequest   // resend the merge commit request
}

public enum RecoveryAction: Equatable, Sendable {
    case nothing
    case reattach
    case relaunch(RecoveryNudge)
    case awaitManualResume
    case fail(reason: String)
}

public struct RecoveryPolicy: Equatable, Sendable {
    public var autoResume: Bool
    public var maxResumes: Int
    public var window: TimeInterval

    public init(autoResume: Bool = true, maxResumes: Int = 3, window: TimeInterval = 30 * 60) {
        self.autoResume = autoResume
        self.maxResumes = maxResumes
        self.window = window
    }
}

/// Per-subagent decision cch-agentd makes on startup (spec §2 Recovery table, R13/R14).
public enum RecoveryPlanner {
    public static let crashLoopReason = "crash loop"

    public static func plan(
        for subagent: Subagent,
        hostAlive: Bool,
        now: Date,
        policy: RecoveryPolicy = RecoveryPolicy()
    ) -> RecoveryAction {
        switch subagent.state {
        case .merged, .stopped, .failed, .discarded:
            return .nothing

        case .complete:
            return hostAlive ? .reattach : .nothing

        case .merging:
            if hostAlive { return .reattach }
            return subagent.mergeSubstate == .awaitingCommit ? .relaunch(.commitRequest) : .nothing

        case .idle:
            return hostAlive ? .reattach : .relaunch(.none)

        case .starting, .running, .needsInput, .interrupted:
            if hostAlive { return .reattach }
            if isCrashLooping(subagent, now: now, policy: policy) { return .fail(reason: crashLoopReason) }
            return policy.autoResume ? .relaunch(.continueWork) : .awaitManualResume
        }
    }

    static func isCrashLooping(_ subagent: Subagent, now: Date, policy: RecoveryPolicy) -> Bool {
        guard let last = subagent.lastResumeAt, now.timeIntervalSince(last) < policy.window else { return false }
        return subagent.resumeCount >= policy.maxResumes
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CCHCoreTests.RecoveryPlannerTests`
Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CCHCore/Rules/RecoveryPlanner.swift Tests/CCHCoreTests/RecoveryPlannerTests.swift
git commit -m "feat(core): startup recovery planner with crash-loop guard"
```

---

### Task 8: Hook policy

**Files:**
- Create: `Sources/CCHCore/Rules/HookPolicy.swift`
- Test: `Tests/CCHCoreTests/HookPolicyTests.swift`

**Interfaces:**
- Consumes: `Subagent`; `makeSubagent`, `epoch` (Task 4).
- Produces:
  - `public enum HookReply: Equatable, Sendable { case none, blockStop(reason: String), addContext(event: String, text: String) }`
  - `public enum HookPolicy`
    - `static let stopReason: String`, `static let reminderInterval: TimeInterval` (600), `static let reminderText: String`
    - `static func onStop(_ subagent: Subagent, stopHookActive: Bool) -> HookReply`
    - `static func onPostToolUse(_ subagent: Subagent, now: Date) -> HookReply`
    - `static func stdout(for reply: HookReply) -> Data` (what `cch-mcp hook` prints; empty for `.none`)

- [ ] **Step 1: Write the failing tests**

`Tests/CCHCoreTests/HookPolicyTests.swift`:

```swift
import XCTest
@testable import CCHCore

final class HookPolicyTests: XCTestCase {
    func testStopBlocksWhenNoReportThisTurn() {
        var s = makeSubagent(state: .running)
        s.turnsStarted = 2
        s.lastReportTurn = 1
        XCTAssertEqual(HookPolicy.onStop(s, stopHookActive: false), .blockStop(reason: HookPolicy.stopReason))
    }

    func testStopBlocksBrandNewSubagent() {
        let s = makeSubagent(state: .starting)  // turnsStarted 0, lastReportTurn -1
        XCTAssertEqual(HookPolicy.onStop(s, stopHookActive: false), .blockStop(reason: HookPolicy.stopReason))
    }

    func testStopAllowedWhenReportedThisTurn() {
        var s = makeSubagent(state: .running)
        s.turnsStarted = 2
        s.lastReportTurn = 2
        XCTAssertEqual(HookPolicy.onStop(s, stopHookActive: false), .none)
    }

    func testStopNeverBlocksTwiceOrAfterCompletion() {
        var s = makeSubagent(state: .running)
        s.turnsStarted = 2
        s.lastReportTurn = 1
        XCTAssertEqual(HookPolicy.onStop(s, stopHookActive: true), .none)
        s.completedAt = epoch
        XCTAssertEqual(HookPolicy.onStop(s, stopHookActive: false), .none)
    }

    func testPostToolUseRemindsAfterTenMinutesSinceCreation() {
        var s = makeSubagent(state: .running)
        s.createdAt = epoch.addingTimeInterval(-601)
        XCTAssertEqual(HookPolicy.onPostToolUse(s, now: epoch),
                       .addContext(event: "PostToolUse", text: HookPolicy.reminderText))
    }

    func testPostToolUseUsesLastReportTime() {
        var s = makeSubagent(state: .running)
        s.createdAt = epoch.addingTimeInterval(-7200)
        s.lastReportAt = epoch.addingTimeInterval(-30)
        XCTAssertEqual(HookPolicy.onPostToolUse(s, now: epoch), .none)
        s.lastReportAt = epoch.addingTimeInterval(-700)
        XCTAssertEqual(HookPolicy.onPostToolUse(s, now: epoch),
                       .addContext(event: "PostToolUse", text: HookPolicy.reminderText))
    }

    func testPostToolUseSilentAfterCompletion() {
        var s = makeSubagent(state: .complete)
        s.createdAt = epoch.addingTimeInterval(-7200)
        s.completedAt = epoch
        XCTAssertEqual(HookPolicy.onPostToolUse(s, now: epoch), .none)
    }

    func testStdoutShapes() throws {
        XCTAssertTrue(HookPolicy.stdout(for: .none).isEmpty)

        let block = try JSONSerialization.jsonObject(
            with: HookPolicy.stdout(for: .blockStop(reason: "why"))) as? [String: Any]
        XCTAssertEqual(block?["decision"] as? String, "block")
        XCTAssertEqual(block?["reason"] as? String, "why")

        let context = try JSONSerialization.jsonObject(
            with: HookPolicy.stdout(for: .addContext(event: "PostToolUse", text: "hi"))) as? [String: Any]
        let specific = context?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(specific?["hookEventName"] as? String, "PostToolUse")
        XCTAssertEqual(specific?["additionalContext"] as? String, "hi")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CCHCoreTests.HookPolicyTests`
Expected: FAIL — `cannot find 'HookPolicy' in scope`.

- [ ] **Step 3: Implement**

`Sources/CCHCore/Rules/HookPolicy.swift`:

```swift
import Foundation

public enum HookReply: Equatable, Sendable {
    case none
    case blockStop(reason: String)
    case addContext(event: String, text: String)
}

/// Decisions for Claude Code hook events coming from subagents (spec §2 "Status reporting").
public enum HookPolicy {
    public static let stopReason = "Call report_status (summary, done, next) before stopping."
    public static let reminderInterval: TimeInterval = 10 * 60
    public static let reminderText =
        "It has been over 10 minutes since your last report_status. Call it now, then continue."

    /// Block the end of a turn once if the subagent hasn't reported during it.
    public static func onStop(_ subagent: Subagent, stopHookActive: Bool) -> HookReply {
        if stopHookActive || subagent.completedAt != nil { return .none }
        return subagent.lastReportTurn < subagent.turnsStarted ? .blockStop(reason: stopReason) : .none
    }

    /// Nudge long-running turns that haven't reported for `reminderInterval`.
    public static func onPostToolUse(_ subagent: Subagent, now: Date) -> HookReply {
        if subagent.completedAt != nil { return .none }
        let since = subagent.lastReportAt ?? subagent.createdAt
        guard now.timeIntervalSince(since) > reminderInterval else { return .none }
        return .addContext(event: "PostToolUse", text: reminderText)
    }

    /// JSON printed by `cch-mcp hook <event>`. Empty data means print nothing.
    public static func stdout(for reply: HookReply) -> Data {
        let object: [String: Any]
        switch reply {
        case .none:
            return Data()
        case .blockStop(let reason):
            object = ["decision": "block", "reason": reason]
        case .addContext(let event, let text):
            object = ["hookSpecificOutput": ["hookEventName": event, "additionalContext": text]]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CCHCoreTests.HookPolicyTests`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CCHCore/Rules/HookPolicy.swift Tests/CCHCoreTests/HookPolicyTests.swift
git commit -m "feat(core): stop and post-tool-use hook policy"
```

---

### Task 9: Subagent model resolution

**Files:**
- Create: `Sources/CCHCore/Rules/SubagentModel.swift`
- Test: `Tests/CCHCoreTests/SubagentModelTests.swift`

**Interfaces:**
- Consumes: `SubagentCategory` (Task 4).
- Produces:
  - `public enum SubagentModel`
  - `static let aliases: [String]` = `["fable", "opus", "sonnet", "haiku"]`
  - `static func isValid(_ value: String) -> Bool`
  - `static func resolve(override: String?, categoryDefault: String?) -> String?` (nil = CLI default)
  - `static func launchArguments(for model: String?) -> [String]`
  - `static func prefKey(for category: SubagentCategory) -> String`

- [ ] **Step 1: Write the failing tests**

`Tests/CCHCoreTests/SubagentModelTests.swift`:

```swift
import XCTest
@testable import CCHCore

final class SubagentModelTests: XCTestCase {
    func testValidValues() {
        for value in ["fable", "opus", "sonnet", "haiku", "sonnet[1m]",
                      "claude-haiku-4-5-20251001", "claude-opus-5", "claude-opus-5[1m]", "claude-fable-5-1"] {
            XCTAssertTrue(SubagentModel.isValid(value), value)
        }
    }

    func testInvalidValues() {
        for value in ["", "Opus", "gpt-5", "claude-", "opus; rm -rf ~", "claude-opus 5", "haiku[2m]"] {
            XCTAssertFalse(SubagentModel.isValid(value), value)
        }
    }

    func testResolveOverrideWinsAndBlanksMeanUnset() {
        XCTAssertEqual(SubagentModel.resolve(override: "haiku", categoryDefault: "opus"), "haiku")
        XCTAssertEqual(SubagentModel.resolve(override: "  ", categoryDefault: "opus"), "opus")
        XCTAssertEqual(SubagentModel.resolve(override: nil, categoryDefault: " sonnet "), "sonnet")
        XCTAssertNil(SubagentModel.resolve(override: nil, categoryDefault: ""))
        XCTAssertNil(SubagentModel.resolve(override: nil, categoryDefault: nil))
    }

    func testLaunchArgumentsAndPrefKeys() {
        XCTAssertEqual(SubagentModel.launchArguments(for: nil), [])
        XCTAssertEqual(SubagentModel.launchArguments(for: "haiku"), ["--model", "haiku"])
        XCTAssertEqual(SubagentCategory.allCases.map(SubagentModel.prefKey(for:)),
                       ["model.task", "model.bug", "model.feature", "model.helper"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CCHCoreTests.SubagentModelTests`
Expected: FAIL — `cannot find 'SubagentModel' in scope`.

- [ ] **Step 3: Implement**

`Sources/CCHCore/Rules/SubagentModel.swift`:

```swift
import Foundation

/// Which model a subagent runs on (spec R15, D14). `nil` means "don't pass --model", i.e. the
/// claude CLI's own default.
public enum SubagentModel {
    public static let aliases = ["fable", "opus", "sonnet", "haiku"]
    private static let longContextSuffix = "[1m]"

    /// Accepts the CLI's aliases or a full `claude-…` model name, each optionally with `[1m]`.
    /// Strict on purpose: the value ends up as a process argument and in a settings field.
    public static func isValid(_ value: String) -> Bool {
        let base = value.hasSuffix(longContextSuffix) ? String(value.dropLast(longContextSuffix.count)) : value
        if aliases.contains(base) { return true }
        let prefix = "claude-"
        guard base.hasPrefix(prefix), base.count > prefix.count else { return false }
        return base.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }

    /// A per-spawn override wins over the category default. Blank strings count as unset.
    public static func resolve(override: String?, categoryDefault: String?) -> String? {
        for candidate in [override, categoryDefault] {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    public static func launchArguments(for model: String?) -> [String] {
        guard let model else { return [] }
        return ["--model", model]
    }

    public static func prefKey(for category: SubagentCategory) -> String {
        "model.\(category.rawValue)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CCHCoreTests.SubagentModelTests`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CCHCore/Rules/SubagentModel.swift Tests/CCHCoreTests/SubagentModelTests.swift
git commit -m "feat(core): subagent model validation and resolution"
```

---

### Task 10: Phase verification

**Files:**
- Modify: `docs/superpowers/plans/2026-09-14-subagents-roadmap.md` (Status column for Phase 1)

**Interfaces:**
- Consumes: everything above.
- Produces: a green, bundled app with `CCHCore` linked, ready for the Phase 2 plan.

- [ ] **Step 1: Full test run**

Run: `swift test 2>&1 | tail -5`
Expected: `Executed 67 tests, with 0 failures` (5 locator + 5 model + 11 state machine + 7 naming + 10 gate + 7 order + 10 recovery + 8 hook + 4 subagent model). If the count differs, list the suites with `swift test list` and reconcile before continuing.

- [ ] **Step 2: Bundle and smoke-test the app**

Run:
```bash
scripts/bundle.sh --run
sleep 4
pgrep -fl "ClaudeCodeHub.app/Contents/MacOS/ClaudeCodeHub"
tail -5 ~/Library/Logs/ClaudeCodeHub.log
```
Expected: app running from `build/ClaudeCodeHub.app`; log shows a recent `[TerminalRegistry] spawn claude=…` line after selecting a session. Clicking a session shows the Claude terminal exactly as before this phase.

- [ ] **Step 3: Mark the roadmap and commit**

In `docs/superpowers/plans/2026-09-14-subagents-roadmap.md`, change the Phase 1 Status cell from `Plan written` to `Done`.

```bash
git add docs/superpowers/plans/2026-09-14-subagents-roadmap.md
git commit -m "docs: mark subagents phase 1 done"
```

- [ ] **Step 4: Hand off**

Report the test count and smoke-test result to the user. Do not start Phase 2 until the Phase 0 FINDINGS are accepted and the Phase 2 plan is written.
