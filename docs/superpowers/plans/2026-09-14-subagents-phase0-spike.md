# Subagents Phase 0 — Feasibility Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove or disprove the six platform assumptions in spec §1 "Risk" and record decisions in `spikes/FINDINGS.md`.

**Architecture:** Two throwaway harnesses. (1) A standalone SwiftPM package that builds a tiny `.app` containing a LaunchAgent (`spike-agentd`, Mach XPC service), an app executable that registers it via `SMAppService`, and a client that pings it from different process ancestries. (2) A Claude Code plugin directory with four slash commands, a Python stdio MCP server, logging hooks, and Python PTY drivers that type into the real `claude` TUI and check the results through hook logs and the session transcript.

**Tech Stack:** Swift 6.3 toolchain (tools-version 5.9), ServiceManagement, Foundation XPC, Python 3.9 (`/usr/bin/python3`), `claude` 2.1.270 at `~/.local/bin/claude`, git 2.50.

**Spec:** `docs/superpowers/specs/2026-09-14-subagents-design.md` (§1 Risk list, §2 hooks, §3 plugins, D4)

## Global Constraints

- Everything lives under `ClaudeCodeHub/spikes/`; it is throwaway and never imported by the app.
- No git commits in this phase (the project is not yet a git repository; Phase 1 Task 1 creates it).
- All harness logs append to `~/Library/Logs/cch-spike.log`.
- Service label and Mach name: `dev.cch.spike.agentd`. App bundle id: `dev.cch.spike.app`.
- Scripted `claude` runs use `--model haiku` to limit token spend.
- Steps marked **USER** need the human (System Settings approval). Stop and ask.
- Clean up at the end: unregister the spike LaunchAgent and remove spike worktrees (Task 4).

---

### Task 1: LaunchAgent + Mach XPC reachability (proofs 1 and 2)

**Files:**
- Create: `spikes/agentd-xpc/Package.swift`
- Create: `spikes/agentd-xpc/Sources/SpikeShared/SpikeShared.swift`
- Create: `spikes/agentd-xpc/Sources/spike-agentd/main.swift`
- Create: `spikes/agentd-xpc/Sources/spike-client/main.swift`
- Create: `spikes/agentd-xpc/Sources/SpikeApp/main.swift`
- Create: `spikes/agentd-xpc/Support/dev.cch.spike.agentd.plist`
- Create: `spikes/agentd-xpc/bundle.sh`

**Interfaces:**
- Produces: results for FINDINGS rows P1 (register + app lookup), P1b (ad-hoc code-signing requirement enforced), P2 (grandchild lookup), P2b (launchd restarts killed agentd).

- [ ] **Step 1: Create the package manifest**

`spikes/agentd-xpc/Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentdSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SpikeShared", path: "Sources/SpikeShared"),
        .executableTarget(name: "SpikeApp", dependencies: ["SpikeShared"], path: "Sources/SpikeApp"),
        .executableTarget(name: "spike-agentd", dependencies: ["SpikeShared"], path: "Sources/spike-agentd"),
        .executableTarget(name: "spike-client", dependencies: ["SpikeShared"], path: "Sources/spike-client"),
    ]
)
```

- [ ] **Step 2: Shared protocol, logger, and ping helper**

`spikes/agentd-xpc/Sources/SpikeShared/SpikeShared.swift`:

```swift
import Foundation

public let spikeServiceName = "dev.cch.spike.agentd"

@objc public protocol SpikeAPI {
    func ping(_ from: String, reply: @escaping (String) -> Void)
    func spawnGrandchild(reply: @escaping (String) -> Void)
}

public func spikeLog(_ message: String) {
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/cch-spike.log")
    let line = "\(Date()) [\(ProcessInfo.processInfo.processName) pid=\(getpid())] \(message)\n"
    let data = Data(line.utf8)
    FileHandle.standardError.write(data)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

/// Connects to the spike agent, sends one ping, and returns the reply or an error string.
public func pingAgentd(from: String, timeout: TimeInterval = 5) -> String {
    let connection = NSXPCConnection(machServiceName: spikeServiceName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: SpikeAPI.self)
    connection.resume()
    let done = DispatchSemaphore(value: 0)
    var result = "TIMEOUT"
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        result = "ERROR: \(error)"
        done.signal()
    } as! SpikeAPI
    proxy.ping(from) { reply in
        result = reply
        done.signal()
    }
    _ = done.wait(timeout: .now() + timeout)
    connection.invalidate()
    return result
}
```

