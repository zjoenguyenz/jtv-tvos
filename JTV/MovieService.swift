import Foundation

enum MovieServiceError: Error, LocalizedError {
    case pluginUnavailable
    case noURL
    case emptyDetail
    case unresolvedEpisode
    case timedOut

    var errorDescription: String? {
        switch self {
        case .pluginUnavailable: return "Plugin chưa sẵn sàng. Hãy đồng bộ nguồn plugin trong Cài đặt."
        case .noURL: return "Plugin không tạo được link dữ liệu."
        case .emptyDetail: return "Không tải được thông tin phim."
        case .unresolvedEpisode: return "Không tìm được link phát cho tập này."
        case .timedOut: return "Lấy link quá lâu. Kiểm tra mạng/VPN rồi bấm Thử lại."
        }
    }
}

/// Resume-once box for the cancellation-responsive pre-resolve
/// join (gate fix pass, Round 1 on R2, Lens 2 F5a): whichever
/// arrives first — the warm task's completion or the joining
/// caller's cancellation — resumes the waiting continuation
/// exactly once; the loser is dropped.
private final class PrefetchJoinBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PlaybackResolution?, Never>?
    private var resumed = false

    func setContinuation(_ continuation: CheckedContinuation<PlaybackResolution?, Never>) {
        lock.lock()
        if resumed {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with value: PlaybackResolution?) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

/// Loads catalog data through the plugin contract and resolves episode
/// play targets into native streams, manga chapters or embed pages.
/// MainActor-isolated (Swift 6): it is a UI-facing store; its caches
/// were already lock-guarded, and its heavy work awaits out to
/// non-isolated helpers (Net, PluginEngine, DebridResolver).
@MainActor
final class MovieService: ObservableObject {
    let manager: PluginManager

    init(manager: PluginManager) {
        self.manager = manager
    }

    private func engine(for pluginId: String) async throws -> PluginEngine {
        guard let engine = await manager.engine(for: pluginId) else {
            throw MovieServiceError.pluginUnavailable
        }
        return engine
    }

    private func manifest(for pluginId: String) async -> PluginManifest? {
        await manager.installedPlugin(id: pluginId)?.manifest
    }

    // MARK: - Session page cache

    /// Short-TTL in-memory cache for LIST / SEARCH / DETAIL page
    /// text (v1.22): back-navigation and tab re-entry used to
    /// refetch page 1 every time (0.9–2.4 s each, measured).
    /// Playback resolution is never cached (links expire), and
    /// plugin scripts / source lists are never cached here —
    /// sync freshness is PluginManager's domain.
    private struct CachedPage { let text: String; let at: Date }
    private var pageCache: [String: CachedPage] = [:]
    private let pageCacheLock = NSLock()
    private let pageCacheTTL: TimeInterval = 60

    private func fetchPage(_ url: String) async throws -> String {
        // Swift 6: scoped withLock replaces lock()/unlock()
        // pairs in async contexts (see Cache.swift note).
        let hit = pageCacheLock.withLock { pageCache[url] }
        if let hit, Date().timeIntervalSince(hit.at) < pageCacheTTL {
            return hit.text
        }
        let text = try await Self.fetchTextWithDeadline(url)
        pageCacheLock.withLock {
            pageCache[url] = CachedPage(text: text, at: Date())
            if pageCache.count > 200 { pageCache.removeAll() }
        }
        return text
    }

    /// L-T05 guard (tvOS-only divergence from the iOS core):
    /// one page fetch gets a hard 20 s wall-clock budget.
    /// Net.fetchText's own retry policy can hold a walled or
    /// stalled host for 37 s (idle) to ~181 s (slow-drip) —
    /// tvOS has no WebView Cloudflare lane to escape into —
    /// while every healthy source in the device log lands in
    /// ~1–2 s, so the budget never fires for a working source;
    /// its retry chance inside the budget is preserved (one
    /// full 12 s attempt + backoff + a partial second attempt).
    /// On expiry the fetch task is cancelled (fetchText
    /// rethrows .cancelled immediately) and the existing
    /// MovieServiceError.timedOut surfaces to the caller's
    /// error state (Home per-section row / Browse TVErrorState).
    private static func fetchTextWithDeadline(_ url: String) async throws -> String {
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await Net.fetchText(url) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    throw MovieServiceError.timedOut
                }
                guard let value = try await group.next() else {
                    throw MovieServiceError.timedOut
                }
                group.cancelAll()
                return value
            }
        } catch {
            if let mse = error as? MovieServiceError, case .timedOut = mse {
                DiagLog.log("net", "fetch timeout host=\(URL(string: url)?.host ?? "?") budget_ms=20000")
            }
            throw error
        }
    }

    /// Embed-page shapes a parser may hand back as its final answer.
    /// Deliberately narrow: disguised stream files (.vl) and signed
    /// extension-less media URLs must NOT match.
    static func looksLikeWebPage(_ urlString: String) -> Bool {
        guard let path = URL(string: urlString)?.path.lowercased() else { return false }
        return path.contains("/e/") || path.contains("/embed") || path.contains("/play/")
            || path.hasSuffix(".html") || path.hasSuffix(".htm") || path.hasSuffix(".php")
    }

    func defaultHeaders(for pluginId: String) async -> [String: String] {
        var headers = ["User-Agent": Net.desktopUA]
        if let base = await manifest(for: pluginId)?.baseUrl, !base.isEmpty {
            headers["Referer"] = base.hasSuffix("/") ? base : base + "/"
        }
        return headers
    }

    // MARK: - Discovery

    func homeSections(pluginId: String) async -> [HomeSection] {
        guard let engine = try? await engine(for: pluginId) else { return [] }
        return await engine.homeSections()
    }

    func primaryCategories(pluginId: String) async -> [NameSlug] {
        guard let engine = try? await engine(for: pluginId) else { return [] }
        return await engine.primaryCategories()
    }

    func filterConfig(pluginId: String) async -> FilterConfig {
        guard let engine = try? await engine(for: pluginId) else { return FilterConfig() }
        return await engine.filterConfig()
    }

    // MARK: - Lists & search

    func list(pluginId: String, slug: String, filters: ListFilters, page: Int) async throws -> ListPage {
        let engine = try await engine(for: pluginId)
        guard let url = await engine.urlForList(slug: slug, filtersJson: filters.jsonString(page: page)) else {
            throw MovieServiceError.noURL
        }
        let text = try await fetchPage(url)
        return await engine.parseList(text: text)
    }

    func search(pluginId: String, keyword: String, page: Int) async throws -> ListPage {
        let engine = try await engine(for: pluginId)
        let filters = ListFilters()
        guard let url = await engine.urlForSearch(keyword: keyword, filtersJson: filters.jsonString(page: page)) else {
            throw MovieServiceError.noURL
        }
        let text = try await fetchPage(url)
        return await engine.parseSearch(text: text)
    }

    // MARK: - Filter option lists

    func categories(pluginId: String) async -> [NameSlug] {
        guard let engine = try? await engine(for: pluginId),
              let url = await engine.urlForCategories(),
              let text = try? await Net.fetchText(url) else { return [] }
        return await engine.parseCategories(text: text)
    }

    func countries(pluginId: String) async -> [NameValue] {
        guard let engine = try? await engine(for: pluginId),
              let url = await engine.urlForCountries(),
              let text = try? await Net.fetchText(url) else { return [] }
        return await engine.parseCountries(text: text)
    }

    func years(pluginId: String) async -> [NameValue] {
        guard let engine = try? await engine(for: pluginId),
              let url = await engine.urlForYears(),
              let text = try? await Net.fetchText(url) else { return [] }
        return await engine.parseYears(text: text)
    }

    // MARK: - Detail

    struct DetailBundle {
        var detail: MovieDetail
        /// Stream parsed from the detail response itself (first-episode
        /// stream for API-style plugins; may be empty).
        var detailStream: StreamInfo
    }

    /// Stage 1 only: the detail record itself. Views render this
    /// immediately, then call `detailStreams` for the source list
    /// (v1.22 progressive detail — torrenthub's stage 2 measured
    /// +713 ms serial before anything could render).
    func detailMeta(pluginId: String, movieId: String) async throws -> DetailBundle {
        // L-T04 breadcrumb D6: bracket the first plugin call of
        // the Detail-open path (urlForDetail → fn=getUrlDetail).
        DiagLog.log("detail", "meta.begin plugin=\(pluginId) movie=\(movieId)")
        let engine = try await engine(for: pluginId)
        guard let url = await engine.urlForDetail(slug: movieId) else {
            throw MovieServiceError.noURL
        }
        DiagLog.log("detail", "meta.url plugin=\(pluginId) host=\(URL(string: url)?.host ?? "?")")
        let text = try await fetchPage(url)
        async let parsedDetail = engine.parseMovieDetail(text: text, url: url)
        async let parsedStream = engine.parseStream(text: text, url: url)
        let (detail, stream) = await (parsedDetail, parsedStream)
        guard let detail else { throw MovieServiceError.emptyDetail }
        return DetailBundle(detail: detail, detailStream: stream)
    }

    /// Stage 2 for two-stage plugins (torrenthub): a meta payload's
    /// detail carries ONE placeholder episode whose id starts with
    /// "jtvstreams:" — swap the real server list in. Returns the
    /// detail unchanged for single-stage plugins or when stage 2
    /// fails. Any other plugin is unaffected: none emits the prefix.
    func detailStreams(pluginId: String, movieId: String, detail: MovieDetail) async -> MovieDetail {
        guard let placeholder = detail.servers.first?.episodes.first,
              placeholder.id.hasPrefix("jtvstreams:") else { return detail }
        // v1.22.2: stage 2 goes through the PLUGIN only — the exact
        // v1.21 path. The v1.22 native debrid-configured Torrentio
        // fetch (jtvts: episodes + resolve-link chase) was removed
        // in the same restoration as the DebridResolver chain: it
        // was never device-proven, while the plugin path was.
        guard let engine = try? await engine(for: pluginId),
              let stage2URL = await engine.urlForDetail(slug: placeholder.id),
              let stage2Text = try? await Net.fetchText(stage2URL),
              let stage2 = await engine.parseMovieDetail(text: stage2Text, url: stage2URL),
              !stage2.servers.isEmpty else { return detail }
        var resolved = detail
        resolved.servers = stage2.servers
        return await mergeMediaFusion(pluginId: pluginId, movieId: movieId, detail: resolved)
    }

    /// v1.22.5: MediaFusion merge (owner request — the same
    /// second torrent gateway the Sony app runs beside
    /// Torrentio). When the owner has pasted his MediaFusion
    /// manifest URL in Settings, a torrenthub detail for an
    /// IMDb-id title gains a "MediaFusion" server: MediaFusion
    /// answers with direct per-provider links (its responses
    /// carry no infoHash), quality-sorted like the plugin's own
    /// list. Strictly additive — no URL configured, a failed
    /// fetch, or an empty answer leaves the detail exactly as
    /// the plugin made it. The manifest URL is a bearer
    /// credential: it lives only in UserDefaults, never logged.
    func mergeMediaFusion(pluginId: String, movieId: String, detail: MovieDetail) async -> MovieDetail {
        guard pluginId == "torrenthub", movieId.hasPrefix("tt") else { return detail }
        // The manifest URL is a bearer credential: the log only
        // ever learns whether one is configured (DiagLog law).
        DiagLog.log("mediafusion", "configured=\(MediaFusion.baseURL != nil ? "yes" : "no")")
        guard let base = MediaFusion.baseURL else { return detail }
        let url = "\(base)/stream/movie/\(movieId).json"
        // v1.22.15 (B-2, H-9): was `try?` — a failed fetch was
        // silent. Identical return on failure; the catch logs
        // the error kind only (domain#code, DiagLog law).
        let text: String
        do {
            text = try await Net.fetchText(url)
        } catch {
            DiagLog.log("mediafusion", "fetch failed kind=\((error as NSError).domain)#\((error as NSError).code)")
            return detail
        }
        let episodes = MediaFusion.parseStreams(text: text)
        guard !episodes.isEmpty else {
            DiagLog.log("mediafusion", "streams=0 parse-empty")
            return detail
        }
        DiagLog.log("mediafusion", "merged streams=\(episodes.count)")
        var merged = detail
        merged.servers.append(EpisodeServer(name: "MediaFusion", episodes: episodes))
        return merged
    }

    func detail(pluginId: String, movieId: String) async throws -> DetailBundle {
        var bundle = try await detailMeta(pluginId: pluginId, movieId: movieId)
        bundle.detail = await detailStreams(pluginId: pluginId, movieId: movieId, detail: bundle.detail)
        return bundle
    }

    // MARK: - Embed prefetch (v1.22)

    /// One-shot cache for a dwell-prefetched EMBED resolution:
    /// for the sources whose chains end in the sniffing webview
    /// (123av, javhd, avdbapi), the chain itself (watch page →
    /// hops → embed page) is seconds of serial fetches that used
    /// to start at the play tap. The detail screen warms it while
    /// the user reads; the tap then consumes it. Only .embed
    /// outcomes are cached — a prefetched video URL could age,
    /// and the embed outcome is just a page URL + headers.
    private var prefetchedEmbeds: [String: (resolution: PlaybackResolution, at: Date)] = [:]
    private let prefetchLock = NSLock()

    /// L-T11 (2) in-flight dedupe (tvOS-only divergence, 1.3.0):
    /// the Detail embed warm and a Play tap for the SAME
    /// plugin+episode used to run two full resolve chains
    /// concurrently and produce two different playlists. The
    /// warm's task is registered here while it runs; a tap's
    /// resolveEpisode JOINS that task instead of starting a
    /// second chain (see the join step in resolveEpisode). The
    /// embed-chain fetch mechanics are unchanged — only the
    /// duplicate concurrent run is removed.
    private var inFlightPrefetch: [String: (token: UUID, task: Task<PlaybackResolution, Error>)] = [:]

    func prefetchEmbedResolution(_ request: PlaybackRequest) {
        let key = request.pluginId + "|" + request.episode.id
        let token = UUID()
        let task = Task<PlaybackResolution, Error> {
            try await self.resolveEpisode(request, joiningPrefetch: false)
        }
        // Gate fix pass (Round 1 on R2, Lens 2 F5b): a
        // superseded warm task is CANCELLED when its registry
        // entry is overwritten — never orphaned to run to
        // completion (and possibly race the newer chain). The
        // token-keyed watcher below already refuses to let the
        // old task evict the newer entry on its way out.
        if let superseded = inFlightPrefetch[key], superseded.token != token {
            superseded.task.cancel()
        }
        inFlightPrefetch[key] = (token, task)
        Task {
            defer {
                if inFlightPrefetch[key]?.token == token { inFlightPrefetch[key] = nil }
            }
            guard let resolution = try? await task.value,
                  case .embed = resolution else { return }
            prefetchLock.withLock { prefetchedEmbeds[key] = (resolution, Date()) }
        }
    }

    /// Cancellation-responsive join of an in-flight pre-resolve
    /// (Lens 2 F5a): races the warm task's completion against
    /// THIS caller's cancellation via withTaskCancellationHandler
    /// — on cancel, the box resumes with nil at once and the
    /// caller stops waiting (its caller-side Task.isCancelled
    /// check then throws CancellationError). The warm task is
    /// deliberately NOT cancelled: it is registry-owned and its
    /// watcher may still cache the outcome for a later tap.
    private static func joinInFlightPrefetch(
        _ task: Task<PlaybackResolution, Error>
    ) async -> PlaybackResolution? {
        let box = PrefetchJoinBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PlaybackResolution?, Never>) in
                box.setContinuation(continuation)
                Task {
                    let result = try? await task.value
                    box.resume(with: result)
                }
            }
        } onCancel: {
            box.resume(with: nil)
        }
    }

    private func consumePrefetchedEmbed(pluginId: String, target: String) -> PlaybackResolution? {
        let key = pluginId + "|" + target
        prefetchLock.lock()
        let hit = prefetchedEmbeds.removeValue(forKey: key)
        prefetchLock.unlock()
        guard let hit, Date().timeIntervalSince(hit.at) < 120 else { return nil }
        return hit.resolution
    }

    // MARK: - Playback resolution

    /// Resolves an episode tap following the plugin episode semantics:
    /// direct media -> native player; manga chapter API -> images;
    /// embed page -> plugin embed/detail parser, else webview sniffer.
    func resolveEpisode(_ request: PlaybackRequest) async throws -> PlaybackResolution {
        try await resolveEpisode(request, joiningPrefetch: true)
    }

    private func resolveEpisode(_ request: PlaybackRequest, joiningPrefetch: Bool) async throws -> PlaybackResolution {
        // v1.22.15 (B-4): register the MediaFusion credential host
        // with the logger BEFORE any line below can carry an MF
        // stream URL through urlForLog. A persisted MF episode can
        // be resumed on a cold launch without mergeMediaFusion ever
        // running in this session (DetailView stage-2 early return),
        // so the getter's registration side effect cannot be relied
        // on having happened. Reading baseURL performs it.
        _ = MediaFusion.baseURL
        // v1.22.15 (B-5, N-12): exactly one chain-duration line
        // per resolve, emitted by the defer on every exit —
        // success and throw alike. No other change here.
        let chainStart = Date()
        let pluginId = request.pluginId
        defer { DiagLog.log("resolve", "duration plugin=\(pluginId) ms=\(Int(Date().timeIntervalSince(chainStart) * 1000))") }
        let target = request.episode.id
        guard !target.isEmpty else {
            DiagLog.log("resolve", "error plugin=\(pluginId) empty target")
            throw MovieServiceError.unresolvedEpisode
        }
        // Log the target KIND and its redacted shape only — a
        // signed stream URL never enters the log (DiagLog law).
        let targetKind = target.hasPrefix("jtvhash:") ? "hash"
            : request.isManga ? "manga"
            : MediaURL.isDirectMedia(target) ? "direct" : "embed"
        DiagLog.log("resolve", "start plugin=\(pluginId) kind=\(targetKind) target=\(DiagLog.urlForLog(target))")

        if let prefetched = consumePrefetchedEmbed(pluginId: pluginId, target: target) {
            DiagLog.log("resolve", "route=embed via=prefetched")
            return prefetched
        }

        // L-T11 (2) in-flight dedupe (tvOS-only divergence,
        // 1.3.0): a Play tap that lands while Detail's embed
        // warm for the same plugin+episode is still running
        // awaits THAT chain instead of starting a second one.
        // The shared outcome is the chain's own fresh result
        // (embed outcomes are additionally cached by the warm's
        // watcher, exactly as before). A failed warm falls
        // through to this call's own chain, unchanged.
        if joiningPrefetch,
           let inFlight = inFlightPrefetch[pluginId + "|" + target] {
            DiagLog.log("resolve", "join in-flight pre-resolve plugin=\(pluginId)")
            // Gate fix pass (Round 1 on R2, Lens 2 F5a): the
            // join is CANCELLATION-RESPONSIVE — a plain
            // `try? await inFlight.task.value` kept a cancelled
            // caller (attempt superseded, cover dismissed)
            // suspended until the warm chain finished on its
            // own schedule. joinInFlightPrefetch races the
            // warm's completion against this caller's
            // cancellation; a cancelled caller stops waiting at
            // once and throws CancellationError instead of
            // falling through to a second chain. The warm task
            // itself is NOT cancelled — it belongs to the
            // registry, and its watcher may still cache an
            // embed outcome.
            if let shared = await Self.joinInFlightPrefetch(inFlight.task) {
                return shared
            }
            if Task.isCancelled { throw CancellationError() }
        }

        // Fast resume: a previously resolved direct stream.
        // (Skipped for torrenthub: debrid download links expire,
        // and re-minting one from the hash is cheap when cached.)
        if pluginId != "torrenthub", !request.knownStreamURL.isEmpty && MediaURL.isDirectMedia(request.knownStreamURL) {
            var headers = request.fallbackHeaders
            if headers.isEmpty { headers = await defaultHeaders(for: pluginId) }
            let stream = await markProxyIfNeeded(StreamInfo(url: request.knownStreamURL, headers: headers), pluginId: pluginId)
            if let fallback = await streamxxPlayerFallback(url: stream.url, headers: stream.headers) { return fallback }
            DiagLog.log("resolve", "route=video engine=\(stream.useCompatEngine ? "ksplayer" : "avplayer") via=fast-resume url=\(DiagLog.urlForLog(stream.url))")
            return .video(stream)
        }

        // Debrid torrent target (torrenthub): the episode id is an
        // info-hash, not a URL — the native debrid resolver turns
        // it into a direct file link (Real-Debrid → TorBox →
        // Premiumize), flagging containers AVPlayer cannot open
        // for the KSPlayer surface.
        if target.hasPrefix("jtvhash:") {
            let hash = String(target.dropFirst("jtvhash:".count))
            DiagLog.log("resolve", "route=debrid")
            return .video(try await DebridResolver.resolve(hash: hash))
        }

        // Direct media target.
        if MediaURL.isDirectMedia(target) {
            var headers = request.fallbackHeaders
            if headers.isEmpty { headers = await defaultHeaders(for: pluginId) }
            let stream = await markProxyIfNeeded(StreamInfo(url: target, headers: headers), pluginId: pluginId)
            if let fallback = await streamxxPlayerFallback(url: stream.url, headers: stream.headers) { return fallback }
            DiagLog.log("resolve", "route=video engine=\(stream.useCompatEngine ? "ksplayer" : "avplayer") via=direct url=\(DiagLog.urlForLog(stream.url))")
            return .video(stream)
        }

        guard let engine = try? await engine(for: pluginId) else {
            DiagLog.log("resolve", "error plugin=\(pluginId) plugin unavailable")
            throw MovieServiceError.pluginUnavailable
        }

        // Manga chapter: fetch the chapter API and parse its image list.
        if request.isManga {
            let text = try await Net.fetchText(target)
            let stream = await engine.parseStream(text: text, url: target)
            if !stream.images.isEmpty {
                var resolved = stream
                if resolved.headers.isEmpty { resolved.headers = await defaultHeaders(for: pluginId) }
                DiagLog.log("resolve", "route=manga images=\(resolved.images.count)")
                return .manga(resolved)
            }
            DiagLog.log("resolve", "error plugin=\(pluginId) manga chapter had no images")
            throw MovieServiceError.unresolvedEpisode
        }

        // NEXT-C C1 (tvOS-only divergence, 1.3.0): torrenthub
        // non-hash http(s) targets that are media by container —
        // or that live on the registered MediaFusion credential
        // host — route DIRECTLY to .video here, immediately
        // before the embed chain. On iOS these shapes are
        // covered by the WKWebView sniffer; tvOS has no webview,
        // and torrenthub's playback parsers return empty by
        // design, so the embed chain could only end at the
        // last-resort .embed error slate. The MediaFusion URL is
        // a bearer credential: this route logs kind + host ONLY,
        // never the raw episode id or URL.
        if pluginId == "torrenthub",
           target.hasPrefix("http://") || target.hasPrefix("https://"),
           let targetURL = URL(string: target) {
            let ext = targetURL.pathExtension.lowercased()
            let videoContainers: Set<String> = ["mkv", "avi", "wmv", "flv", "webm", "m2ts",
                                                "mp4", "m4v", "mov", "m3u8", "mpd", "ts"]
            let mfHost = MediaFusion.baseURL.flatMap { URL(string: $0)?.host }
            let isMFHost = mfHost != nil && targetURL.host == mfHost
            if videoContainers.contains(ext) || isMFHost {
                var headers = request.fallbackHeaders
                if headers.isEmpty { headers = await defaultHeaders(for: pluginId) }
                // useCompatEngine by DebridResolver's extension
                // rule (friendly = mp4/m4v/mov); HLS/DASH
                // playlists are AVPlayer-native, so the two
                // playlist extensions are exempted from the
                // rule's non-friendly verdict. The rule receives
                // the URL's PATH (no query string — review-gate
                // fix, 1.3.0), consistent with the container
                // classification above: a signed friendly file
                // must not be misflagged compat by its query.
                let compat = DebridResolver.needsCompatEngine(filename: targetURL.path)
                    && ext != "m3u8" && ext != "mpd"
                let raw = StreamInfo(url: target, headers: headers, useCompatEngine: compat)
                let stream = await markProxyIfNeeded(raw, pluginId: pluginId)
                DiagLog.log("resolve", "route=video via=torrent-direct kind=\(isMFHost ? "mediafusion" : "container") host=\(targetURL.host ?? "?") engine=\(stream.useCompatEngine ? "ksplayer" : "avplayer")")
                return .video(stream)
            }
        }

        // Embed chain: plugins resolve in hops — a parser returns
        // isEmbed=true plus the NEXT url (njav: watch page → /jm/ →
        // player page → signed m3u8; vlxx: a POST config; sextop1:
        // a player-API config). Follow the chain like the reference
        // resolver does: fetch each hop (POST when the config carries
        // a postBody) and re-parse, until a hop yields a direct
        // stream (isEmbed=false), an image set, or the chain runs
        // out. The old single-pass code handed the first hop's page
        // URL to AVPlayer, which failed instantly.
        var currentURL = target
        var currentHeaders = await defaultHeaders(for: pluginId)
        var payload = try await Net.fetchText(currentURL, headers: currentHeaders)
        var lastEmbedURL = target
        // Embed-chain parse budget: 4 by default (the historical
        // bound). A plugin may declare a larger need in its
        // manifest (maxChainParses — hentaihub's watch-started
        // chain needs 5); the declaration can only raise the
        // bound, never lower it, and is capped so a bad value
        // cannot stall resolution in serial fetches.
        let declaredParses = await manifest(for: pluginId)?.maxChainParses ?? 0
        let parseBudget = min(max(declaredParses, 4), 8)
        if parseBudget != 4 {
            DiagLog.log("resolve", "budget plugin=\(pluginId) parses=\(parseBudget)")
        }
        for _ in 0..<parseBudget {
            var step = await engine.parseEmbed(html: payload, url: currentURL)
            if step == nil || step?.hasPlayableURL != true {
                let parsed = await engine.parseStream(text: payload, url: currentURL)
                if parsed.hasPlayableURL || !parsed.images.isEmpty { step = parsed }
            }
            guard let step, step.hasPlayableURL || !step.images.isEmpty else { break }
            if !step.images.isEmpty {
                var resolved = step
                if resolved.headers.isEmpty { resolved.headers = currentHeaders }
                DiagLog.log("resolve", "route=manga via=embed-chain images=\(resolved.images.count)")
                return .manga(resolved)
            }
            if !step.isEmbed || MediaURL.isDirectMedia(step.url) {
                // A web page is never a video: some plugins finish
                // their chain at an embed page marked isEmbed=false
                // (javhd → cloudwish /e/…). AVPlayer fails on those
                // instantly; the sniffing webview is the right home.
                if !MediaURL.isDirectMedia(step.url), Self.looksLikeWebPage(step.url),
                   let pageURL = URL(string: step.url) {
                    var pageHeaders = step.headers
                    if pageHeaders.isEmpty { pageHeaders = currentHeaders }
                    DiagLog.log("resolve", "route=embed via=webpage url=\(DiagLog.urlForLog(step.url))")
                    return .embed(url: pageURL, headers: pageHeaders, sniffMedia: true)
                }
                var resolved = step
                if resolved.headers.isEmpty { resolved.headers = currentHeaders }
                let stream = await markProxyIfNeeded(resolved, pluginId: pluginId)
                if let fallback = await streamxxPlayerFallback(url: stream.url, headers: stream.headers) { return fallback }
                DiagLog.log("resolve", "route=video engine=\(stream.useCompatEngine ? "ksplayer" : "avplayer") via=embed-chain url=\(DiagLog.urlForLog(stream.url))")
                return .video(stream)
            }
            // Self-embed (123av's shape): the parser points back at
            // the very page we already fetched. Refetching it changes
            // nothing — hand it to the sniffing webview now, keeping
            // the plugin's step headers for the page load.
            if step.url == currentURL, let pageURL = URL(string: step.url) {
                var pageHeaders = step.headers
                if pageHeaders.isEmpty { pageHeaders = currentHeaders }
                DiagLog.log("resolve", "route=embed via=self-embed url=\(DiagLog.urlForLog(step.url))")
                return .embed(url: pageURL, headers: pageHeaders, sniffMedia: true)
            }
            // Follow the hop.
            lastEmbedURL = step.url
            currentURL = step.url
            if !step.headers.isEmpty {
                currentHeaders = (await defaultHeaders(for: pluginId)).merging(step.headers) { _, new in new }
            }
            if let body = step.postBody, !body.isEmpty {
                payload = try await Net.fetchTextPOST(currentURL, body: body, headers: currentHeaders)
            } else {
                payload = try await Net.fetchText(currentURL, headers: currentHeaders)
            }
        }

        // Last resort: open the embed in the sniffing webview.
        guard let url = URL(string: lastEmbedURL) else {
            DiagLog.log("resolve", "error plugin=\(pluginId) unresolved episode")
            throw MovieServiceError.unresolvedEpisode
        }
        DiagLog.log("resolve", "route=embed via=last-resort url=\(DiagLog.urlForLog(lastEmbedURL))")
        return .embed(url: url, headers: await defaultHeaders(for: pluginId), sniffMedia: true)
    }

    /// streamxx route decision (v1.22.11): the operator's newer
    /// uploads have NO HLS backup in the segment store, and the
    /// progressive MP4 served at their /main.m3u8 address has
    /// corrupt sample tables — measured with FFmpeg 8.1, which
    /// cannot decode a single frame ("missing mandatory atoms,
    /// broken header", "contradictionary STSC and STCO"), so no
    /// native or compat engine on the phone can play them either
    /// (the v1.22.10 KSPlayer flagging failed on the owner's
    /// device for exactly this reason). The operator's own web
    /// player at embed.streamxx.net/player/<id> DOES play the
    /// same titles (browser-verified), so a backup-less streamxx
    /// stream is handed to the webview on that player page
    /// instead of to a video surface. The hand-off is
    /// NON-SNIFFING (sniffMedia: false, round-2 review M-1):
    /// the player page loads the same broken /main.m3u8
    /// internally, and the webview's media sniffer would
    /// capture that URL and promote it to a native surface —
    /// which cannot play it — defeating the route. Left alone,
    /// the page's own player plays it in-page exactly as it
    /// does in a browser. A stream WITH a backup keeps the
    /// synthesis path: this helper returns nil and the caller
    /// proceeds to .video untouched. Never throws; any
    /// doubt → nil.
    private func streamxxPlayerFallback(url: String, headers: [String: String]) async -> PlaybackResolution? {
        guard let u = URL(string: url), let streamID = PlaylistSynthesizer.streamxxID(from: u) else { return nil }
        if await PlaylistSynthesizer.backupExists(streamID: streamID) {
            DiagLog.log("resolve", "streamxx id=\(streamID) backup=yes -> synthesis path")
            return nil
        }
        guard let playerURL = URL(string: "https://embed.streamxx.net/player/\(streamID)") else { return nil }
        DiagLog.log("resolve", "streamxx id=\(streamID) backup=no route=embed-player sniff=off url=\(DiagLog.urlForLog(playerURL.absoluteString))")
        return .embed(url: playerURL, headers: headers, sniffMedia: false)
    }

    /// Some playlists route their segments through a throwaway
    /// proxy host (streamxx's /__hls_proxy/…) that can be dead
    /// while the playlist itself still loads from an edge cache:
    /// AVPlayer then stalls on the first segment instead of
    /// failing, so the HLS-proxy rescue retry never engages. Peek
    /// at the playlist; when it uses that wrapper, mark the stream
    /// so the player starts through the rescue proxy immediately
    /// (the proxy unwraps the segment URLs itself).
    ///
    /// Film4K is marked unconditionally: its segments are fMP4
    /// files wrapped in PNG images (the TV app's v1.6.4 round
    /// closed its Film4K saga — the service itself is healthy,
    /// just slow through the tunnel, and the app's fetch layer is
    /// already patient). A wrapped segment makes AVPlayer stall
    /// rather than fail, which is exactly the case the plain-first
    /// retry cannot rescue; starting through the loader (which
    /// strips the wrappers) is the reliable order, and v1.8's
    /// proxied→plain fallback covers the reverse if ever needed.
    /// Per-host verdict cache (v1.22): the probe below downloads
    /// the whole playlist just to grep for the wrapper — measured
    /// 1.5–2.0 s on sextop1's 80 KB playlist, paid on EVERY tap for
    /// a wrapper its playlists never contain. Only the streamxx
    /// family produces the wrapper, so a host's first successful
    /// probe settles the question for the rest of the session.
    private static var proxyVerdicts: [String: Bool] = [:]
    private static let proxyVerdictLock = NSLock()

    private func markProxyIfNeeded(_ stream: StreamInfo, pluginId: String) async -> StreamInfo {
        if pluginId == "film4k", stream.url.lowercased().contains(".m3u8") {
            var marked = stream
            marked.requiresProxy = true
            return marked
        }
        // streamxx URLs return untouched (v1.22.11): their route
        // decision — synthesis when a backup exists, the
        // operator's web player when none does — is made by
        // streamxxPlayerFallback in resolveEpisode, BEFORE the
        // stream reaches a video surface. What must never happen
        // here is the generic __hls_proxy probe below: it
        // downloads the whole body as text to grep for the
        // wrapper, which on streamxx's newer uploads means
        // pulling a ~100 MB progressive MP4 down as "text" on
        // every tap — and the verdict never affected streamxx
        // playback anyway (synthesis outranks the proxy ladder).
        if let url = URL(string: stream.url), PlaylistSynthesizer.streamxxID(from: url) != nil {
            return stream
        }
        guard stream.url.lowercased().contains(".m3u8") else { return stream }
        let host = URL(string: stream.url)?.host ?? ""
        if !host.isEmpty {
            let cached = Self.proxyVerdictLock.withLock { Self.proxyVerdicts[host] }
            if let cached {
                guard cached else { return stream }
                var marked = stream
                marked.requiresProxy = true
                return marked
            }
        }
        guard let text = try? await Net.fetchText(stream.url, headers: stream.headers) else { return stream }
        let verdict = text.contains("__hls_proxy/")
        if !host.isEmpty {
            Self.proxyVerdictLock.withLock { Self.proxyVerdicts[host] = verdict }
        }
        guard verdict else { return stream }
        var marked = stream
        marked.requiresProxy = true
        return marked
    }

    /// Resolves one manga chapter (used by the reader's prev/next).
    func resolveMangaChapter(pluginId: String, episode: Episode) async throws -> StreamInfo {
        guard let engine = try? await engine(for: pluginId) else {
            throw MovieServiceError.pluginUnavailable
        }
        let text = try await Net.fetchText(episode.id)
        let stream = await engine.parseStream(text: text, url: episode.id)
        guard !stream.images.isEmpty else { throw MovieServiceError.unresolvedEpisode }
        var resolved = stream
        if resolved.headers.isEmpty { resolved.headers = await defaultHeaders(for: pluginId) }
        return resolved
    }
}

