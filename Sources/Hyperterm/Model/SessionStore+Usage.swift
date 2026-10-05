import Foundation

/// Usage limits only arrive with an agent's turns (Claude's statusLine, Codex's session log), so
/// the last reading is kept on disk and shown from launch instead of an empty footer.
extension SessionStore {
    private struct SavedUsage: Codable {
        var claude: RateLimits?
        var codex: RateLimits?
        var accounts: [String: RateLimits]
    }

    private static var usageFile: URL { ControlPaths.supportDirectory.appendingPathComponent("usage.json") }

    func saveUsage() {
        let saved = SavedUsage(claude: rateLimits, codex: codexRateLimits, accounts: accountLimits)
        let url = Self.usageFile
        DispatchQueue.global(qos: .utility).async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(saved) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The saved reading, aged to now, then each Codex account's newest session log, which is
    /// usually fresher and needs no turn.
    func loadUsage() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.usageFile), let saved = try? decoder.decode(SavedUsage.self, from: data) {
            if rateLimits == nil { rateLimits = saved.claude?.current() }
            if codexRateLimits == nil { codexRateLimits = saved.codex?.current() }
            for (key, limits) in saved.accounts where accountLimits[key] == nil { accountLimits[key] = limits.current() }
        }
        let accounts = AccountStore.shared.accounts(for: .codex)
        DispatchQueue.global(qos: .utility).async {
            let readings: [(String, RateLimits)] = accounts.compactMap { account in
                guard let log = CodexUsage.newestLog(in: account.homeDirectory),
                      let limits = CodexUsage.tail(of: log).flatMap({ CodexUsage.latest(in: $0) })?.limits else { return nil }
                return ("codex/\(account.id)", limits.current())
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, !readings.isEmpty else { return }
                    for (key, limits) in readings { self.accountLimits[key] = limits }
                    // The sidebar meter follows the account new Codex agents use.
                    let preferred = "codex/\(AccountStore.shared.preferredID(for: .codex))"
                    if let limits = self.accountLimits[preferred] ?? readings.first?.1 { self.codexRateLimits = limits }
                    self.saveUsage()
                }
            }
        }
    }
}