- [ ] **Step 3: The agent**

`spikes/agentd-xpc/Sources/spike-agentd/main.swift`:

```swift
import Foundation
import SpikeShared

final class Service: NSObject, NSXPCListenerDelegate, SpikeAPI {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        spikeLog("accept pid=\(connection.processIdentifier)")
        // P1b: ad-hoc signatures carry an identifier; prove the requirement is enforced.
        connection.setCodeSigningRequirement(
            "identifier \"dev.cch.spike.app\" or identifier \"dev.cch.spike.client\""
        )
        connection.exportedInterface = NSXPCInterface(with: SpikeAPI.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func ping(_ from: String, reply: @escaping (String) -> Void) {
        spikeLog("ping from \(from)")
        reply("pong from agentd pid=\(getpid()) to \(from)")
    }

    /// agentd → /bin/sh → spike-client, mimicking agentd → host → claude → cch-mcp.
    func spawnGrandchild(reply: @escaping (String) -> Void) {
        let client = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("spike-client").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "'\(client)' grandchild-of-agentd"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            reply("spawn failed: \(error)")
            return
        }
        DispatchQueue.global().async {
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            reply(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

spikeLog("agentd starting")
let service = Service()
let listener = NSXPCListener(machServiceName: spikeServiceName)
listener.delegate = service
listener.resume()
RunLoop.main.run()
```

- [ ] **Step 4: The client**

`spikes/agentd-xpc/Sources/spike-client/main.swift`:

```swift
import Foundation
import SpikeShared

let label = CommandLine.arguments.dropFirst().first ?? "client"
print(pingAgentd(from: "\(label) pid=\(getpid()) ppid=\(getppid())"))
```

- [ ] **Step 5: The app executable**

`spikes/agentd-xpc/Sources/SpikeApp/main.swift`:

```swift
import Foundation
import ServiceManagement
import SpikeShared

let agent = SMAppService.agent(plistName: "dev.cch.spike.agentd.plist")

func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}

let command = CommandLine.arguments.dropFirst().first ?? "status"
switch command {
case "register":
    do {
        try agent.register()
        print("registered; status=\(describe(agent.status))")
    } catch {
        print("register failed: \(error); status=\(describe(agent.status))")
    }
    if agent.status == .requiresApproval {
        SMAppService.openSystemSettingsLoginItems()
    }
case "unregister":
    do {
        try agent.unregister()
        print("unregistered; status=\(describe(agent.status))")
    } catch {
        print("unregister failed: \(error)")
    }
case "status":
    print("status=\(describe(agent.status))")
case "ping":
    print(pingAgentd(from: "app"))
case "grandchild-app":
    let client = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/spike-client").path
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "'\(client)' grandchild-of-app"]
    try process.run()
    process.waitUntilExit()
case "grandchild-agentd":
    let connection = NSXPCConnection(machServiceName: spikeServiceName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: SpikeAPI.self)
    connection.resume()
    let done = DispatchSemaphore(value: 0)
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        print("ERROR: \(error)")
        done.signal()
    } as! SpikeAPI
    proxy.spawnGrandchild { output in
        print(output)
        done.signal()
    }
    if done.wait(timeout: .now() + 15) == .timedOut { print("TIMEOUT") }
default:
    print("usage: SpikeApp register|status|ping|grandchild-app|grandchild-agentd|unregister")
}
```

- [ ] **Step 6: LaunchAgent plist**

`spikes/agentd-xpc/Support/dev.cch.spike.agentd.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.cch.spike.agentd</string>
  <key>BundleProgram</key><string>Contents/MacOS/spike-agentd</string>
  <key>MachServices</key>
  <dict>
    <key>dev.cch.spike.agentd</key><true/>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>AssociatedBundleIdentifiers</key>
  <array><string>dev.cch.spike.app</string></array>
</dict>
</plist>
```

