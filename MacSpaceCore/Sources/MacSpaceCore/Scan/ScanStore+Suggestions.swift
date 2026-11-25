/// Ready-made findings built from the safety verdicts.
extension ScanStore {
    /// Leftovers, caches and installers worth at least `SafetyRules.suggestionMinSize`, safe or
    /// caution only, in that order; empty groups are omitted. May be called mid-scan (provisional).
    public func suggestions() -> [Suggestion] {
        let home = SafetyTables.normalized(environment.home)
        let lib = home + "/Library"
        var seen = Set<NodeID>()

        func item(_ id: NodeID, reasons: Set<SafetyReason>) -> SuggestionItem? {
            let flags = tree.flags(id)
            guard !flags.contains(.removed), !flags.contains(.dataless),
                  tree.size(id) >= SafetyRules.suggestionMinSize else { return nil }
            let verdict = judged(id)
            guard verdict.level == .safe || verdict.level == .caution, reasons.contains(verdict.reason),
                  seen.insert(id).inserted else { return nil }
            return SuggestionItem(id: id, name: tree.name(id), path: tree.path(of: id),
                                  size: tree.size(id), verdict: verdict)
        }
        func children(ofFolder path: String, reasons: Set<SafetyReason>) -> [SuggestionItem] {
            guard let folder = tree.node(atPath: path) else { return [] }
            return tree.children(of: folder).compactMap { item($0, reasons: reasons) }
        }

        let leftoverReasons: Set<SafetyReason> = [.leftover, .recentLeftover, .leftoverLaunchAgent]
        let cacheReasons: Set<SafetyReason> = [.cacheOfApp, .cacheOfRunningApp, .appleCache]
        var leftovers: [SuggestionItem] = []
        for location in LibraryLocation.allCases {
            leftovers += children(ofFolder: lib + "/" + location.rawValue, reasons: leftoverReasons)
        }
        var caches = children(ofFolder: lib + "/" + LibraryLocation.caches.rawValue, reasons: cacheReasons)
        for root in SafetyTables.developerCaches(home: home) {
            guard let id = tree.node(atPath: root.path) else { continue }
            if judged(id).reason == .developerCache {
                if let found = item(id, reasons: [.developerCache]) { caches.append(found) }
            } else {
                caches += children(ofFolder: root.path, reasons: [.developerCache])
            }
        }
        let installers = installerIDs.compactMap { item($0, reasons: [.installer]) }

        return [(SuggestionKind.leftovers, leftovers), (.caches, caches), (.installers, installers)]
            .filter { !$0.1.isEmpty }
            .map { Suggestion(kind: $0.0, items: $0.1) }
    }
}
