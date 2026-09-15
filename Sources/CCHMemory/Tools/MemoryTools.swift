import Foundation

/// Which tools a `cch-mcp serve` instance exposes. Set per plugin through `CCH_TOOLSET`.
public enum Toolset: String, Sendable {
    /// Interactive Hub sessions and subagents.
    case main
    /// Repo sweep: read/write memories; every write is `source: code`.
    case sweep
    /// Dreaming: consolidate, supersede, bump feature versions, flag conflicts.
    case dream
    /// Documentation ingestion: every write is `source: doc`.
    case docs

    var tools: Set<String> {
        let read: Set<String> = ["memory_search", "memory_get"]
        switch self {
        case .main:
            return read.union(["memory_write", "memory_update", "memory_link", "memory_flag_conflict", "bug_open", "bug_fix",
                               "bug_learning", "bug_similar", "bug_link_regression", "log_event"])
        case .sweep:
            return read.union(["memory_write", "memory_update", "memory_link"])
        case .dream:
            return read.union(["dream_candidates", "memory_update", "memory_supersede", "memory_link", "memory_flag_conflict", "feature_bump_version"])
        case .docs:
            return read.union(["memory_write", "memory_link", "memory_flag_conflict"])
        }
    }

    /// Source forced onto writes, if any.
    var forcedSource: MemorySource? {
        switch self {
        case .sweep: return .code
        case .docs: return .doc
        case .main, .dream: return nil
        }
    }
}

public struct ToolContext {
    public let store: MemoryStore
    public let console: ConsoleLog?
    public let project: Project
    public let branch: String?
    public let sessionID: String?
    public let source: String
    public let toolset: Toolset

    public init(store: MemoryStore, console: ConsoleLog?, project: Project, branch: String?, sessionID: String?, source: String,
                toolset: Toolset = .main) {
        self.store = store
        self.console = console
        self.project = project
        self.branch = branch
        self.sessionID = sessionID
        self.source = source
        self.toolset = toolset
    }
}

/// The core-memory MCP tools (spec section 2). Pure request → text handlers, so they are
/// testable without a stdio server.
public enum MemoryTools {
    /// Claude Code names tools from a plugin-provided MCP server `mcp__plugin_<plugin>_<server>__<tool>`.
    public static let toolPrefix = "mcp__plugin_cch-main_cch__"

    private static let writableKinds = MemoryKind.allCases.filter { !$0.isFrozen }.map(\.rawValue)

    /// Tools of the main toolset.
    public static var definitions: [[String: Any]] { definitions(for: .main) }

    public static func definitions(for toolset: Toolset) -> [[String: Any]] {
        (allDefinitions + dreamDefinitions).filter { toolset.tools.contains($0["name"] as? String ?? "") }
    }

    private static var dreamDefinitions: [[String: Any]] {
        [
            tool("dream_candidates", "List memories changed since the last dream, with related memories and each feature's last recorded version. Page with offset.",
                 properties: ["offset": ["type": "integer", "minimum": 0]], required: []),
            tool("memory_supersede", "Mark a memory as replaced by another (after merging its knowledge into the kept one).",
                 properties: ["old": ["type": "string"], "kept": ["type": "string"], "reason": ["type": "string"]],
                 required: ["old", "kept", "reason"]),
            tool("feature_bump_version", "Record a new version of a feature from its current description. Conservative: only for behavior changes that matter when debugging.",
                 properties: ["feature": ["type": "string"], "reason": ["type": "string"]], required: ["feature", "reason"])
        ]
    }