- [ ] **Step 7: Bundle script**

`spikes/agentd-xpc/bundle.sh`:

```bash
#!/bin/bash
# Build the spike and assemble build/Spike.app with an embedded LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"
swift build
BIN=.build/debug
APP=build/Spike.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/SpikeApp" "$BIN/spike-agentd" "$BIN/spike-client" "$APP/Contents/MacOS/"
cp Support/dev.cch.spike.agentd.plist "$APP/Contents/Library/LaunchAgents/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SpikeApp</string>
  <key>CFBundleIdentifier</key><string>dev.cch.spike.app</string>
  <key>CFBundleName</key><string>CCH Spike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier dev.cch.spike.agentd "$APP/Contents/MacOS/spike-agentd"
codesign --force --sign - --identifier dev.cch.spike.client "$APP/Contents/MacOS/spike-client"
codesign --force --sign - "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "built $APP"
```

Run: `chmod +x spikes/agentd-xpc/bundle.sh && spikes/agentd-xpc/bundle.sh`
Expected: ends with `built build/Spike.app`, no compiler errors.

- [ ] **Step 8: Register the agent (P1, part 1)**

Run: `spikes/agentd-xpc/build/Spike.app/Contents/MacOS/SpikeApp register`
Expected: `registered; status=enabled`, or `status=requiresApproval` (System Settings opens).

**USER** (only if `requiresApproval`): in System Settings → General → Login Items & Extensions, allow "CCH Spike" / `spike-agentd` to run in the background. Then run `…/SpikeApp status` and expect `status=enabled`.

Record the exact output, including any error text, for FINDINGS P1.

- [ ] **Step 9: Confirm launchd is running it**

Run: `launchctl print gui/$(id -u)/dev.cch.spike.agentd | grep -E "state|program|pid" ; pgrep -fl spike-agentd`
Expected: `state = running`, a pid, and program path inside `spikes/agentd-xpc/build/Spike.app`.

- [ ] **Step 10: App → agent ping (P1, part 2)**

Run: `spikes/agentd-xpc/build/Spike.app/Contents/MacOS/SpikeApp ping`
Expected: `pong from agentd pid=<n> to app`

- [ ] **Step 11: Grandchild pings (P2)**

Run:
```bash
( cd spikes/agentd-xpc
  build/Spike.app/Contents/MacOS/SpikeApp grandchild-app
  build/Spike.app/Contents/MacOS/SpikeApp grandchild-agentd
  build/Spike.app/Contents/MacOS/spike-client from-terminal )
```
Expected: three `pong from agentd …` lines, labelled `grandchild-of-app`, `grandchild-of-agentd`, `from-terminal`.

- [ ] **Step 12: Signing requirement rejects a foreign identifier (P1b)**

Run:
```bash
( cd spikes/agentd-xpc
  cp build/Spike.app/Contents/MacOS/spike-client build/rogue-client
  codesign --force --sign - --identifier dev.rogue.client build/rogue-client
  build/rogue-client rogue )
```
Expected: `ERROR: …` or `TIMEOUT` (not `pong`). If it prints `pong`, the requirement is not enforced; record FAIL for P1b.

- [ ] **Step 13: launchd restarts a killed agent (P2b)**

Run:
```bash
OLD=$(pgrep -f "Spike.app/Contents/MacOS/spike-agentd"); echo "old=$OLD"
kill -9 "$OLD"; sleep 3
NEW=$(pgrep -f "Spike.app/Contents/MacOS/spike-agentd"); echo "new=$NEW"
spikes/agentd-xpc/build/Spike.app/Contents/MacOS/SpikeApp ping
```
Expected: `new` is a different non-empty pid; ping returns `pong from agentd pid=<new>`.

- [ ] **Step 14: Write raw results**

Append each step's command and output to `spikes/results-task1.txt` (plain text). The FINDINGS file is written in Task 4.

---

### Task 2: Plugin commands, plugin MCP, hooks, PTY delivery (proofs 3, 4, 5)

