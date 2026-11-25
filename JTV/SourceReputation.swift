import Foundation

/// Source reputation (DESIGN: ~/workspace/jtv-reputation/DESIGN.md §3,
/// owner system order 2026-11-25). The learned layer over JTV's
/// multi-source orderings: per-source play outcomes, persisted
/// across launches, used ONLY to reorder lists that already exist
/// — never to drop, shrink, disable or hide a source.
///
/// The unit is the PLUGIN id (debrid providers are keyed as their
/// own pseudo-ids, "debrid:<provider>"). The pattern follows the
/// Da Banh tvOS 1.7.10 reference (PlaylistStore.SourceReputation):
/// UserDefaults JSON + one NSLock + synchronous persists, fed ONLY
/// by real playback outcomes (FL-486: a probe-verified source can
/// still fail the player, so probes/verifiers never feed the tier).
///
/// Cold start / all-AVERAGE reproduces today's static orders
/// EXACTLY: the ordering key is applied as a STABLE sort, so equal
/// records keep the current order byte-for-byte.
final class SourceReputation: @unchecked Sendable {
    static let shared = SourceReputation()

    enum Tier: String {
        case good = "GOOD"
        case average = "AVERAGE"
        case bad = "BAD"

        /// Sort rank: GOOD first, BAD last.
        var rank: Int {
            switch self {
            case .good: return 0
            case .average: return 1
            case .bad: return 2
            }
        }
    }

    struct Entry: Codable {
        var playSuccesses: Int = 0
        var playFailures: Int = 0
        /// EMA (alpha 0.3) of start-to-first-frame ms over plays
        /// that reached a first frame. 0 = no sample yet.
        var firstFrameEmaMs: Double = 0
        /// EMA (alpha 0.3) of successful resolve durations.
        /// Orders WITHIN a tier only; never makes a tier.
        var resolveEmaMs: Double = 0
        var resolveFailures: Int = 0
        /// Last time this entry was touched (epoch seconds) —
        /// drives the 128-key oldest-touched eviction and the
        /// 30-day idle expiry at load.
        var lastSeen: TimeInterval = 0
    }

    private static let storeKey = "jtv-reputation"
    private static let maxKeys = 128
    private static let idleExpiry: TimeInterval = 30 * 24 * 3600
    private static let emaAlpha = 0.3