    private static var allDefinitions: [[String: Any]] {
        [
            tool("memory_search", "Search this project's core memories (features, architecture, APIs, design, scripts, sessions, learnings) and bugs. Use scope 'all' to search every project.",
                 properties: [
                    "query": ["type": "string", "description": "What you are looking for, in natural language or keywords."],
                    "kinds": ["type": "array", "items": ["type": "string", "enum": MemoryKind.allCases.map(\.rawValue)], "description": "Optional kinds filter."],
                    "scope": ["type": "string", "enum": ["project", "all"], "description": "Default 'project'."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 30]
                 ], required: ["query"]),
            tool("memory_get", "Get the full text of a memory (e.g. 'M12') or bug (e.g. 'BUG-3'), with its links, feature versions and bug learnings.",
                 properties: ["id": ["type": "string", "description": "M<number> or BUG-<number>"]], required: ["id"]),
            tool("memory_write", "Record a durable core memory for this project. Duplicates are detected and the existing memory is returned.",
                 properties: [
                    "kind": ["type": "string", "enum": writableKinds],
                    "title": ["type": "string", "description": "Short, specific, searchable."],
                    "body": ["type": "string", "description": "The knowledge itself: what, where in the code, why."],
                    "source": ["type": "string", "enum": MemorySource.allCases.map(\.rawValue), "description": "code = verified in code, doc = from documentation, session = learned while working, user = the user said it. Default session."],
                    "links": ["type": "array", "items": ["type": "object", "properties": [
                        "to": ["type": "string", "description": "M<number>"],
                        "relation": ["type": "string", "enum": EdgeRelation.allCases.map(\.rawValue)]
                    ], "required": ["to", "relation"]]],
                    "file_pointer": ["type": "string", "description": "Optional path to a detailed context file."]
                 ], required: ["kind", "title", "body"]),
            tool("memory_update", "Update a mutable memory in place (not bugs or bug learnings). Does not bump feature versions.",
                 properties: [
                    "id": ["type": "string"], "title": ["type": "string"], "body": ["type": "string"],
                    "reason": ["type": "string", "description": "Why it changed."]
                 ], required: ["id", "reason"]),
            tool("memory_link", "Link two memories.",
                 properties: [
                    "from": ["type": "string"], "to": ["type": "string"],
                    "relation": ["type": "string", "enum": EdgeRelation.allCases.map(\.rawValue)]
                 ], required: ["from", "to", "relation"]),
            tool("memory_flag_conflict", "Report that two memories disagree (typically documentation vs code). Logged to the Hub console.",
                 properties: ["a": ["type": "string"], "b": ["type": "string"], "note": ["type": "string"]],
                 required: ["a", "b", "note"]),
            tool("bug_open", "Open a new bug in this project's append-only bug ledger, attached to the feature it affects.",
                 properties: [
                    "title": ["type": "string"], "symptom": ["type": "string"],
                    "feature": ["type": "string", "description": "M<number> of the affected feature memory, if known."]
                 ], required: ["title", "symptom"]),
            tool("bug_fix", "Mark an open bug fixed. Allowed once; bug history is never rewritten.",
                 properties: [
                    "bug": ["type": "string", "description": "BUG-<number>"], "root_cause": ["type": "string"],
                    "fix_summary": ["type": "string"], "commit": ["type": "string"]
                 ], required: ["bug", "root_cause", "fix_summary"]),
            tool("bug_learning", "Attach a frozen learning to a bug (what was tried, why the fix works, how to spot a regression).",
                 properties: ["bug": ["type": "string"], "text": ["type": "string"]], required: ["bug", "text"]),
            tool("bug_similar", "Find earlier bugs similar to a symptom, across feature versions — regression candidates.",
                 properties: [
                    "symptom": ["type": "string"], "feature": ["type": "string"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 20]
                 ], required: ["symptom"]),
            tool("bug_link_regression", "Record that a bug is a regression of an earlier bug.",
                 properties: ["bug": ["type": "string"], "regression_of": ["type": "string"]], required: ["bug", "regression_of"]),
            tool("log_event", "Write an entry to the Claude Code Hub debug console.",
                 properties: [
                    "domain": ["type": "string", "description": "e.g. build, tests, deploy, or your MCP's name."],
                    "severity": ["type": "string", "enum": LogSeverity.allCases.map(\.rawValue)],
                    "message": ["type": "string"], "data": ["type": "object"]
                 ], required: ["domain", "severity", "message"])
        ]
    }