**Files:**
- Create: `spikes/claude-plugin/cch-main/.claude-plugin/plugin.json`
- Create: `spikes/claude-plugin/cch-main/commands/task.md`
- Create: `spikes/claude-plugin/cch-main/commands/bugfix.md`
- Create: `spikes/claude-plugin/cch-main/commands/feature.md`
- Create: `spikes/claude-plugin/cch-main/commands/helper.md`
- Create: `spikes/claude-plugin/cch-main/.mcp.json`
- Create: `spikes/claude-plugin/cch-main/hooks/hooks.json`
- Create: `spikes/claude-plugin/bin/fake-mcp.py`
- Create: `spikes/claude-plugin/bin/hook-log.sh`
- Create: `spikes/claude-plugin/bin/stop-once.py`
- Create: `spikes/claude-plugin/ptyutil.py`
- Create: `spikes/claude-plugin/drive.py`
- Create: `spikes/claude-plugin/check.py`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: FINDINGS rows P3 (unprefixed/namespaced command resolution), P3b (`${CLAUDE_PLUGIN_ROOT}/..` paths work in `.mcp.json` and hooks), P4 (paste delivery, multi-line, mid-turn), P4b (permission Notification payload), P4c (Stop block + `stop_hook_active`), P5 (actual MCP tool name). `ptyutil.py` is reused by Task 3.

- [ ] **Step 1: Plugin manifest and commands**

`spikes/claude-plugin/cch-main/.claude-plugin/plugin.json`:

```json
{ "name": "cch-main", "version": "0.0.1", "description": "Claude Code Hub spike plugin" }
```

`spikes/claude-plugin/cch-main/commands/task.md`:

```markdown
---
description: SPIKE — spawn a Task subagent
argument-hint: <text>
---
Call the cch ping tool with text "$ARGUMENTS" and category "task". Reply with only the tool's result.
```

`spikes/claude-plugin/cch-main/commands/bugfix.md`:

```markdown
---
description: SPIKE — spawn a Bug subagent
argument-hint: <text>
---
Call the cch ping tool with text "$ARGUMENTS" and category "bug". Reply with only the tool's result.
```

`spikes/claude-plugin/cch-main/commands/feature.md`:

```markdown
---
description: SPIKE — spawn a Feature subagent
argument-hint: <text>
---
Call the cch ping tool with text "$ARGUMENTS" and category "feature". Reply with only the tool's result.
```

`spikes/claude-plugin/cch-main/commands/helper.md`:

```markdown
---
description: SPIKE — spawn a Helper subagent
argument-hint: <text>
---
Call the cch ping tool with text "$ARGUMENTS" and category "helper". Reply with only the tool's result.
```

- [ ] **Step 2: Plugin MCP config and hooks (paths deliberately go through `..`, like the real `../../../MacOS/cch-mcp`)**

`spikes/claude-plugin/cch-main/.mcp.json`:

```json
{ "mcpServers": { "cch": { "command": "${CLAUDE_PLUGIN_ROOT}/../bin/fake-mcp.py", "args": ["serve"] } } }
```

`spikes/claude-plugin/cch-main/hooks/hooks.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/../bin/hook-log.sh\" UserPromptSubmit" } ] }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/../bin/hook-log.sh\" PostToolUse" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/../bin/hook-log.sh\" Notification" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/../bin/stop-once.py\"" } ] }
    ]
  }
}
```

- [ ] **Step 3: Fake MCP server**

`spikes/claude-plugin/bin/fake-mcp.py`:

```python
#!/usr/bin/env python3
"""Minimal stdio MCP server: one `ping` tool. Logs every call and the caller's CCH_ROLE."""
import datetime
import json
import os
import sys

LOG = os.path.expanduser("~/Library/Logs/cch-spike.log")


def log(message):
    with open(LOG, "a") as f:
        f.write(f"{datetime.datetime.now()} [fake-mcp pid={os.getpid()}] {message}\n")


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


log(f"start role={os.environ.get('CCH_ROLE')} argv={sys.argv}")
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        version = msg.get("params", {}).get("protocolVersion", "2025-06-18")
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": version,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "cch", "version": "0.0.1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{
            "name": "ping",
            "description": "Spike ping. Returns the text, category and caller role.",
            "inputSchema": {"type": "object",
                            "properties": {"text": {"type": "string"}, "category": {"type": "string"}},
                            "required": ["text"]}}]}})
    elif method == "tools/call":
        args = msg.get("params", {}).get("arguments", {})
        log(f"tools/call {msg['params'].get('name')} {json.dumps(args)}")
        text = f"pong role={os.environ.get('CCH_ROLE')} category={args.get('category')} text={args.get('text')}"
        send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": text}]}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"unknown method {method}"}})
```

