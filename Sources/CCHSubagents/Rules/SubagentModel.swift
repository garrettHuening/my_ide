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