// MARK: - MediaFusion (v1.22.5)

/// Parser + settings for the owner's MediaFusion gateway. The
/// manifest URL is configured by the owner at
/// mediafusion.elfhosted.com/configure (his providers, cached
/// only) and pasted into Settings; it is a bearer credential —
/// stored only in UserDefaults, never logged, never sent
/// anywhere except the gateway itself. MediaFusion stream
/// responses carry NO infoHash: every entry is a direct
/// per-provider link, so episodes keep the URL as their id
/// (the same shape as the torrenthub plugin's direct entries).
enum MediaFusion {
    static let urlKey = "jtv_mediafusion_url"

    static var baseURL: String? {
        let stored = UserDefaults.standard.string(forKey: urlKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // tvOS adaptation (owner ruling: credentials are bundled
        // in the build): when the UserDefaults value is empty, fall
        // back to the bundled constant. A non-empty stored value
        // still wins, exactly as on iOS; nothing else changes.
        let raw = stored.isEmpty
            ? BundledSecrets.mfURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : stored
        guard !raw.isEmpty else { return nil }
        var value = raw
        if value.hasPrefix("stremio://") {
            value = "https://" + String(value.dropFirst("stremio://".count))
        }
        if value.hasSuffix("/manifest.json") {
            value = String(value.dropLast("/manifest.json".count))
        }
        if value.hasSuffix("/") { value = String(value.dropLast()) }
        guard value.hasPrefix("http") else { return nil }
        // v1.22.15 (B-4(i), H-2): register the credential
        // host with the logger so its URL paths are redacted
        // in the log. Host only — the value itself (a bearer
        // credential) never enters the log. Return unchanged.
        if let host = URLComponents(string: value)?.host, !host.isEmpty {
            DiagLog.registerCredentialHost(host)
        }
        return value
    }

    static func parseStreams(text: String) -> [Episode] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else { return [] }
        var parsed: [(episode: Episode, rank: Int, seeds: Int, sizeMB: Double)] = []
        for stream in streams {
            let name = stream["name"] as? String ?? ""
            let title = stream["title"] as? String ?? ""
            let hints = stream["behaviorHints"] as? [String: Any]
            let filename = (hints?["filename"] as? String)
                ?? title.components(separatedBy: "\n").first
                ?? ""
            let provider: String
            let lowered = name.lowercased()
            if lowered.contains("premiumize") || name.contains("PM") { provider = "PM" }
            else if lowered.contains("torbox") || name.contains("TB") { provider = "TB" }
            else if lowered.contains("real-debrid") || lowered.contains("realdebrid") || name.contains("RD") { provider = "RD" }
            else { provider = "MF" }
            let haystack = (name + " " + title + " " + filename).lowercased()
            // v1.22.8: 1440p and FHD join the 1080 tier (the plugin
            // ranks 1440p a half-step above 1080p; here the Int
            // scale ties them and the seed count decides, which is
            // the owner's stated tiebreak).
            let rank = (haystack.contains("2160") || haystack.contains("4k") || haystack.contains("uhd")) ? 4
                : (haystack.contains("1440") || haystack.contains("1080") || haystack.contains("fhd")) ? 3
                : haystack.contains("720") ? 2
                : haystack.contains("480") ? 1 : 0
            let seeds = intAfter("👤", in: title)
            let sizeMB = sizeInMB(title)
            var label = provider
            if !filename.isEmpty { label += " · " + filename }
            if sizeMB > 0 { label += " · " + formatSize(sizeMB) }
            if seeds > 0 { label += " · 👤 \(seeds)" }
            if let url = stream["url"] as? String, !url.isEmpty {
                parsed.append((Episode(id: url, name: label, slug: url), rank, seeds, sizeMB))
            } else if let hash = (stream["infoHash"] as? String)?.lowercased(), !hash.isEmpty {
                let id = "jtvhash:" + hash
                parsed.append((Episode(id: id, name: label, slug: id), rank, seeds, sizeMB))
            }
        }
        parsed.sort { a, b in
            if a.rank != b.rank { return a.rank > b.rank }
            if a.seeds != b.seeds { return a.seeds > b.seeds }
            return a.sizeMB > b.sizeMB
        }
        return parsed.prefix(15).map { $0.episode }
    }

    private static func intAfter(_ marker: String, in text: String) -> Int {
        guard let range = text.range(of: marker) else { return 0 }
        let digits = text[range.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    private static func sizeInMB(_ text: String) -> Double {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*(GB|GiB|MB|MiB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[valueRange]) else { return 0 }
        let unit = text[unitRange]
        return (unit == "GB" || unit == "GiB") ? value * 1024 : value
    }

    private static func formatSize(_ sizeMB: Double) -> String {
        sizeMB >= 1024
            ? String(format: "%.2f GB", sizeMB / 1024)
            : String(format: "%.0f MB", sizeMB)
    }
}