- [ ] **Step 4: Hook scripts**

`spikes/claude-plugin/bin/hook-log.sh`:

```bash
#!/bin/bash
payload=$(tr -d '\n')
echo "$(date '+%F %T') [hook $1] $payload" >> "$HOME/Library/Logs/cch-spike.log"
exit 0
```

`spikes/claude-plugin/bin/stop-once.py`:

```python
#!/usr/bin/env python3
"""Logs every Stop and blocks the first one per session, to prove the block/stop_hook_active contract."""
import datetime
import json
import os
import sys

payload = json.load(sys.stdin)
with open(os.path.expanduser("~/Library/Logs/cch-spike.log"), "a") as f:
    f.write(f"{datetime.datetime.now()} [hook Stop] {json.dumps(payload)}\n")

work = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "work")
os.makedirs(work, exist_ok=True)
marker = os.path.join(work, f"stop-blocked-{payload.get('session_id')}")
if not payload.get("stop_hook_active") and not os.path.exists(marker):
    open(marker, "w").close()
    print(json.dumps({"decision": "block",
                      "reason": "SPIKE: before stopping, reply with exactly the word BANANA."}))
sys.exit(0)
```

Run: `chmod +x spikes/claude-plugin/bin/*`
Expected: no output.

- [ ] **Step 5: PTY helper**

`spikes/claude-plugin/ptyutil.py`:

```python
"""Run `claude` in a real PTY, type into it, and capture ANSI-stripped output."""
import fcntl
import os
import pty
import re
import select
import signal
import struct
import termios
import time

ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-B]")


class Claude:
    def __init__(self, cwd, argv, env_extra, raw_log_path):
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
            os.chdir(cwd)
            env = dict(os.environ)
            env["TERM"] = "xterm-256color"
            env.update(env_extra)
            os.execve(argv[0], argv, env)
        self.pid, self.fd = pid, fd
        self.raw = open(raw_log_path, "wb")
        self.text = b""

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.2)
            if not ready:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return False
            if not data:
                return False
            self.raw.write(data)
            self.raw.flush()
            if b"\x1b[6n" in data:  # cursor position query
                os.write(self.fd, b"\x1b[40;1R")
            self.text += ANSI.sub(b"", data)
        return True

    def seen(self, needle):
        return needle.lower().encode() in self.text.lower()

    def paste(self, message):
        os.write(self.fd, b"\x1b[200~" + message.encode() + b"\x1b[201~")
        time.sleep(0.05)
        os.write(self.fd, b"\r")

    def key(self, data):
        os.write(self.fd, data)

    def close(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.kill(self.pid, sig)
            except ProcessLookupError:
                break
            time.sleep(1)
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        self.raw.close()
```

- [ ] **Step 6: Driver**

`spikes/claude-plugin/drive.py`:

