import Foundation

enum ProcessEnvironment {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// The parent environment with a usable PATH, a UTF-8 locale and a TERM, then `overrides` on top.
    static func make(
        base: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var env = base
        let existing = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        var path: [String] = []
        for entry in searchPaths + existing where !path.contains(entry) { path.append(entry) }
        env["PATH"] = path.joined(separator: ":")
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["LANG"] == nil, env["LC_ALL"] == nil, env["LC_CTYPE"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["TERM"] == nil { env["TERM"] = "dumb" }
        for (key, value) in overrides { env[key] = value }
        // Mole reads many MOLE_* switches: MOLE_DELETE_MODE=permanent, MOLE_DRY_RUN, MOLE_PURGE_YES, MOLE_TEST_*
        // and more. Any of them can change what a real run does, so every one is dropped, whether inherited from
        // whatever launched Burrow or passed in by a job. Burrow sets none of them; Mole's own defaults apply.
        for key in env.keys where key.hasPrefix(moleVariablePrefix) { env[key] = nil }
        return env
    }

    static let moleVariablePrefix = "MOLE_"
}