    public static func call(_ name: String, arguments args: [String: Any], context ctx: ToolContext) throws -> String {
        let store = ctx.store
        let pid = ctx.project.id
        guard ctx.toolset.tools.contains(name) else {
            throw MemoryError.invalid("tool \(name) is not available in the \(ctx.toolset.rawValue) toolset")
        }
        switch name {
        case "dream_candidates":
            let offset = max(int(args, "offset") ?? 0, 0)
            let since = try store.lastDream(projectID: pid, status: "succeeded").map { $0.finishedAt ?? $0.startedAt } ?? .distantPast
            let all = try store.dreamCandidates(projectID: pid, since: since)
            let page = all.dropFirst(offset).prefix(10)
            guard !page.isEmpty else { return "No more candidates (\(all.count) total)." }
            var out = "Candidates \(offset + 1)–\(offset + page.count) of \(all.count):\n"
            for candidate in page {
                let m = candidate.memory
                out += "\n=== [M\(m.id)] \(m.kind.rawValue) · \(m.source.rawValue) · \(m.title)\n\(m.body)\n"
                if let v = candidate.lastVersion {
                    out += v.description == m.body
                        ? "Last version v\(v.version): unchanged.\n"
                        : "Last version v\(v.version) (\(v.reason)) described it as:\n\(v.description)\n"
                }
                if !candidate.related.isEmpty {
                    out += "Related:\n" + candidate.related.map {
                        "  [M\($0.id)] \($0.kind.rawValue) · \($0.source.rawValue) · \($0.title) — \(Grounding.oneLine($0.body, max: 160))"
                    }.joined(separator: "\n") + "\n"
                }
            }
            if offset + page.count < all.count { out += "\nMore: dream_candidates(offset: \(offset + page.count))" }
            return out

        case "memory_supersede":
            guard let old = parseMemoryID(try string(args, "old")), let kept = parseMemoryID(try string(args, "kept")) else {
                throw MemoryError.invalid("old and kept must be M<number>")
            }
            guard old != kept else { throw MemoryError.invalid("a memory cannot supersede itself") }
            guard let keptMemory = try store.memory(id: kept), keptMemory.projectID == pid, keptMemory.supersededBy == nil else {
                throw MemoryError.invalid("M\(kept) must be an active memory in this project")
            }
            try store.supersede(old, by: kept)
            try? ctx.console?.append(domain: "dreaming", severity: .info, source: ctx.source,
                                     message: "M\(old) superseded by M\(kept): \(try string(args, "reason"))", projectID: pid)
            return "M\(old) is now superseded by M\(kept)."

        case "feature_bump_version":
            guard let feature = parseMemoryID(try string(args, "feature")) else { throw MemoryError.invalid("feature must be M<number>") }
            let version = try store.bumpFeatureVersion(featureID: feature, reason: try string(args, "reason"))
            try? ctx.console?.append(domain: "dreaming", severity: .info, source: ctx.source,
                                     message: "M\(feature) bumped to v\(version.version): \(version.reason)", projectID: pid)
            return "M\(feature) is now v\(version.version)."

        case "memory_search":
            let query = try string(args, "query")
            let limit = min(max(int(args, "limit") ?? 10, 1), 30)
            let kinds = Set((args["kinds"] as? [String] ?? []).compactMap(MemoryKind.init(rawValue:)))
            let scopeAll = (args["scope"] as? String) == "all"
            var config = RetrievalConfig()
            config.minPromptCharacters = 1
            let items = try Retriever(store: store, config: config)
                .retrieve(prompt: query, projectIDs: scopeAll ? nil : [pid], limit: kinds.isEmpty ? limit : 30)
                .filter { item in
                    guard !kinds.isEmpty else { return true }
                    if case .memory(let m) = item.ref { return kinds.contains(m.kind) }
                    return false
                }
                .prefix(limit)
            guard !items.isEmpty else { return "No matching memories." }
            let versions = try featureVersions(for: Array(items), store: store)
            return items.map { Grounding.line(for: $0, featureVersions: versions) }.joined(separator: "\n")

        case "memory_get":
            let id = try string(args, "id")
            if let number = parseBugNumber(id) {
                guard let bug = try store.bug(projectID: pid, number: number) else { throw MemoryError.notFound("BUG-\(number)") }
                return try describe(bug: bug, store: store)
            }
            guard let mid = parseMemoryID(id), let memory = try store.memory(id: mid) else { throw MemoryError.notFound(id) }
            return try describe(memory: memory, store: store)

        case "memory_write":
            guard let kind = MemoryKind(rawValue: try string(args, "kind")), !kind.isFrozen else {
                throw MemoryError.invalid("kind must be one of: \(writableKinds.joined(separator: ", "))")
            }
            let source = ctx.toolset.forcedSource ?? (args["source"] as? String).flatMap(MemorySource.init(rawValue:)) ?? .session
            var links: [(to: Int64, relation: EdgeRelation)] = []
            for raw in args["links"] as? [[String: Any]] ?? [] {
                guard let to = (raw["to"] as? String).flatMap(parseMemoryID),
                      let relation = (raw["relation"] as? String).flatMap(EdgeRelation.init(rawValue:)) else {
                    throw MemoryError.invalid("each link needs to (M<number>) and a valid relation")
                }
                links.append((to, relation))
            }
            let result = try store.writeMemory(projectID: pid, kind: kind, title: try string(args, "title"),
                                               body: try string(args, "body"), source: source,
                                               filePointer: args["file_pointer"] as? String, branch: ctx.branch,
                                               sessionID: ctx.sessionID, links: links)
            return result.duplicate
                ? "Duplicate of existing [M\(result.memory.id)] \(result.memory.title). Use memory_update to change it."
                : "Recorded [M\(result.memory.id)] \(result.memory.kind.rawValue) · \(result.memory.title)"

        case "memory_update":
            guard let mid = parseMemoryID(try string(args, "id")) else { throw MemoryError.invalid("id must be M<number>") }
            let reason = try string(args, "reason")
            let updated = try store.updateMemory(id: mid, title: args["title"] as? String, body: args["body"] as? String)
            try? ctx.console?.append(domain: "memory", severity: .info, source: ctx.source,
                                     message: "Updated M\(mid): \(reason)", projectID: pid, sessionID: ctx.sessionID)
            return "Updated [M\(updated.id)] \(updated.title)"

        case "memory_link":
            guard let from = parseMemoryID(try string(args, "from")), let to = parseMemoryID(try string(args, "to")),
                  let relation = EdgeRelation(rawValue: try string(args, "relation")) else {
                throw MemoryError.invalid("from/to must be M<number> and relation valid")
            }
            try store.link(from: from, to: to, relation: relation)
            return "Linked M\(from) -\(relation.rawValue)-> M\(to)"

        case "memory_flag_conflict":
            let a = try string(args, "a"), b = try string(args, "b"), note = try string(args, "note")
            try ctx.console?.append(domain: "memory.conflict", severity: .warning, source: ctx.source,
                                    message: "\(a) vs \(b): \(note)", projectID: pid, sessionID: ctx.sessionID)
            return "Conflict logged to the Hub console."

        case "bug_open":
            let featureID = try (args["feature"] as? String).map { raw -> Int64 in
                guard let id = parseMemoryID(raw) else { throw MemoryError.invalid("feature must be M<number>") }
                return id
            }
            let bug = try store.openBug(projectID: pid, title: try string(args, "title"), symptom: try string(args, "symptom"),
                                        featureID: featureID, branch: ctx.branch)
            let version = bug.featureVersion.map { " (feature M\(featureID ?? 0) v\($0))" } ?? ""
            return "Opened [BUG-\(bug.number)] \(bug.title)\(version). Check bug_similar for regressions."

        case "bug_fix":
            guard let number = parseBugNumber(try string(args, "bug")) else { throw MemoryError.invalid("bug must be BUG-<number>") }
            let bug = try store.fixBug(projectID: pid, number: number, rootCause: try string(args, "root_cause"),
                                       fixSummary: try string(args, "fix_summary"), commit: args["commit"] as? String)
            return "Fixed [BUG-\(bug.number)] \(bug.title). Add what you learned with bug_learning."

        case "bug_learning":
            guard let number = parseBugNumber(try string(args, "bug")) else { throw MemoryError.invalid("bug must be BUG-<number>") }
            let memory = try store.addBugLearning(projectID: pid, number: number, text: try string(args, "text"), sessionID: ctx.sessionID)
            return "Recorded [M\(memory.id)] \(memory.title)"

        case "bug_similar":
            let symptom = try string(args, "symptom")
            let limit = min(max(int(args, "limit") ?? 5, 1), 20)
            let featureID = (args["feature"] as? String).flatMap(parseMemoryID)
            return try similarBugs(symptom: symptom, featureID: featureID, limit: limit, projectID: pid, store: store)

        case "bug_link_regression":
            guard let new = parseBugNumber(try string(args, "bug")), let old = parseBugNumber(try string(args, "regression_of")) else {
                throw MemoryError.invalid("bug and regression_of must be BUG-<number>")
            }
            try store.linkRegression(projectID: pid, newNumber: new, oldNumber: old)
            return "Linked BUG-\(new) as a regression of BUG-\(old)."

        case "log_event":
            guard let console = ctx.console else { throw MemoryError.invalid("console unavailable") }
            guard let severity = LogSeverity(rawValue: try string(args, "severity")) else {
                throw MemoryError.invalid("severity must be one of: \(LogSeverity.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            var dataJSON: String?
            if let data = args["data"], JSONSerialization.isValidJSONObject(data) {
                dataJSON = String(data: try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), encoding: .utf8)
            }
            try console.append(domain: try string(args, "domain"), severity: severity, source: ctx.source,
                               message: try string(args, "message"), projectID: pid, sessionID: ctx.sessionID, dataJSON: dataJSON)
            return "Logged."

        default:
            throw MemoryError.invalid("unknown tool \(name)")
        }
    }

    // MARK: Helpers

    public static func parseMemoryID(_ raw: String) -> Int64? {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " []")).uppercased()
        return Int64(s.hasPrefix("M") ? String(s.dropFirst()) : s)
    }

    public static func parseBugNumber(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " []")).uppercased()
        guard s.hasPrefix("BUG-") else { return nil }
        return Int(s.dropFirst(4))
    }

    static func featureVersions(for items: [RetrievedItem], store: MemoryStore) throws -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for item in items {
            if case .memory(let m) = item.ref, m.kind == .feature, let v = try store.currentFeatureVersion(featureID: m.id) {
                out[m.id] = v
            }
        }
        return out
    }

    private static func similarBugs(symptom: String, featureID: Int64?, limit: Int, projectID: Int64, store: MemoryStore) throws -> String {
        var lists: [[Int64]] = []
        if let match = FTSQuery.match(for: symptom) {
            lists.append(try store.ftsBugs(projectIDs: [projectID], match: match, limit: 20))
        }
        if let vector = store.embedder?.embed(symptom) {
            lists.append(try store.vectorBugs(projectIDs: [projectID], vector: vector, limit: 20).map(\.id))
        }
        var scores = Retriever.reciprocalRankFusion(lists)
        let bugs = try store.bugs(ids: Array(scores.keys))
        if let featureID {
            for (id, bug) in bugs where bug.featureID == featureID { scores[id, default: 0] *= 1.5 }
        }
        let ranked = scores.sorted { $0.value > $1.value }.prefix(limit).compactMap { bugs[$0.key] }
        guard !ranked.isEmpty else { return "No similar bugs." }
        return try ranked.map { bug in
            var line = Grounding.line(for: RetrievedItem(ref: .bug(bug), score: 0, viaLink: false, pinned: false), featureVersions: [:])
            if let featureID = bug.featureID, let bugVersion = bug.featureVersion,
               let current = try store.currentFeatureVersion(featureID: featureID), current != bugVersion {
                line += " (feature is now v\(current))"
            }
            return line
        }.joined(separator: "\n")
    }

    private static func describe(memory m: Memory, store: MemoryStore) throws -> String {
        var out = "[M\(m.id)] \(m.kind.rawValue) · source: \(m.source.rawValue)\nTitle: \(m.title)\n\n\(m.body)"
        if let file = m.filePointer {
            out += "\n\nContext file: \(file)"
            if let contents = try? String(contentsOfFile: file, encoding: .utf8) {
                out += "\n---\n\(String(contents.prefix(20_000)))\n---"
            }
        }
        if let by = m.supersededBy { out += "\n\nSuperseded by M\(by)." }
        let links = try store.links(of: m.id)
        if !links.isEmpty {
            let related = try store.memories(ids: links.map { $0.fromID == m.id ? $0.toID : $0.fromID })
            out += "\n\nLinks:\n" + links.map { link in
                let other = link.fromID == m.id ? link.toID : link.fromID
                let arrow = link.fromID == m.id ? "-\(link.relation.rawValue)->" : "<-\(link.relation.rawValue)-"
                return "  \(arrow) [M\(other)] \(related[other]?.title ?? "?")"
            }.joined(separator: "\n")
        }
        if m.kind == .feature {
            let versions = try store.featureVersions(featureID: m.id)
            if !versions.isEmpty {
                out += "\n\nVersions:\n" + versions.map { "  v\($0.version) (\($0.reason)): \(Grounding.oneLine($0.description, max: 200))" }.joined(separator: "\n")
            }
            let bugs = try store.bugs(featureID: m.id)
            if !bugs.isEmpty {
                out += "\n\nBugs:\n" + bugs.map { "  [BUG-\($0.number)] \($0.status.rawValue) v\($0.featureVersion ?? 0) · \($0.title)" }.joined(separator: "\n")
            }
        }
        return out
    }

    private static func describe(bug b: Bug, store: MemoryStore) throws -> String {
        var out = "[BUG-\(b.number)] \(b.status.rawValue) · \(b.title)\nSymptom: \(b.symptom)"
        if let fid = b.featureID {
            let title = try store.memory(id: fid)?.title ?? "?"
            let current = try store.currentFeatureVersion(featureID: fid)
            out += "\nFeature: [M\(fid)] \(title), fixed against v\(b.featureVersion ?? 0)" + (current.map { " (now v\($0))" } ?? "")
        }
        if let cause = b.rootCause { out += "\nRoot cause: \(cause)" }
        if let fix = b.fixSummary { out += "\nFix: \(fix)" }
        if let commit = b.commitSHA { out += "\nCommit: \(commit)" }
        let regressions = try store.regressions(ofBugID: b.id)
        if !regressions.isEmpty { out += "\nRegression of: " + regressions.map { "BUG-\($0)" }.joined(separator: ", ") }
        let learnings = try store.bugLearnings(bugID: b.id)
        if !learnings.isEmpty {
            out += "\n\nLearnings:\n" + learnings.map { "  [M\($0.id)] \($0.body)" }.joined(separator: "\n")
        }
        return out
    }

    private static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    private static func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryError.invalid("missing required argument: \(key)")
        }
        return value
    }

    private static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int { return i }
        if let d = args[key] as? Double { return Int(d) }
        if let s = args[key] as? String { return Int(s) }
        return nil
    }
}
