import Foundation
// tvOS adaptation: `import UIKit` dropped — its only use was
// UIDevice (export header below), replaced with ProcessInfo.

/// In-app diagnostic log (LOG RETRIEVAL LAW, owner order
/// 2026-11-18): every build ships a way to get its log out, so
/// faults are fixed from evidence instead of blind hunting.
/// Settings → "Gửi log chẩn đoán" exports the buffer as a text
/// file through the iOS share sheet.
///
/// Design:
/// • Ring buffer of the last ~2,000 lines, in memory only. The
///   log is a debugging aid for the CURRENT session, not a
///   record — nothing is persisted to disk by the logger itself.
/// • Thread safety: a plain NSLock around every access, the same
///   pattern ImageCacheManager uses. An actor was rejected: the
///   call sites are synchronous (UIKit error surfaces, the
///   non-isolated image cache, timer closures) and forcing an
///   async hop at each one would scatter Tasks through code
///   paths that must stay exactly as they are. The class is
///   therefore `@unchecked Sendable` with ALL mutable state —
///   buffer and date formatters alike — touched only while the
///   lock is held.
/// • REDACTION (hard rule): debrid tokens, the MediaFusion
///   manifest URL and signed-URL query strings must NEVER reach
///   this buffer. Call sites log hosts and paths via
///   `urlForLog(_:)` (scheme + host + path, query and fragment
///   stripped, credentials dropped) and refer to secrets only
///   by configured yes/no. There is deliberately no API that
///   takes a raw URL.
/// • v1.22.15: hosts registered via `registerCredentialHost(_:)`
///   carry their credential in the URL PATH (the MediaFusion
///   manifest), so for those hosts `urlForLog(_:)` drops the
///   path entirely — scheme + host (+ port) + "/…" only. Every
///   non-registered host keeps the path exactly as before: the
///   route lines diagnosis depends on must not change shape.
final class DiagLog: @unchecked Sendable {
    static let shared = DiagLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 2000
    /// Hosts whose URL path carries a credential (v1.22.15, see
    /// the redaction note above). Touched only while `lock` is
    /// held, like every other piece of mutable state here.
    private var credentialHosts: Set<String> = []

    /// Formatters are created once and only ever used while
    /// `lock` is held (see append/export), so they need no
    /// synchronization of their own.
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return f
    }()

    private init() {}

    // MARK: - Logging

    static func log(_ category: String, _ message: String) {
        shared.append(category: category, message: message)
    }

    private func append(category: String, message: String) {
        lock.withLock {
            lines.append("\(timeFormatter.string(from: Date())) [\(category)] \(message)")
            if lines.count > capacity {
                lines.removeFirst(lines.count - capacity)
            }
        }
    }

    // MARK: - Export

    static func exportText() -> String {
        shared.export()
    }

    private func export() -> String {
        let (snapshot, exportedAt) = lock.withLock { (lines, exportDateFormatter.string(from: Date())) }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let header = [
            "JTV diagnostic log",
            "Exported: \(exportedAt)",
            "App: JTV \(version) (\(build))",
            // tvOS adaptation: header names tvOS; version comes
            // from ProcessInfo, not UIDevice.
            "System: tvOS \(Self.osVersionString) on \(Self.deviceModel)",
            "Lines: \(snapshot.count) (oldest first, times are local)",
            "---",
        ]
        return (header + snapshot).joined(separator: "\n") + "\n"
    }

    /// Hardware identifier (e.g. "iPhone17,2") — more useful in
    /// a log than UIDevice's marketing-free "iPhone".
    private static var deviceModel: String {
        var sys = utsname()
        uname(&sys)
        return Mirror(reflecting: sys.machine).children.reduce("") { acc, child in
            guard let byte = child.value as? Int8, byte != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(bitPattern: byte)))
        }
    }

    /// tvOS adaptation: formatted ProcessInfo OS version
    /// (e.g. "27.2.1"), replacing UIDevice.current.systemVersion.
    private static var osVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: - Redaction helper

    /// Registers a host whose URL path carries a credential
    /// (v1.22.15): `urlForLog(_:)` will return no path segments
    /// at all for it. Empty hosts are ignored; registering the
    /// same host twice is a no-op.
    static func registerCredentialHost(_ host: String) {
        guard !host.isEmpty else { return }
        shared.lock.withLock { _ = shared.credentialHosts.insert(host) }
    }

    /// The ONLY shape in which a URL may enter the log:
    /// scheme://host[:port]/path — query and fragment stripped,
    /// any embedded credentials dropped. For a host registered
    /// via `registerCredentialHost(_:)` the path is dropped too
    /// (scheme://host[:port]/…), because that path IS the
    /// credential. Non-URL targets
    /// (episode ids such as "jtvhash:…" or "jtvstreams:…")
    /// collapse to their scheme-like prefix so the payload —
    /// a hash, a signed id — is never written either.
    static func urlForLog(_ urlString: String) -> String {
        if let comps = URLComponents(string: urlString),
           let scheme = comps.scheme, let host = comps.host, !host.isEmpty {
            var out = "\(scheme)://\(host)"
            if let port = comps.port { out += ":\(port)" }
            let isCredentialHost = shared.lock.withLock { shared.credentialHosts.contains(host) }
            if isCredentialHost { return out + "/…" }
            out += comps.path
            return out
        }
        if let colon = urlString.firstIndex(of: ":") {
            return String(urlString[..<colon]) + ":…"
        }
        return "…"
    }
}
