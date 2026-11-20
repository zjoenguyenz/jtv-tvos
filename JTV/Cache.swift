import Foundation
import SwiftUI
import UIKit
import CryptoKit

// MARK: - Networking

enum Net {
    static let defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024)
        config.httpMaximumConnectionsPerHost = 12
        return URLSession(configuration: config)
    }()

    static func makeRequest(url: URL, headers: [String: String] = [:], referer: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue(defaultUA, forHTTPHeaderField: "User-Agent")
        if let referer, !referer.isEmpty {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// Cloudflare's JS challenge ("Just a moment…") is served with a
    /// 403/503 (rarely a 200 interstitial). Ordinary Cloudflare pages
    /// also carry challenge-platform scripts, so the body marker alone
    /// is not enough — status or the interstitial title must agree.
    static func isCloudflareChallenge(_ text: String, status: Int) -> Bool {
        let t = text.lowercased()
        if t.contains("<title>just a moment") { return true }
        if status == 403 || status == 503 {
            return t.contains("just a moment")
                || t.contains("challenge-platform")
                || t.contains("challenges.cloudflare.com")
        }
        return false
    }

    /// Marker check for rendered DOM coming back from the WebView
    /// fetcher (no HTTP status available there).
    static func isChallengeHTML(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("<title>just a moment") || t.contains("challenges.cloudflare.com")
    }

    static func fetchText(_ urlString: String, headers: [String: String] = [:]) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        // Up to 3 attempts with a short backoff: the VPN tunnel path can
        // drop or garble a first response (-1011), a retry usually lands.
        // v1.22: a hard 4xx (except 429) is NOT retried — the old
        // policy burned ~61 s on failures that could never succeed —
        // and the per-attempt timeout drops to 12 s.
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            var attemptStatus = 0
            do {
                var req = makeRequest(url: url, headers: headers)
                req.timeoutInterval = 12
                let (data, response) = try await session.data(for: req)
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                attemptStatus = status
                if isCloudflareChallenge(text, status: status) {
                    // tvOS adaptation: there is no WebView
                    // Cloudflare lane on tvOS (that class does
                    // not exist in this copy) — a challenged
                    // fetch fails this attempt and the plain
                    // retry/backoff path below applies, exactly
                    // as it does for any other failed attempt.
                    throw URLError(.badServerResponse)
                }
                if !(200...299).contains(status) {
                    throw URLError(.badServerResponse)
                }
                // tvOS adaptation: the forced nhplayer WebView
                // detour (v1.22.13/v1.22.14 in the iOS original)
                // does not exist on tvOS — those resources behave
                // as a normal fetch and the plain body is returned.
                return text
            } catch {
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                if (400..<500).contains(attemptStatus), attemptStatus != 429 { throw lastError }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }

    // tvOS adaptation: the post-detour plain-retry helper and
    // the forced-detour resource predicate from the iOS original
    // are removed — both existed only to serve the WebView
    // Cloudflare lane, which does not exist on tvOS.

    /// POST variant for plugin hop configs that carry a postBody
    /// (e.g. vlxx's /ajax.php player call). Same retry policy.
    static func fetchTextPOST(_ urlString: String, body: String, headers: [String: String] = [:]) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            var attemptStatus = 0
            do {
                var req = makeRequest(url: url, headers: headers)
                req.httpMethod = "POST"
                req.timeoutInterval = 12
                if req.value(forHTTPHeaderField: "Content-Type") == nil {
                    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                }
                req.httpBody = body.data(using: .utf8)
                let (data, response) = try await session.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                attemptStatus = status
                if !(200...299).contains(status) {
                    throw URLError(.badServerResponse)
                }
                return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            } catch {
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                if (400..<500).contains(attemptStatus), attemptStatus != 429 { throw lastError }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }

    static func fetchData(_ urlString: String, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        // v1.22: same retry policy as fetchText (was: zero retries).
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            do {
                return try await session.data(for: makeRequest(url: url, headers: headers)).0
            } catch {
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }
}

// MARK: - WebView fetcher — absent on tvOS (adaptation)
//
// tvOS adaptation: the iOS WebView fetcher class (an off-screen
// WKWebView Cloudflare-challenge lane) does not exist in this
// copy at all. Fetches degrade to the plain URLSession paths:
// Net.fetchText uses its normal retry path, and the image
// cache fetches bytes directly.

// MARK: - Image cache

final class ImageCacheManager: @unchecked Sendable {
    static let shared = ImageCacheManager()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()
    /// v1.22 disk tier (~300 MB, LRU by modification date): every
    /// cold launch used to re-download every poster — the memory
    /// cache alone could not survive a relaunch.
    private let diskDir: URL
    private let diskCap = 300 * 1024 * 1024

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 256 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("jtv-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        let dir = diskDir, cap = diskCap
        Task.detached { Self.pruneDisk(dir: dir, cap: cap) }
    }

    private func diskURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(digest)
    }

    private static func pruneDisk(dir: URL, cap: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var total = 0
        var sized: [(url: URL, size: Int, date: Date)] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            total += size
            sized.append((entry, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > cap else { return }
        for entry in sized.sorted(by: { $0.date < $1.date }) {
            if total <= cap { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Real memory cost of a decoded bitmap. The old accounting
    /// used the COMPRESSED byte count, so the 256 MB cap was
    /// fictitious — decoded posters run 5–15× their file size.
    private func decodedCost(_ image: UIImage) -> Int {
        Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }

    /// Caps pathological decodes (4K backdrops) at a 2048 px long
    /// edge; normal posters and manga pages pass through untouched.
    /// A reading page or strip is NEVER capped: its short edge is
    /// the reading width (a SayHentai strip runs ~720 x 10000), and
    /// capping the long edge crushed one to ~147 px wide — the
    /// owner-reported "very blurry" pages of 2026-11-18, which the
    /// plugin's HD files never caused. Only an image large in BOTH
    /// dimensions (a backdrop, a photo) is capped. The disk tier
    /// stores the original bytes, so this fix also heals chapters
    /// already cached on the device.
    private func capped(_ image: UIImage) -> UIImage {
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let longest = max(pixelW, pixelH)
        guard longest > 2048 else { return image }
        guard min(pixelW, pixelH) > 1080 else { return image }
        let ratio = 2048 / longest
        let target = CGSize(width: pixelW * ratio, height: pixelH * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func key(for url: String, headers: [String: String]) -> String {
        if headers.isEmpty { return url }
        let suffix = headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return url + "|" + suffix
    }

    func cachedImage(for urlString: String, headers: [String: String] = [:]) -> UIImage? {
        cache.object(forKey: key(for: urlString, headers: headers) as NSString)
    }

    func loadImage(urlString: String, headers: [String: String] = [:]) async -> UIImage? {
        let k = key(for: urlString, headers: headers)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        guard let url = URL(string: urlString) else { return nil }

        // Swift 6: NSLock.lock()/unlock() are unavailable in
        // async contexts; scoped withLock is the sanctioned
        // form. The check-and-set MUST stay inside ONE critical
        // section — the pre-migration code held the lock across
        // the check, the Task creation and the registration,
        // and splitting that into two sections (an earlier
        // conversion did) loses the dedupe guarantee: two
        // concurrent calls could both miss the check and both
        // fetch, and a finishing task's cleanup could clear a
        // successor's registration. So the task is created AND
        // registered inside a single withLock section that
        // returns it; the section itself never awaits.
        let task: Task<UIImage?, Never> = lock.withLock {
            if let existing = inFlight[k] { return existing }
            let created = Task<UIImage?, Never> {
                defer {
                    self.lock.withLock { self.inFlight[k] = nil }
                }
                // Disk tier first: decode + promote to memory.
                let disk = self.diskURL(for: k)
                if let data = try? Data(contentsOf: disk), let image = UIImage(data: data) {
                    let cappedImage = self.capped(image)
                    self.cache.setObject(cappedImage, forKey: k as NSString, cost: self.decodedCost(cappedImage))
                    return cappedImage
                }
                guard let data = await self.fetchBytes(url: url, headers: headers),
                      let image = UIImage(data: data) else { return nil }
                try? data.write(to: disk, options: .atomic)
                let cappedImage = self.capped(image)
                self.cache.setObject(cappedImage, forKey: k as NSString, cost: self.decodedCost(cappedImage))
                return cappedImage
            }
            inFlight[k] = created
            return created
        }
        return await task.value
    }

    /// tvOS adaptation: plain fetch only. The iOS original's
    /// WebView fallback ladder (clear the host's wall in a web
    /// view, retry direct, then pull the bytes out of the web
    /// view) is dropped — no such lane exists on tvOS. A
    /// response that does not decode as an image fails,
    /// exactly as ordinary failures (404, dead host, timeout)
    /// always did.
    private func fetchBytes(url: URL, headers: [String: String]) async -> Data? {
        // Some hosts (sayhentai.cx's /storage/ covers, measured
        // 2026-11-18) refuse image requests that arrive with no
        // Referer at all — Cloudflare serves its hard block page
        // even to Safari on a direct image navigation, while the
        // same image loads fine inside the site's own pages. A
        // browser loading an image embedded in a page sends that
        // page as the Referer; with no caller-supplied Referer,
        // send the image host's own root — the closest equivalent
        // (the site's pages are the only referrers these images
        // ever legitimately have). Callers that pass an explicit
        // Referer (the manga reader) keep theirs.
        var hdrs = headers
        if !hdrs.keys.contains(where: { $0.lowercased() == "referer" }), let host = url.host, !host.isEmpty {
            hdrs["Referer"] = "\(url.scheme ?? "https")://\(host)/"
        }
        var req = Net.makeRequest(url: url, headers: hdrs)
        req.timeoutInterval = 30
        guard let (data, _) = try? await Net.session.data(for: req) else { return nil }
        if UIImage(data: data) != nil { return data }
        // Log the HOST only (DiagLog law — never the signed/
        // full URL) so a dead or walled image host stays
        // diagnosable from the exported log.
        DiagLog.log("image", "fetch failed host=\(url.host ?? "?")")
        return nil
    }

    /// Warms memory/disk for images about to be scrolled into
    /// (rails after a section lands, the manga reader's next
    /// pages). Deduped against the cache and in-flight loads.
    func prefetch(urlStrings: [String], headers: [String: String] = [:]) {
        for urlString in urlStrings.prefix(60) {
            if cachedImage(for: urlString, headers: headers) != nil { continue }
            Task { _ = await self.loadImage(urlString: urlString, headers: headers) }
        }
    }

    func clear() {
        cache.removeAllObjects()
        // v1.22.15 (F-2): the Settings action ("Xoá bộ nhớ đệm
        // ảnh") now tells the truth — it also empties the disk
        // tier, not just the memory tier. Synchronous on purpose: clear() is
        // an explicit user action and the disk directory is
        // empty when it returns.
        if let entries = try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: nil) {
            for entry in entries {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}

/// Async image view backed by ImageCacheManager (supports custom headers,
/// e.g. the Referer manga CDNs require).
struct CachedAsyncImage: View {
    let urlString: String
    var headers: [String: String] = [:]
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    /// v1.22.15 (F-1): the task identity MUST match
    /// ImageCacheManager.key(for:headers:) — the URL alone
    /// when headers is empty, else the URL + "|" + the
    /// headers sorted by key as "k=v" joined by "&" — so the
    /// view reloads exactly when the manager's cache entry
    /// would differ (a same-URL/different-headers request is
    /// a different image to the manager, and now to the view).
    private var identity: String {
        if headers.isEmpty { return urlString }
        let suffix = headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return urlString + "|" + suffix
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.white.opacity(0.25))
                    }
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .overlay { ProgressView().tint(.white.opacity(0.5)) }
            }
        }
        .task(id: identity) {
            image = nil
            failed = false
            if let cached = ImageCacheManager.shared.cachedImage(for: urlString, headers: headers) {
                image = cached
                return
            }
            let loaded = await ImageCacheManager.shared.loadImage(urlString: urlString, headers: headers)
            if let loaded { image = loaded } else { failed = true }
        }
    }
}

// MARK: - Haptics

/// tvOS adaptation: no-op stub with the SAME public API as the
/// iOS original (tap / select / success). tvOS has no haptic
/// feedback generators, so every existing call site compiles
/// unchanged and simply does nothing on TV.
enum Haptics {
    static func tap() {}

    static func select() {}

    static func success() {}
}