```python
#!/usr/bin/env python3
"""Proofs 3-5: plugin commands, plugin MCP + hooks, bracketed-paste delivery incl. mid-turn and permission prompt."""
import os
import subprocess

from ptyutil import Claude

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
REPO = os.path.join(WORK, "drive-repo")
LOG = os.path.expanduser("~/Library/Logs/cch-spike.log")
CLAUDE = os.path.expanduser("~/.local/bin/claude")


def mark(label):
    with open(LOG, "a") as f:
        f.write(f"==== {label} ====\n")
    print(f"==== {label} ====", flush=True)


os.makedirs(REPO, exist_ok=True)
if not os.path.isdir(os.path.join(REPO, ".git")):
    subprocess.run(["git", "init", "-q", REPO], check=True)
    subprocess.run(["git", "-C", REPO, "commit", "-q", "--allow-empty", "-m", "init"], check=True)

argv = [CLAUDE, "--model", "haiku",
        "--plugin-dir", os.path.join(HERE, "cch-main"),
        "--allowedTools", "mcp__cch__ping", "mcp__plugin_cch-main_cch__ping", "Bash(sleep 15)"]
c = Claude(REPO, argv, {"CCH_ROLE": "main"}, os.path.join(WORK, "drive-pty.raw"))

mark("startup")
c.pump(12)
if c.seen("trust"):
    mark("trust dialog seen in drive-repo; accepting")
    c.key(b"\r")
    c.pump(6)

mark("P3 unprefixed /task")
c.paste("/task hello-unprefixed")
c.pump(45)

mark("P3 namespaced /cch-main:task")
c.paste("/cch-main:task hello-namespaced")
c.pump(45)

mark("P3 /bugfix")
c.paste("/bugfix hello-bugfix")
c.pump(45)

mark("P4 multi-line paste")
c.paste("First line of a pasted message.\nSecond line: reply with exactly the word ALPHA.")
c.pump(30)

mark("P4 mid-turn: first")
c.paste("Run the bash command `sleep 15`, then reply with exactly DONE-ONE.")
c.pump(4)
mark("P4 mid-turn: second, sent while busy")
c.paste("Reply with exactly the word QUEUED-TWO.")
c.pump(60)

mark("P4b permission prompt")
c.paste("Run the bash command `echo needs-permission` and show me its output.")
c.pump(20)
c.key(b"\x1b")  # dismiss the permission prompt
c.pump(8)

mark("end")
c.close()
print("done; now run check.py")
```

- [ ] **Step 7: Checker**

`spikes/claude-plugin/check.py`:

```python
#!/usr/bin/env python3
"""Summarise spike evidence: MCP calls, hook events, and the transcript in order."""
import json
import os
import re

LOG = os.path.expanduser("~/Library/Logs/cch-spike.log")
lines = open(LOG).read().splitlines()

print("== fake-mcp calls ==")
for line in lines:
    if "[fake-mcp" in line:
        print(line)

print("\n== hook events (event, key fields) ==")
transcript = None
for line in lines:
    m = re.search(r"\[hook (\w+)\] (\{.*\})$", line)
    if not m:
        continue
    event, payload = m.group(1), json.loads(m.group(2))
    transcript = payload.get("transcript_path", transcript)
    keep = {k: payload[k] for k in ("tool_name", "prompt", "notification_type", "message", "stop_hook_active")
            if k in payload}
    print(event, json.dumps(keep)[:300])

print("\n== transcript", transcript, "==")
if transcript and os.path.exists(transcript):
    for raw in open(transcript):
        entry = json.loads(raw)
        kind = entry.get("type")
        if kind not in ("user", "assistant"):
            continue
        content = entry.get("message", {}).get("content")
        if isinstance(content, str):
            text = content
        else:
            parts = []
            for block in content or []:
                if block.get("type") == "text":
                    parts.append(block["text"])
                elif block.get("type") == "tool_use":
                    parts.append(f"<tool_use {block.get('name')}>")
                elif block.get("type") == "tool_result":
                    parts.append("<tool_result>")
            text = " ".join(parts)
        print(f"{kind:9} {text[:160]!r}")
```

- [ ] **Step 8: Run the driver**

Run:
```bash
mv ~/Library/Logs/cch-spike.log ~/Library/Logs/cch-spike.task1.log 2>/dev/null || true   # check.py reads only this run
( cd spikes/claude-plugin && python3 drive.py && python3 check.py | tee ../results-task2.txt )
```
Expected: the driver prints its `====` markers and `done; now run check.py`; `check.py` prints three sections.

- [ ] **Step 9: Read the evidence and classify each proof**