    private let lock = NSLock()
    private var entries: [String: Entry]
    /// The store this instance loaded from — persists go to the
    /// SAME store (gate fix R1: persistLocked used to write to
    /// .standard regardless of the injected store).
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Corrupt store -> empty (start with no reputation,
        // never crash on a learned one). Entries idle for more
        // than 30 days expire at load.
        var loaded: [String: Entry] = [:]
        if let data = defaults.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            loaded = decoded
        }
        let cutoff = Date().timeIntervalSince1970 - Self.idleExpiry
        loaded = loaded.filter { $0.value.lastSeen >= cutoff }
        entries = loaded
    }

    // MARK: - Recording (feeds, DESIGN §3.2)

    /// Playback success: the served stream reached its first
    /// frame. `ms` is the start-to-first-frame latency.
    func recordSuccess(key: String, firstFrameMs: Int) {
        guard !key.isEmpty else { return }
        lock.lock()
        var entry = touchLocked(key)
        entry.playSuccesses += 1
        entry.firstFrameEmaMs = Self.ema(entry.firstFrameEmaMs, sample: Double(firstFrameMs))
        entries[key] = entry
        persistLocked()
        let successes = entry.playSuccesses, failures = entry.playFailures
        lock.unlock()
        DiagLog.log("reputation", "outcome key=\(key) result=success ms=\(firstFrameMs) successes=\(successes) failures=\(failures)")
    }

    /// Playback failure: a served stream died terminally in the
    /// player (item failure / watchdog terminal — never a stall
    /// an auto-switch rescued).
    func recordFailure(key: String) {
        guard !key.isEmpty else { return }
        lock.lock()
        var entry = touchLocked(key)
        entry.playFailures += 1
        entries[key] = entry
        persistLocked()
        let successes = entry.playSuccesses, failures = entry.playFailures
        lock.unlock()
        DiagLog.log("reputation", "outcome key=\(key) result=failure successes=\(successes) failures=\(failures)")
    }

    /// Resolve stats (numbers, not tier): called from the
    /// resolveEpisode defer choke point for EVERY resolve exit.
    /// A successful resolve's ms feeds resolveEmaMs; a failed
    /// resolve counts resolveFailures. Never touches the tier.
    /// Silent — the resolve duration line already records it.
    func recordResolve(key: String, ms: Int, success: Bool) {
        guard !key.isEmpty else { return }
        lock.lock()
        var entry = touchLocked(key)
        if success {
            entry.resolveEmaMs = Self.ema(entry.resolveEmaMs, sample: Double(ms))
        } else {
            entry.resolveFailures += 1
        }
        entries[key] = entry
        persistLocked()
        lock.unlock()
    }

    // MARK: - Reads

    /// The ONE classification (reference rule): GOOD at >=3 play
    /// successes and successes >= 3x play failures; BAD mirrored;
    /// else AVERAGE. No record = AVERAGE.
    func tier(for key: String) -> Tier {
        lock.lock()
        let entry = entries[key]
        lock.unlock()
        guard let entry else { return .average }
        return Self.tier(of: entry)
    }

    private static func tier(of entry: Entry) -> Tier {
        if entry.playSuccesses >= 3, entry.playSuccesses >= 3 * entry.playFailures { return .good }
        if entry.playFailures >= 3, entry.playFailures >= 3 * entry.playSuccesses { return .bad }
        return .average
    }

    /// One-line rendering of a record for DiagLog (counts and
    /// EMAs only — no URLs, no tokens).
    func describe(key: String) -> String {
        lock.lock()
        let entry = entries[key]
        lock.unlock()
        guard let entry else { return "key=\(key) tier=AVERAGE (no record)" }
        return "key=\(key) tier=\(Self.tier(of: entry).rawValue) ok=\(entry.playSuccesses) fail=\(entry.playFailures) ffEma=\(Int(entry.firstFrameEmaMs)) resolveEma=\(Int(entry.resolveEmaMs)) resolveFail=\(entry.resolveFailures)"
    }

    /// The ordering key (DESIGN §3.1): tier, then firstFrameEmaMs
    /// when >0, then resolveEmaMs when >0. A missing EMA sorts
    /// after every measured one within the tier.
    private func orderingKey(for key: String) -> (Int, Double, Double) {
        lock.lock()
        let entry = entries[key]
        lock.unlock()
        guard let entry else { return (Tier.average.rank, .infinity, .infinity) }
        return (Self.tier(of: entry).rank,
                entry.firstFrameEmaMs > 0 ? entry.firstFrameEmaMs : .infinity,
                entry.resolveEmaMs > 0 ? entry.resolveEmaMs : .infinity)
    }

    /// REORDER ONLY (DESIGN §3.3): returns the SAME elements,
    /// stable-sorted by the ordering key — the enumerated offset
    /// tiebreak makes the stability explicit, so equal keys keep
    /// the input order exactly (the cold-start rule). When the
    /// applied order differs from the input, one DiagLog line
    /// names the surface, the resulting order, and describe() of
    /// each key whose position moved (§3.4).
    func sortedByReputation<T>(_ items: [T], surface: String, key: (T) -> String) -> [T] {
        guard items.count > 1 else { return items }
        let decorated = items.enumerated().map { (offset: $0.offset, item: $0.element, ord: orderingKey(for: key($0.element))) }
        let sorted = decorated.sorted { a, b in
            if a.ord.0 != b.ord.0 { return a.ord.0 < b.ord.0 }
            if a.ord.1 != b.ord.1 { return a.ord.1 < b.ord.1 }
            if a.ord.2 != b.ord.2 { return a.ord.2 < b.ord.2 }
            return a.offset < b.offset
        }
        let result = sorted.map { $0.item }
        let beforeKeys = items.map(key)
        let afterKeys = result.map(key)
        if afterKeys != beforeKeys {
            var moved: [String] = []
            for (index, k) in afterKeys.enumerated() where beforeKeys[index] != k && !moved.contains(k) {
                moved.append(k)
            }
            let detail = moved.map { describe(key: $0) }.joined(separator: " | ")
            DiagLog.log("reputation", "order surface=\(surface) order=\(afterKeys.joined(separator: ",")) \(detail)")
        }
        return result
    }

    // MARK: - Internals (lock held)

    private static func ema(_ current: Double, sample: Double) -> Double {
        current <= 0 ? sample : current + emaAlpha * (sample - current)
    }

    /// Fetch-or-create the entry for `key`, stamp its lastSeen,
    /// and evict the oldest-touched entries beyond the cap.
    /// The caller writes the mutated entry back and persists.
    private func touchLocked(_ key: String) -> Entry {
        var entry = entries[key] ?? Entry()
        entry.lastSeen = Date().timeIntervalSince1970
        entries[key] = entry
        if entries.count > Self.maxKeys {
            let evictable = entries.sorted { $0.value.lastSeen < $1.value.lastSeen }
            for (victim, _) in evictable where victim != key && entries.count > Self.maxKeys {
                entries[victim] = nil
            }
        }
        return entry
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storeKey)
    }
}