Using `spikes/results-task2.txt`:
- **P3:** `fake-mcp calls` has `text=hello-unprefixed` → unprefixed `/task` works. `hello-namespaced` → namespaced form works. `hello-bugfix` with `category=bug` → `/bugfix` works. A missing line means that form failed.
- **P3b:** any `fake-mcp … start` line and any `[hook …]` line prove `${CLAUDE_PLUGIN_ROOT}/..` resolution for MCP and hooks respectively.
- **P5:** the `PostToolUse` events' `tool_name` for the ping call is the real prefix (e.g. `mcp__cch__ping` or `mcp__plugin_cch-main_cch__ping`). Record it verbatim.
- **P4:** the transcript has a user entry containing both "First line" and "Second line" (one prompt, not two), followed by an assistant `ALPHA`. After `DONE-ONE`'s request, a user entry "Reply with exactly the word QUEUED-TWO." appears and an assistant `QUEUED-TWO` follows. Record whether the queued message landed after `DONE-ONE` or mid-turn (between tool use and final reply).
- **P4b:** a `Notification` event exists; record its `notification_type` and `message` values verbatim.
- **P4c:** the first `Stop` event has `stop_hook_active: false`, an assistant `BANANA` follows, and a later `Stop` has `stop_hook_active: true`.

If `drive-pty.raw` is needed to debug, view it with `python3 -c "import sys,re;print(re.sub(rb'\x1b\[[0-9;?]*[ -/]*[@-~]',b'',open('spikes/claude-plugin/work/drive-pty.raw','rb').read()).decode(errors='replace'))" | less`.

---

### Task 3: Folder-trust dialog in new worktrees (proof 6)

**Files:**
- Create: `spikes/claude-plugin/trust_probe.py`

**Interfaces:**
- Consumes: `ptyutil.Claude` from Task 2.
- Produces: FINDINGS row P6 and the D4 worktree-location decision.

- [ ] **Step 1: Probe script**

`spikes/claude-plugin/trust_probe.py`:

```python
#!/usr/bin/env python3
"""Proof 6: does claude show its trust dialog in fresh worktree directories?"""
import json
import os
import shutil
import subprocess

from ptyutil import Claude

HERE = os.path.dirname(os.path.abspath(__file__))
CLAUDE = os.path.expanduser("~/.local/bin/claude")
BASE = "/private/tmp/cch-trust-probe"
REPO = os.path.join(BASE, "repo")
WT_SUPPORT = os.path.expanduser("~/Library/Application Support/ClaudeCodeHub/spike-worktrees/wt-a")
WT_REPO_LOCAL = os.path.join(REPO, ".claude", "worktrees", "wt-b")


def git(*args):
    subprocess.run(["git", *args], check=True, capture_output=True)


def trusted_ancestors(path):
    try:
        config = json.load(open(os.path.expanduser("~/.claude.json")))
    except (OSError, ValueError):
        return "unreadable"
    projects = config.get("projects", {})
    return [p for p, v in projects.items()
            if v.get("hasTrustDialogAccepted") and (path == p or path.startswith(p.rstrip("/") + "/"))]


def probe(cwd, accept):
    c = Claude(cwd, [CLAUDE, "--model", "haiku"], {}, os.path.join(HERE, "work", f"trust-{os.path.basename(cwd)}.raw"))
    c.pump(12)
    seen = c.seen("trust")
    if seen and accept:
        c.key(b"\r")
        c.pump(5)
    c.close()
    return seen


shutil.rmtree(BASE, ignore_errors=True)
shutil.rmtree(os.path.dirname(WT_SUPPORT), ignore_errors=True)
os.makedirs(REPO)
git("init", "-q", REPO)
git("-C", REPO, "commit", "-q", "--allow-empty", "-m", "init")
os.makedirs(os.path.join(HERE, "work"), exist_ok=True)

results = {"repo_trust_prompt": probe(REPO, accept=True)}
git("-C", REPO, "worktree", "add", "-q", "-b", "spike-a", WT_SUPPORT)
git("-C", REPO, "worktree", "add", "-q", "-b", "spike-b", WT_REPO_LOCAL)
results["support_dir_worktree_trust_prompt"] = probe(WT_SUPPORT, accept=False)
results["repo_local_worktree_trust_prompt"] = probe(WT_REPO_LOCAL, accept=False)
results["trusted_ancestors_support"] = trusted_ancestors(WT_SUPPORT)
results["trusted_ancestors_repo_local"] = trusted_ancestors(WT_REPO_LOCAL)
print(json.dumps(results, indent=2))
```

- [ ] **Step 2: Run it**

Run: `( cd spikes/claude-plugin && python3 trust_probe.py | tee ../results-task3.txt )`
Expected: a JSON object with three booleans and two ancestor lists.

- [ ] **Step 3: Classify**

- `repo_trust_prompt` should be `true` (fresh repo). If `false`, the detector missed the dialog: open `work/trust-repo.raw` as in Task 2 Step 9, find the dialog's wording, change `c.seen("trust")` to that wording, and rerun.
- D4 decision:
  - support dir `false` → keep D4 (Application Support).
  - support dir `true`, repo-local `false` → move worktrees to `<repo>/.claude/worktrees/<id>-<slug>`.
  - both `true` → keep D4; Phase 2 must detect the dialog and accept it before sending the brief (record the dialog wording from the raw log).
- Note any non-empty `trusted_ancestors_*` list; it means the result may be inherited from a trusted parent and not representative of other machines.

---

### Task 4: FINDINGS and cleanup

**Files:**
- Create: `spikes/FINDINGS.md`
- Modify: `docs/superpowers/specs/2026-09-14-subagents-design.md` (only the lines named in Step 2)

**Interfaces:**
- Consumes: `spikes/results-task1.txt`, `results-task2.txt`, `results-task3.txt`.
- Produces: the decisions Phase 2+ plans rely on.

- [ ] **Step 1: Write FINDINGS**

`spikes/FINDINGS.md` (fill every cell from the results files; use PASS / FAIL and paste short verbatim evidence):

```markdown
# Subagents Spike Findings — <date>

| Proof | Question | Result | Evidence |
|---|---|---|---|
| P1 | Ad-hoc bundle registers LaunchAgent via SMAppService; app reaches Mach service | | |
| P1b | setCodeSigningRequirement rejects a foreign ad-hoc identifier | | |
| P2 | Grandchild of app and of agentd reach the Mach service | | |
| P2b | launchd restarts a killed agent | | |
| P3 | `/task` unprefixed works; `/cch-main:task` works; `/bugfix` works | | |
| P3b | `${CLAUDE_PLUGIN_ROOT}/..` paths work in plugin .mcp.json and hooks | | |
| P4 | Bracketed paste + CR delivers one prompt (multi-line ok); mid-turn message is queued | | |
| P4b | Notification hook payload for permission prompts (`notification_type` value) | | |
| P4c | Stop hook block + `stop_hook_active` behave as spec §2 assumes | | |
| P5 | Exact MCP tool name for a plugin-provided server | | |
| P6 | Trust dialog in Application Support worktree / repo-local worktree | | |

## Decisions

- IPC transport: XPC Mach service (P1, P2 pass) | Unix-socket fallback (needs user approval)
- Command names: unprefixed `/task` `/bugfix` `/feature` `/helper` | namespaced `/cch-main:…`
- MCP tool prefix for allowlists and prompts: `<verbatim>`
- Worktree location (D4): Application Support | `<repo>/.claude/worktrees` | Application Support + dialog handling
- Mid-turn delivery: queued after turn | injected mid-turn
```

- [ ] **Step 2: Update the spec to match**

In `docs/superpowers/specs/2026-09-14-subagents-design.md`, replace only:
- every `mcp__cch__` with the recorded P5 prefix (if different);
- the D4 row and §3 spawn step 5 path (if P6 changed the location);
- the `/task`… command table (if only namespaced forms work);
- §1 "Fallback" paragraph → append "**Adopted**" only after the user approves it.

- [ ] **Step 3: Clean up**

Run:
```bash
spikes/agentd-xpc/build/Spike.app/Contents/MacOS/SpikeApp unregister
sleep 2; pgrep -fl spike-agentd || echo "agent gone"
git -C /private/tmp/cch-trust-probe/repo worktree remove --force "$HOME/Library/Application Support/ClaudeCodeHub/spike-worktrees/wt-a" || true
rm -rf /private/tmp/cch-trust-probe "$HOME/Library/Application Support/ClaudeCodeHub/spike-worktrees"
```
Expected: `unregistered; status=notRegistered` and `agent gone`.

- [ ] **Step 4: Hand off**

Show the user `spikes/FINDINGS.md` and stop. Phase 1 may start; Phase 2 is not planned until the user accepts the Decisions block.
