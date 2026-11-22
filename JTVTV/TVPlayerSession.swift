import Foundation
import SwiftUI

/// JTV tvOS Phase 3 — the player session owner (plan §3.1).
///
/// One session per presented player cover. It holds the current
/// `PlaybackRequest`, the monotonic `attemptID`, the current
/// resolution/stream, the live position, the user's manual
/// subtitle selection (session state, §4.4) and the §6
/// instrumentation timestamps. It owns resolve calls
/// (`MovieService.resolveEpisode` — protected machinery, called
/// never modified), surface routing (§3.2), source switching
/// (§5), history writes and `PinSession.setPlaybackActive(_:)`
/// at present/dismiss.
///
/// Attempt-scoping is total (FL-041/FL-044): every async
/// callback — resolve completions, item-ready, first-frame,
/// failure, watchdog — carries the attemptID that created it
/// and is dropped whole when stale.
///
/// Swift 6: the session is @MainActor; no lock is ever taken
/// from an async context; hosts hop to the main actor before
/// calling in.

// MARK: - Shared resume rule (§5.2 — ONE definition, both surfaces)

/// The shared resume rule (FL-204/FL-205): seek ONCE, when the
/// new item is ready, only if the recorded target > 5 s, with
/// zero tolerance, and play only when the seek completion
/// reports `finished == true`. The same rule serves
/// Detail-initiated resume (`startPosition` on the request) and
/// switch-resume (the live-captured target) — the hosts perform
/// the surface-specific seek, this type owns the constants and
/// the decision, and both hosts report the outcome back through
/// `TVPlayerSession.noteResumeSeek(attempt:target:finished:)`.
enum TVResumeRule {
    /// Targets at or below this many seconds are not seeked —
    /// playback simply starts (and no resume.seek line is
    /// emitted, because no seek happened).
    static let minimumTarget: Double = 5

    static func shouldSeek(_ target: Double) -> Bool {
        target.isFinite && target > minimumTarget
    }
}

// MARK: - Routing (§3.2)

enum TVSurfaceRoute: Equatable {
    case av
    case ks
    case proxy
}

// MARK: - Failure slate (§3.5)

struct TVPlayerFailure: Equatable {
    enum Stage: Equatable {
        case resolve
        case load
        case watchdog
        case embed
    }

    let stage: Stage
    /// Designed, user-readable message (never a raw error).
    let message: String
    /// `domain#code` of the underlying error, when one exists.
    let errorLabel: String?

    var stageToken: String {
        switch stage {
        case .resolve: return "resolve"
        case .load: return "load"
        case .watchdog: return "load"
        case .embed: return "load"
        }
    }
}

// MARK: - Phase

enum TVPlayerPhase {
    case resolving
    case playing(route: TVSurfaceRoute, attempt: Int)
    case manga(StreamInfo)
    case failed(TVPlayerFailure)
}

// MARK: - Panels (owned here so Menu arbitration has one source)

enum TVPlayerPanel: Equatable {
    case subtitles
    case sources
    /// NEXT-B (1.3.0): the manga reader's chapter-end bar. It is
    /// a session panel so the cover's single Menu arbiter closes
    /// it first, exactly like the other panels (FL-048).
    case mangaChapterEnd
}

// MARK: - Session

@MainActor
final class TVPlayerSession: ObservableObject {

    // Dependencies (all created once by TVRootView and handed
    // down — the session creates nothing of its own).
    private let service: MovieService
    private let history: WatchHistoryManager
    private let pinSession: PinSession
    private let onDismiss: () -> Void

    /// The request currently being played. Source switches swap
    /// its episode in place (the iOS C-3 shape: only `episode`
    /// changes; movie/plugin/server context ride unchanged).
    @Published private(set) var currentRequest: PlaybackRequest

    // MARK: Provider switch (L-T13, 1.3.1)

    /// One provider switch row for a torrent (hash) title:
    /// session-computed data ONLY (DIAG-131-SWITCH §5.2(6)) —
    /// Models.swift stays byte-identical.
    struct ProviderRow: Identifiable, Equatable {
        let provider: DebridResolver.Provider
        var state: DebridResolver.CacheState
        var id: String { "provider-" + provider.rawValue }
        var title: String { "\(provider.displayName) · \(state.rowLabel)" }
    }

    /// Live provider rows for the current hash title (empty for
    /// non-torrent titles). Seeded as `.checking` at start and
    /// published when `DebridResolver.probeAll` lands;
    /// not-configured providers are filtered out.
    @Published private(set) var providerRows: [ProviderRow] = []
    /// The provider the user pinned via a provider switch, if
    /// any. nil = the resolver's automatic pick (the default
    /// `DebridResolver.resolve(hash:)` path, unchanged).
    private(set) var forcedProvider: DebridResolver.Provider?
    private var providerProbeTask: Task<Void, Never>?

    // MARK: Auto source selection (L-T23, 1.3.3; L-T30, 1.3.4 — multi-server titles, verified episode correspondence)

    /// Measured scores from attempt 1's selection pass
    /// (episode id → resolve + first-byte milliseconds). An
    /// auto-switch may only ever target a source measured
    /// here: the owner's rule is "switch to a MEASURED-better
    /// source", never to an unmeasured guess.
    private var measuredSourceScores: [String: Int] = [:]
    /// Auto selection is live for this session: a title
    /// started on the default pick, measured at attempt 1.
    private var autoSourceMode = false
    /// Any manual source/provider pick by the viewer disables
    /// every automatic source action for the rest of the
    /// session — the viewer's choice is respected absolutely.
    private var manualSourceChosen = false
    /// Episodes that already had an attempt this session; an
    /// auto-switch never revisits one.
    private var triedSourceIDs: Set<String> = []
    /// Set by start() when attempt 1's resolve must run the
    /// measurement pass; consumed by the first beginAttempt.
    private var autoMeasurePending = false
    /// Gate fix (Round 1, Lens C C-1): whether this session
    /// was started on the detail's DEFAULT pick — decided by
    /// TVDetailView (the first non-empty server's first
    /// episode, the Play button's target) and handed over via
    /// TVAutoMeasureArming + TVPlayerView.init, because
    /// PlaybackRequest is shared core and must not grow a
    /// TV-only field. The session itself cannot derive it:
    /// the request's allEpisodes is the STARTED server's list
    /// whichever server that was, so an episode-id comparison
    /// cannot tell a default start from a deliberate pick of
    /// another server's first episode.
    private let autoMeasureArmed: Bool
    /// Auto-switches performed this session (hard cap — no
    /// ping-ponging between sources).
    private var autoSwitchCount = 0

    /// Candidates measured per selection pass (serial — the
    /// plugin engine serialises JS per plugin, so a parallel
    /// race would measure queue wait, not source speed).
    private static let autoMeasureCandidateCap = 5
    /// Wall-clock ceiling for the whole measurement pass,
    /// checked between candidates; a single candidate is
    /// bounded by the core chains' own budgets and by the
    /// session's existing 45 s resolve deadline.
    private static let autoMeasureTotalBudget: TimeInterval = 10
    /// Score penalty when a resolved URL refuses the
    /// first-byte probe (some hosts reject Range requests
    /// but still play): the candidate stays eligible, ranked
    /// behind every cleanly probed one at equal resolve time.
    private static let autoProbePenaltyMs = 3000
    private static let autoSwitchCap = 2

    /// The current title is a torrent hash title (the only
    /// shape a provider switch can steer).
    var isTorrentHashTitle: Bool {
        currentRequest.pluginId == "torrenthub"
            && currentRequest.episode.id.hasPrefix("jtvhash:")
    }

    /// Any switch surface has something to show: episode
    /// variants beyond the current one, OR at least two
    /// configured provider rows for a hash title.
    var hasSwitchRows: Bool {
        switchTargets.count > 1 || providerRows.count > 1
    }

    // NEXT-B (1.3.0) reader accessors: the manga reader is a
    // child of this session and needs the service (chapter
    // resolves run INSIDE the reader, never through
    // beginAttempt/switchSource) and the history manager (it
    // writes its own image-index records; the session's
    // notePosition/flushHistory are seconds-shaped and must
    // never be fed manga indices). Internal reads only — the
    // stored properties stay private.
    var mangaService: MovieService { service }
    var mangaHistory: WatchHistoryManager { history }
    /// The stream the current attempt resolved to (video only).
    @Published private(set) var currentStream: StreamInfo?
    @Published private(set) var phase: TVPlayerPhase = .resolving
    /// Whichever panel is up over the player, if any. Menu
    /// arbitration (§3.3) reads exactly this.
    @Published var presentedPanel: TVPlayerPanel?
    /// The selected sidecar file track, when the AV surface's
    /// cue overlay must render it (§4.2). Always nil on the KS
    /// surface — the KS layer renders file tracks itself.
    @Published private(set) var activeFileTrack: SubtitleTrack?
    /// Live playhead, published for the AV cue overlay. Hosts
    /// update it through `notePosition(attempt:position:duration:)`.
    @Published private(set) var currentPosition: Double = 0
    /// The embedded-track catalogue the active host discovered
    /// (drives the shared subtitle panel's rows).
    @Published private(set) var subtitleCatalog = TVSubtitleCatalog()
    /// What is actually selected right now (the default rule's
    /// pick, or the user's manual pick once made).
    @Published private(set) var effectiveChoice: TVSubtitleChoice = .off

    /// Sidecar cue store for the AV overlay (fetch + parse).
    let fileSubtitles = TVFileSubtitleStore()

    // Attempt state.
    private(set) var attemptID = 0
    /// The recorded seek target for the current attempt (§5.1
    /// step 2): set at attempt start from the request's
    /// startPosition or from the live capture at a switch tap.
    /// Remembered, never re-derived afterwards (FL-041/FL-209).
    private(set) var recordedSeekTarget: Double = 0
    private var resolveTask: Task<Void, Never>?
    private var resolveTimeoutTask: Task<Void, Never>?
    /// A2: the streamxx native-lane extraction task for the
    /// current attempt (cancelled with every new attempt).
    private var streamxxLaneTask: Task<Void, Never>?
    private var started = false

    // Instrumentation timestamps (§6).
    private var tapDate: Date?
    private var attemptStartDate: Date?
    private var resolveDoneDate: Date?
    private var firstFrameLogged = false

    // Live position (history + switch capture fallback).
    private var livePosition: Double = 0
    private var liveDuration: Double = 0

    // Subtitle session state (§4.4): the user's manual pick.
    // nil = the user has not chosen — the default rule applies.
    private(set) var manualChoice: TVSubtitleChoice?

    /// L-T11 (3) (1.3.0): set by TVPlayerSessionView the first
    /// time its body runs, so the cover.sessionview.body
    /// breadcrumb is first-only instead of one line per
    /// re-render.
    var sessionViewBodyLogged = false

    // Host registrations (attempt-scoped; a stale host's
    // deregistration must not clear the live host's handlers).
    private var registeredAttempt = 0
    private var positionProvider: (@MainActor () -> Double)?
    private var subtitleApplier: (@MainActor (TVSubtitleChoice) -> TVSubtitleChoice)?

    init(request: PlaybackRequest,
         service: MovieService,
         history: WatchHistoryManager,
         pinSession: PinSession,
         autoMeasureArmed: Bool,
         onDismiss: @escaping () -> Void) {
        // L-T04 probe breadcrumbs P2/P3: bracket session
        // construction (the shared segment's first hand-off).
        DiagLog.log("player", "session.init.begin plugin=\(request.pluginId)")
        self.currentRequest = request
        self.service = service
        self.history = history
        self.pinSession = pinSession
        self.autoMeasureArmed = autoMeasureArmed
        self.onDismiss = onDismiss
        DiagLog.log("player", "session.init.done")
    }

    // MARK: Lifecycle

    /// Called once from the cover's onAppear. Logs the §6 tap
    /// line (the session's birth — Detail stays untouched, per
    /// the plan's preference) and starts the first attempt.
    func start() {
        guard !isStopped else { return }
        guard !started else { return }
        started = true
        pinSession.setPlaybackActive(true)
        tapDate = Date()
        DiagLog.log("player", "tap attempt=1 plugin=\(currentRequest.pluginId) server=\(currentRequest.serverName)")
        // L-T13 §5.0 breadcrumb: the counts the next device log
        // needs to convict the switch surfaces' inputs.
        DiagLog.log("player", "switch.targets count=\(switchTargets.count) plugin=\(currentRequest.pluginId) episodes=\(currentRequest.allEpisodes.count) switchList=\(currentRequest.switchList.count) torrentHash=\(isTorrentHashTitle ? 1 : 0)")
        // L-T23 (1.3.3) + L-T30 (1.3.4): measured
        // auto-selection arms for a session started on the
        // detail's DEFAULT pick (autoMeasureArmed — Detail
        // arms only the Play button's target, the first
        // non-empty server's first episode) when alternative
        // sources exist. 1.3.3 armed javhd only; the owner's
        // L-T30 ruling ("Khi mở bất kỳ phim nào nó chạy bản
        // nguồn trước mới chạy phim. Chỉ chọn ngầm thôi") arms
        // EVERY plugin whose Detail built candidates (the
        // cross-server correspondents in switchList).
        // torrenthub stays out: its switchList is the panel
        // shortlist, its source choice is the provider
        // machinery, and measuring its hash episodes through
        // resolveEpisode could start debrid downloads. Manga
        // stays out: chapters are not sources. A session
        // started on any other episode — a chip tap on another
        // server, a history resume on another server — is the
        // viewer's deliberate pick: never measured, never
        // overridden (gate Round 1, Lens C C-1).
        autoMeasurePending = autoMeasureArmed
            && currentRequest.pluginId != "torrenthub"
            && !currentRequest.isManga
            && !autoSourceCandidates().isEmpty
        autoSourceMode = autoMeasurePending
        triedSourceIDs.insert(currentRequest.episode.id)
        startProviderProbeIfNeeded()
        beginAttempt(resumeTarget: currentRequest.startPosition)
    }

    /// L-T13: for a hash title, seed the provider rows as
    /// `.checking` and probe every provider's cache state OFF
    /// the resolve critical path (the Phase-1 probe shape —
    /// probe-only, never a download). Rows publish when ready.
    private func startProviderProbeIfNeeded() {
        guard isTorrentHashTitle, providerRows.isEmpty else { return }
        providerRows = DebridResolver.Provider.allCases.map {
            ProviderRow(provider: $0, state: .checking)
        }
        // Gate fix pass (F-B2): the probe's IDENTITY — the exact
        // episode id (hash) it was started for — is captured
        // here and re-checked at publish time, so a completion
        // that outlived its episode can never publish the old
        // episode's rows onto the new one.
        let probedEpisodeID = currentRequest.episode.id
        let hash = String(probedEpisodeID.dropFirst("jtvhash:".count))
        providerProbeTask?.cancel()
        providerProbeTask = Task { [weak self] in
            let probes = await DebridResolver.probeAll(hash: hash)
            guard let self, !Task.isCancelled, !self.isStopped else { return }
            guard self.currentRequest.episode.id == probedEpisodeID else {
                DiagLog.log("player", "switch.providers dropped stale probe for superseded episode")
                return
            }
            self.providerRows = probes
                .filter { $0.state != .notConfigured }
                .map { ProviderRow(provider: $0.provider, state: $0.state) }
            let summary = self.providerRows.map { "\($0.provider.logToken)=\($0.state.logToken)" }.joined(separator: " ")
            DiagLog.log("player", "switch.providers \(summary)")
        }
    }

    /// Called from the cover's onDisappear: playback no longer
    /// counts as activity, the final position is flushed to
    /// history, and every in-flight task is cancelled.
    /// Gate fix pass (Round 1 on R2, Lens 2 F1/F3): set by
    /// stop() — a stopped session is terminal and must never
    /// be handed out again by TVPlayerSessionReuse.
    private(set) var isStopped = false

    func stop() {
        pinSession.setPlaybackActive(false)
        flushHistory()
        // Invalidate the attempt BEFORE cancelling the tasks:
        // bumping attemptID makes every attempt-scoped publish
        // guard (resolveSucceeded/resolveFailed, embedSlate,
        // streamxx lane, itemFailed, watchdogFailed, position
        // and subtitle funnels) fail for any completion that
        // lands after teardown, so nothing can publish
        // .failed/.playing/slate into a dismissed cover.
        attemptID += 1
        isStopped = true
        // A stopped session leaves the reuse registry at once
        // (instance-matched clear — TVPlayerView, Lens 2 F3),
        // so no later cover evaluation can resurrect it.
        TVPlayerSessionReuse.clear(session: self)
        resolveTask?.cancel()
        resolveTask = nil
        resolveTimeoutTask?.cancel()
        resolveTimeoutTask = nil
        streamxxLaneTask?.cancel()
        streamxxLaneTask = nil
        providerProbeTask?.cancel()
        providerProbeTask = nil
        positionProvider = nil
        subtitleApplier = nil
    }

    func dismiss() {
        onDismiss()
    }

    // MARK: Attempts & resolve

    private func beginAttempt(resumeTarget: Double) {
        guard !isStopped else { return }
        attemptID += 1
        let attempt = attemptID
        recordedSeekTarget = resumeTarget
        attemptStartDate = Date()
        resolveDoneDate = nil
        firstFrameLogged = false
        currentStream = nil
        activeFileTrack = nil
        subtitleCatalog = TVSubtitleCatalog()
        // Nothing is selected on the new surface yet: the
        // panel must not present the PREVIOUS attempt's
        // selection as current in the window before this
        // attempt's directive lands. (manualChoice is NOT
        // reset — it is the stored pick the directive
        // re-applies, FL-049.)
        effectiveChoice = .off
        livePosition = 0
        liveDuration = 0
        phase = .resolving
        // A new attempt supersedes the old host entirely; its
        // registrations die with it (the new host re-registers).
        registeredAttempt = attempt
        positionProvider = nil
        subtitleApplier = nil

        // A new attempt supersedes the old one: cancel its
        // resolve and its deadline before reassigning either,
        // so a stale completion or a stale timeout can never
        // land on this attempt (their attempt guards are the
        // second layer of the same rule).
        resolveTask?.cancel()
        resolveTimeoutTask?.cancel()
        resolveTimeoutTask = nil
        streamxxLaneTask?.cancel()
        streamxxLaneTask = nil

        DiagLog.log("player", "resolve.begin attempt=\(attempt)")
        let request = currentRequest
        // L-T13: a user-pinned provider steers a hash title's
        // resolve through DebridResolver.resolve(hash:provider:)
        // ONLY; every other attempt (including the unpinned
        // first attempt) uses the existing service path,
        // byte-for-byte in effect.
        let pinned = forcedProvider
        let pinnedHash: String? = (pinned != nil && request.episode.id.hasPrefix("jtvhash:"))
            ? String(request.episode.id.dropFirst("jtvhash:".count)) : nil
        // L-T30 torrent extension (owner ruling 2026-11-22
        // 16:10 CST): an UNPINNED hash attempt is the silent
        // auto-pick — DebridResolver.resolve(hash:) probes the
        // providers in priority order (TorBox → Real-Debrid →
        // Premiumize) and the first CACHED provider serves;
        // a probe error counts as unavailable (RD's
        // disabled_endpoint 403 → probe-error), ranking that
        // provider out of the cached phase; nobody cached →
        // the download flows run in the same priority order.
        // No provider surface precedes playback (the loading
        // state carries no source list for hash titles —
        // TVPlayerView), and a manual in-player provider pick
        // (the pinned path above) remains the only override.
        if pinned == nil, isTorrentHashTitle {
            DiagLog.log("player", "providers auto-pick attempt=\(attempt) mode=silent order=torbox>rd>premiumize rule=cached-first probe-error-excluded")
        }
        // L-T23 (1.3.3): attempt 1 of an auto-selection
        // session resolves through the measurement pass
        // instead (its winner's resolution is reused — no
        // double resolve). Consumed here so retries and
        // switches always take the plain path.
        let measure = autoMeasurePending
        autoMeasurePending = false
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolution: PlaybackResolution
                if let pinned, let pinnedHash {
                    DiagLog.log("player", "resolve.provider attempt=\(attempt) provider=\(pinned.logToken)")
                    resolution = .video(try await DebridResolver.resolve(hash: pinnedHash, provider: pinned))
                } else if measure {
                    // A nil return means the pass found itself
                    // superseded mid-measurement (gate Round 1,
                    // Lens B F-B1): the session has moved on to
                    // a newer attempt, so this task ends
                    // silently — no publish, no failure slate.
                    guard let measured = try await self.resolveWithMeasurement(attempt: attempt)
                    else { return }
                    resolution = measured
                } else {
                    resolution = try await self.service.resolveEpisode(request)
                }
                self.resolveSucceeded(attempt: attempt, resolution: resolution)
            } catch {
                self.resolveFailed(attempt: attempt, error: error)
            }
        }
        // Resolve deadline (FL-005/FL-152): non-torrent attempts
        // get a session-level ceiling, so no resolve can spin
        // forever without reaching the error slate (§3.5's
        // "no silent infinite loading"). Non-torrent attempts
        // keep the iOS resolver's 45 s.
        //
        // NEXT-C C2 (1.3.0, iOS parity): TORRENT targets
        // (pluginId == "torrenthub") are EXEMPT from the session
        // deadline entirely — iOS exempts torrent episodes from
        // its screen deadline because the debrid chain carries
        // its own per-provider budgets (900 s) and a server-side
        // download legitimately takes minutes. The old tvOS
        // 120 s ceiling for `jtvhash:` attempts false-failed
        // uncached torrents (120 s ≪ the chain's budget). The
        // loading state carries the source-switch list (C3), so
        // the exempt wait is never a trap.
        if request.pluginId != "torrenthub" {
            resolveTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard let self, !Task.isCancelled else { return }
                guard self.attemptID == attempt, case .resolving = self.phase else { return }
                DiagLog.log("player", "fail attempt=\(attempt) stage=resolve error=player#timeout")
                self.phase = .failed(TVPlayerFailure(
                    stage: .resolve,
                    message: "Không tải được nguồn phát. Kiểm tra mạng rồi thử lại.",
                    errorLabel: "player#timeout"))
            }
        }
    }

    // MARK: Measured source selection (L-T23, 1.3.3)

    /// The alternative sources for auto selection, in
    /// measurement-priority order: the request's switchList
    /// as built by Detail (javhd: other servers' first
    /// episodes — the family representatives — then the
    /// current server's other mirrors, then the rest; every
    /// other multi-server plugin, L-T30: the started
    /// episode's correspondent on each other server),
    /// deduped, the started episode excluded.
    private func autoSourceCandidates() -> [Episode] {
        var seen: Set<String> = [currentRequest.episode.id]
        var result: [Episode] = []
        for episode in currentRequest.switchList
        where seen.insert(episode.id).inserted {
            result.append(episode)
        }
        return result
    }

    /// Attempt 1's resolve for an auto-selection session:
    /// measure the candidates SERIALLY (the plugin engine
    /// serialises JS per plugin — a parallel race would time
    /// the queue, not the sources), score each by resolve
    /// time + first-byte time of its resolved URL, and return
    /// the best candidate's resolution for the attempt to
    /// play. The resolve machinery itself is only ever CALLED
    /// (MovieService.resolveEpisode), never modified. A
    /// candidate that errors, resolves to a non-video shape
    /// (an embed cannot be probed and would slate anyway), or
    /// falls outside the total budget is simply unmeasured —
    /// and unmeasured sources are never auto-selected. If
    /// every candidate fails, the started candidate's own
    /// error is thrown, so the attempt lands on exactly the
    /// failure path a plain resolve would have produced.
    ///
    /// Gate fix (Round 1, Lens B F-B1): the pass QUIESCES
    /// the moment its attempt is superseded (a switch, retry
    /// or dismiss bumps attemptID and cancels this task). The
    /// validity check runs at every candidate boundary, after
    /// every await, and in the error path; a superseded pass
    /// returns nil at once — it issues no further resolves
    /// through the serialised plugin engine (which would
    /// contend with the live attempt's resolve) and writes no
    /// scores. The caller treats nil as "the session moved
    /// on" and ends the task silently.
    private func resolveWithMeasurement(attempt: Int) async throws -> PlaybackResolution? {
        let started = currentRequest
        let candidates = [started.episode] + autoSourceCandidates()
        let deadline = Date().addingTimeInterval(Self.autoMeasureTotalBudget)
        var best: (episode: Episode, resolution: PlaybackResolution, score: Int)?
        var startedError: Error?
        // F-B1: superseded = this task was cancelled, a newer
        // attempt owns the session, or the session stopped.
        func superseded() -> Bool {
            Task.isCancelled || attempt != attemptID || isStopped
        }
        for (index, episode) in candidates.prefix(Self.autoMeasureCandidateCap).enumerated() {
            if superseded() {
                DiagLog.log("player", "autosource.measure stop=superseded measured=\(index)")
                return nil
            }
            if index > 0, Date() >= deadline {
                DiagLog.log("player", "autosource.measure stop=budget measured=\(index)")
                break
            }
            var req = started
            req.episode = episode
            if episode.id != started.episode.id {
                // The fast-resume URL belongs to the started
                // episode only — never offer it for another
                // source's resolve.
                req.knownStreamURL = ""
            }
            let host = URL(string: episode.id)?.host ?? "?"
            let t0 = Date()
            do {
                let resolution = try await service.resolveEpisode(req)
                // F-B1: the resolve could not be cancelled
                // mid-flight (the plugin bridge has no cancel
                // seam) — if the attempt died while it ran, its
                // result is discarded here, unscored.
                if superseded() {
                    DiagLog.log("player", "autosource.measure stop=superseded measured=\(index)")
                    return nil
                }
                let resolveMs = Int(Date().timeIntervalSince(t0) * 1000)
                guard case .video(let stream) = resolution else {
                    DiagLog.log("player", "autosource.measure name=\(episode.name) host=\(host) outcome=not-video")
                    continue
                }
                var score = resolveMs
                if let streamURL = URL(string: stream.url),
                   let ttfb = await TVSourceProbe.timeToFirstByte(
                    url: streamURL, headers: stream.headers) {
                    score += ttfb
                    DiagLog.log("player", "autosource.measure name=\(episode.name) host=\(host) resolve=\(resolveMs) ttfb=\(ttfb) score=\(score)")
                } else {
                    score += Self.autoProbePenaltyMs
                    DiagLog.log("player", "autosource.measure name=\(episode.name) host=\(host) resolve=\(resolveMs) ttfb=-1 score=\(score)")
                }
                // F-B1: no score write from a superseded pass —
                // the table belongs to the live session only.
                if superseded() {
                    DiagLog.log("player", "autosource.measure stop=superseded measured=\(index)")
                    return nil
                }
                measuredSourceScores[episode.id] = score
                if best == nil || score < best!.score {
                    best = (episode, resolution, score)
                }
            } catch {
                // F-B1: an error landing after supersede is
                // not evidence about any live source — drop it.
                if superseded() {
                    DiagLog.log("player", "autosource.measure stop=superseded measured=\(index)")
                    return nil
                }
                if episode.id == started.episode.id { startedError = error }
                DiagLog.log("player", "autosource.measure name=\(episode.name) host=\(host) outcome=error kind=\(Self.errorLabel(error))")
            }
        }
        guard let best else {
            throw startedError ?? MovieServiceError.timedOut
        }
        // A superseded attempt publishes nothing and swaps
        // nothing: nil, and the caller ends the task silently
        // (resolveSucceeded's own guard is the second layer).
        if superseded() {
            DiagLog.log("player", "autosource.measure stop=superseded stage=publish")
            return nil
        }
        if best.episode.id != started.episode.id {
            DiagLog.log("player", "autosource.pick name=\(best.episode.name) host=\(URL(string: best.episode.id)?.host ?? "?") score=\(best.score) from=\(started.episode.name)")
            currentRequest.episode = best.episode
            triedSourceIDs.insert(best.episode.id)
        } else {
            DiagLog.log("player", "autosource.pick name=\(best.episode.name) score=\(best.score) kept=1")
        }
        return best.resolution
    }

    /// The best MEASURED source that has not had an attempt
    /// yet — the only legal auto-switch target. Nil when auto
    /// selection is off, the viewer has taken manual control,
    /// the switch cap is reached, or nothing measured
    /// remains.
    private func nextAutoSourceCandidate() -> Episode? {
        guard autoSourceMode, !manualSourceChosen,
              autoSwitchCount < Self.autoSwitchCap else { return nil }
        var bestID: String?
        var bestScore = Int.max
        for (episodeID, score) in measuredSourceScores
        where !triedSourceIDs.contains(episodeID) && score < bestScore {
            bestID = episodeID
            bestScore = score
        }
        guard let bestID else { return nil }
        return autoSourceCandidates().first { $0.id == bestID }
            ?? (currentRequest.allEpisodes.first { $0.id == bestID })
    }

    private func resolveSucceeded(attempt: Int, resolution: PlaybackResolution) {
        guard attempt == attemptID, case .resolving = phase else { return }
        resolveTimeoutTask?.cancel()
        resolveTimeoutTask = nil
        let done = Date()
        resolveDoneDate = done
        let ms = Int(done.timeIntervalSince(attemptStartDate ?? done) * 1000)
        switch resolution {
        case .video(let stream):
            currentStream = stream
            let route: TVSurfaceRoute
            let token: String
            if stream.useCompatEngine {
                route = .ks
                token = "ks"
            } else if stream.requiresProxy {
                route = .proxy
                token = "proxy"
            } else {
                route = .av
                token = "av"
            }
            // L-T04 probe breadcrumb P7 (extends the §6 line):
            // route + stream host (host only — redaction-safe)
            // + proxy flag, so the AV fork is named in the log.
            let streamHost = URLComponents(string: stream.url)?.host ?? "?"
            DiagLog.log("player", "resolve.done attempt=\(attempt) ms=\(ms) route=\(token) host=\(streamHost) proxy=\(route == .proxy ? 1 : 0)")
            phase = .playing(route: route, attempt: attempt)
        case .manga(let stream):
            currentStream = stream
            DiagLog.log("player", "resolve.done attempt=\(attempt) ms=\(ms) route=manga")
            phase = .manga(stream)
        case .embed(let url, let headers, let sniffMedia):
            // A2 (1.3.0, NEXT-A2 study §3.2): the UNIQUE
            // streamxx signature — sniffMedia == false AND the
            // embed.streamxx.net/player/<id> URL — is produced
            // only by MovieService.streamxxPlayerFallback's
            // backup=no branch. That route gets ONE native-lane
            // attempt (plain fetch + EMBED_CONFIG parse, its own
            // ~10 s budget) before the slate. Every other .embed
            // outcome keeps today's slate exactly. Prefetched
            // embeds arrive through this same point — no bypass.
            if !sniffMedia, url.host == "embed.streamxx.net",
               url.path.hasPrefix("/player/") {
                DiagLog.log("player", "resolve.done attempt=\(attempt) ms=\(ms) route=embed via=streamxx-player")
                startStreamxxLane(attempt: attempt, url: url, headers: headers)
            } else {
                embedSlate(attempt: attempt, ms: ms)
            }
        }
    }

    /// The designed .embed error slate (§3.5) — no webview
    /// exists on tvOS (gaps G-2/G-3), never a black trap. Shared
    /// by the plain .embed outcome and by A2 lane failures.
    private func embedSlate(attempt: Int, ms: Int) {
        guard attempt == attemptID, case .resolving = phase else { return }
        DiagLog.log("player", "resolve.done attempt=\(attempt) ms=\(ms) route=embed")
        phase = .failed(TVPlayerFailure(
            stage: .embed,
            message: "Nguồn này cần trình phát web, chưa hỗ trợ trên TV. Hãy đổi nguồn khác.",
            errorLabel: nil))
    }

    // MARK: A2 — streamxx native lane (NEXT-A2 §2.3/§3.2)

    /// One extraction attempt for a backup-less streamxx title:
    /// plain-fetch the operator's player page and read the
    /// unsigned direct MP4 URL out of its static inline
    /// EMBED_CONFIG (`hls_url`, fallback `storage_url`). The
    /// embed host's own /stream/<id>/main.m3u8 copy is
    /// newline-corrupted in transit and is NEVER used. On
    /// success the stream re-enters this session's own .video
    /// path with useCompatEngine = true, so it routes to the
    /// KS surface exactly like a resolved compat stream (the
    /// B2 object is h264+aac per the study's ffprobe evidence).
    ///
    /// Budget: resolveSucceeded has already cancelled the
    /// resolve deadline, so the lane carries its OWN ~10 s
    /// budget (task-group race, the MovieService
    /// fetchTextWithDeadline shape). Timeout / fetch failure /
    /// parse failure / invalid URL → the designed slate plus a
    /// distinct DiagLog line — never a crash, never a hang.
    /// Logs carry kind + host only (house style).
    private func startStreamxxLane(attempt: Int, url: URL, headers: [String: String]) {
        streamxxLaneTask?.cancel()
        streamxxLaneTask = Task { [weak self] in
            guard let self else { return }
            let page: String
            do {
                page = try await Self.fetchTextWithBudget(url.absoluteString, headers: headers, seconds: 10)
            } catch {
                self.streamxxLaneFailed(attempt: attempt, reason: "fetch")
                return
            }
            let extraction = Self.streamxxMediaURL(from: page)
            guard let mediaURL = extraction.url else {
                DiagLog.log("player", "streamxx-lane parse-detail \(extraction.diagnostics) pageBytes=\(page.utf8.count)")
                self.streamxxLaneFailed(attempt: attempt, reason: "parse")
                return
            }
            DiagLog.log("player", "streamxx-lane extracted host=\(mediaURL.host ?? "?")")
            let stream = StreamInfo(url: mediaURL.absoluteString, headers: headers,
                                    useCompatEngine: true)
            self.resolveSucceeded(attempt: attempt, resolution: .video(stream))
        }
    }

    private func streamxxLaneFailed(attempt: Int, reason: String) {
        guard attempt == attemptID, case .resolving = phase else { return }
        DiagLog.log("player", "streamxx-lane failed reason=\(reason)")
        embedSlate(attempt: attempt, ms: 0)
    }

    /// Task-group race giving a fetch a hard wall-clock budget;
    /// on expiry the fetch is cancelled and the call throws.
    private static func fetchTextWithBudget(_ url: String, headers: [String: String],
                                            seconds: Double) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await Net.fetchText(url, headers: headers) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MovieServiceError.timedOut
            }
            guard let value = try await group.next() else {
                throw MovieServiceError.timedOut
            }
            group.cancelAll()
            return value
        }
    }

    /// Extracts the playable media URL from the player
    /// page's inline EMBED_CONFIG. L-T10 hardening (1.3.2):
    /// the 1.3.0 rule (FIRST occurrence of hls_url/storage_url
    /// only, https + Backblaze-B2 host + .mp4 suffix or
    /// nothing) failed on device (log_9: reason=parse) on a
    /// title whose VM-fetched page had the standard shape —
    /// the device-served page evidently varies in a dimension
    /// the old gates rejected, and iOS has no such gates at
    /// all (it lets the page's own JS read the config). The
    /// scan now: starts at the EMBED_CONFIG block, walks the
    /// key ladder hls_url → storage_url → cdn_streaming_url →
    /// cdn_embed_url, tries EVERY assignment of each key, and
    /// accepts any https URL whose path ends in .mp4 (first
    /// preference, the proven B2 shape) or .m3u8 (fallback) —
    /// the KS surface remains the playback boundary, not a
    /// host allowlist. On failure the returned diagnostics
    /// name, per key, what was found (host + suffix class),
    /// so the next device log convicts the exact gate.
    private static func streamxxMediaURL(from page: String) -> (url: URL?, diagnostics: String) {
        let region: String
        if let cfg = page.range(of: "EMBED_CONFIG") {
            region = String(page[cfg.lowerBound...])
        } else {
            region = page
        }
        var diag: [String] = []
        var hlsCandidate: URL?
        for key in ["hls_url", "storage_url", "cdn_streaming_url", "cdn_embed_url"] {
            let values = embedConfigValues(in: region, key: key)
            var found = "absent"
            for raw in values {
                guard let url = URL(string: raw), url.scheme == "https",
                      let host = url.host else { continue }
                let path = url.path.lowercased()
                if path.hasSuffix(".mp4") {
                    return (url, "")
                }
                if path.hasSuffix(".m3u8") {
                    found = "\(host)/m3u8"
                    if hlsCandidate == nil { hlsCandidate = url }
                } else {
                    found = "\(host)/other"
                }
            }
            diag.append("\(key)=\(found)")
        }
        if let hlsCandidate {
            return (hlsCandidate, "")
        }
        return (nil, diag.joined(separator: " "))
    }

    /// Every string value assigned to `key` in the page, in
    /// page order (plain string scan — no JS, no JSON parse
    /// of the whole page, whose other fields are not
    /// guaranteed JSON-clean). Tolerates quoted or bare keys;
    /// a null / non-string assignment is skipped rather than
    /// swallowing the next quoted token (the old single-value
    /// reader's corruption shape). `\/` escapes are
    /// unescaped.
    private static func embedConfigValues(in page: String, key: String) -> [String] {
        var values: [String] = []
        var cursor = page.startIndex
        while let hit = page.range(of: key, range: cursor..<page.endIndex) {
            cursor = hit.upperBound
            var i = hit.upperBound
            while i < page.endIndex, page[i] == "\"" || page[i] == " " || page[i] == "\t" {
                i = page.index(after: i)
            }
            guard i < page.endIndex, page[i] == ":" else { continue }
            i = page.index(after: i)
            while i < page.endIndex, page[i] == " " || page[i] == "\t" || page[i] == "\n" || page[i] == "\r" {
                i = page.index(after: i)
            }
            guard i < page.endIndex, page[i] == "\"" else { continue }
            let start = page.index(after: i)
            guard let close = page.range(of: "\"", range: start..<page.endIndex) else { break }
            let raw = String(page[start..<close.lowerBound])
            let value = raw.replacingOccurrences(of: "\\/", with: "/")
            if !value.isEmpty { values.append(value) }
            cursor = close.upperBound
        }
        return values
    }

    private func resolveFailed(attempt: Int, error: Error) {
        guard attempt == attemptID, case .resolving = phase else { return }
        resolveTimeoutTask?.cancel()
        resolveTimeoutTask = nil
        let label = Self.errorLabel(error)
        DiagLog.log("player", "fail attempt=\(attempt) stage=resolve error=\(label)")
        phase = .failed(TVPlayerFailure(
            stage: .resolve,
            message: "Không tải được nguồn phát. Kiểm tra mạng rồi thử lại.",
            errorLabel: label))
    }

    /// Thử lại (§3.5): same attempt inputs, new attempt. The
    /// resume target is the live position when a host still has
    /// one, else the current attempt's recorded target.
    func retry() {
        guard !isStopped else { return }
        let captured = captureLivePosition()
        beginAttempt(resumeTarget: captured > 0 ? captured : recordedSeekTarget)
    }

    // MARK: Source switching (§5)

    /// Switch targets: the torrenthub shortlist when present
    /// (its episodes ARE the cross-server sources), else the
    /// current server's episode list (the iOS rule).
    /// L-T23 (1.3.3) + L-T30 (1.3.4): for every non-torrent
    /// plugin the switchList carries AUTO-SELECTION candidates
    /// (see autoSourceCandidates), not panel rows — the panel
    /// keeps showing the current server's episodes for every
    /// non-torrent plugin, exactly as before.
    var switchTargets: [Episode] {
        if currentRequest.pluginId == "torrenthub",
           !currentRequest.switchList.isEmpty {
            return currentRequest.switchList
        }
        let list = currentRequest.allEpisodes
        return list.isEmpty ? [currentRequest.episode] : list
    }

    var hasSwitchTargets: Bool { switchTargets.count > 1 }

    /// Switch entry used by surfaces that capture the playhead
    /// themselves at the tap (the AV transport menu reads
    /// `player.currentTime()` synchronously in its action).
    func switchSource(to episode: Episode, capturedPosition: Double?) {
        performSwitch(to: episode, captured: capturedPosition ?? captureLivePosition())
    }

    /// Switch entry for surfaces whose live clock the session
    /// reads through the registered position provider (the KS
    /// host / the SwiftUI source panel) — the provider reads
    /// the engine's clock synchronously at this call, which IS
    /// the tap moment (FL-041/FL-209).
    func switchSource(to episode: Episode) {
        performSwitch(to: episode, captured: captureLivePosition())
    }

    /// `auto` marks the L-T23 auto-switch path (1.3.3): every
    /// OTHER call is a manual viewer pick and permanently
    /// disables auto selection for the session.
    private func performSwitch(to episode: Episode, captured: Double, auto: Bool = false) {
        guard !isStopped else { return }
        guard episode.id != currentRequest.episode.id else { return }
        if !auto { manualSourceChosen = true }
        triedSourceIDs.insert(episode.id)
        let from = currentRequest.episode.name
        // The switch line names the NEW attempt (beginAttempt
        // increments to exactly this number).
        DiagLog.log("player", "switch attempt=\(attemptID + 1) from=\(from) to=\(episode.name) captured=\(Self.seconds(captured))s")
        currentRequest.episode = episode
        // Gate fix pass (F-B2): cancel the provider probe on
        // EVERY episode switch — including a switch to a
        // NON-hash episode, where startProviderProbeIfNeeded
        // no-ops and previously never cancelled the old probe,
        // whose completion then bled the old hash's rows into
        // the new episode. The identity guard in the probe's
        // completion is the second layer of the same rule.
        providerProbeTask?.cancel()
        providerProbeTask = nil
        // A different EPISODE is a different hash: any provider
        // pin belonged to the old hash's rows, so it clears and
        // the new hash's providers are re-probed.
        if forcedProvider != nil || !providerRows.isEmpty {
            forcedProvider = nil
            providerRows = []
        }
        startProviderProbeIfNeeded()
        beginAttempt(resumeTarget: captured)
    }

    // MARK: Provider switching (L-T13)

    /// Provider switch entry for surfaces that capture the
    /// playhead themselves at the tap (the AV transport menu).
    func switchProvider(to provider: DebridResolver.Provider, capturedPosition: Double?) {
        performProviderSwitch(to: provider, captured: capturedPosition ?? captureLivePosition())
    }

    /// Provider switch entry for surfaces whose live clock the
    /// session reads through the registered position provider
    /// (the KS host / the SwiftUI panels).
    func switchProvider(to provider: DebridResolver.Provider) {
        performProviderSwitch(to: provider, captured: captureLivePosition())
    }

    /// A user-initiated provider switch: position-preserving
    /// via the same beginAttempt machinery as an episode
    /// switch (the shared resume rule then applies on the new
    /// surface). The episode does NOT change — only the
    /// provider that must serve its hash. A not-cached provider
    /// resolves through its normal (download-capable) flow:
    /// that is user intent, and the cached-only rule binds the
    /// preview probe only. Failure lands on the existing
    /// designed error slate (resolveFailed / itemFailed).
    private func performProviderSwitch(to provider: DebridResolver.Provider, captured: Double) {
        guard !isStopped else { return }
        guard isTorrentHashTitle else { return }
        guard forcedProvider != provider else { return }
        manualSourceChosen = true
        // Gate fix pass (C-F4): a row still in .checking state
        // is information, not a command — its probe verdict has
        // not arrived, so pinning it would start the full
        // (download-capable) resolve blind. No-op with a
        // breadcrumb; every surface also disables such rows.
        if let row = providerRows.first(where: { $0.provider == provider }),
           row.state == .checking {
            DiagLog.log("player", "switch.provider ignored provider=\(provider.logToken) reason=still-checking")
            return
        }
        DiagLog.log("player", "switch.provider attempt=\(attemptID + 1) provider=\(provider.logToken) captured=\(Self.seconds(captured))s")
        forcedProvider = provider
        beginAttempt(resumeTarget: captured)
    }

    /// The live playhead, read synchronously NOW through the
    /// active host's provider; the session's last noted
    /// position is the fallback when no host is registered.
    private func captureLivePosition() -> Double {
        if let provider = positionProvider {
            let value = provider()
            if value.isFinite, value > 0 { return value }
        }
        return livePosition
    }

    // MARK: Host registration (attempt-scoped)

    func registerHost(attempt: Int,
                      positionProvider: @escaping @MainActor () -> Double,
                      subtitleApplier: @escaping @MainActor (TVSubtitleChoice) -> TVSubtitleChoice) {
        guard attempt == attemptID, attempt == registeredAttempt else { return }
        self.positionProvider = positionProvider
        self.subtitleApplier = subtitleApplier
    }

    func deregisterHost(attempt: Int) {
        guard attempt == registeredAttempt else { return }
        positionProvider = nil
        subtitleApplier = nil
    }

    // MARK: Host funnels (all attempt-scoped)

    /// The active item is ready. Returns the recorded seek
    /// target the host must apply through the shared resume
    /// rule (§5.2).
    func itemReady(attempt: Int) -> Double {
        guard attempt == attemptID, case .playing = phase else { return 0 }
        let now = Date()
        let ms = Int(now.timeIntervalSince(attemptStartDate ?? now) * 1000)
        DiagLog.log("player", "item.ready attempt=\(attempt) ms=\(ms)")
        return recordedSeekTarget
    }

    /// First frame on a surface. Emits the §6 firstframe line
    /// and, once per attempt, the computed press-to-firstframe
    /// aggregate JoeTV does not compute.
    func noteFirstFrame(attempt: Int, surface: String, via: String?) {
        guard attempt == attemptID, case .playing = phase, !firstFrameLogged else { return }
        firstFrameLogged = true
        let now = Date()
        let attemptStart = attemptStartDate ?? now
        let ms = Int(now.timeIntervalSince(attemptStart) * 1000)
        var line = "firstframe attempt=\(attempt) surface=\(surface) ms=\(ms)"
        if let via { line += " via=\(via)" }
        DiagLog.log("player", line)
        // total is anchored at THIS attempt's start (the
        // Detail tap on attempt 1; the switch/retry tap that
        // began the attempt afterwards), so the aggregate
        // always decomposes as total = resolve + load —
        // never polluted by prior attempts' playback time.
        let total = Int(now.timeIntervalSince(attemptStart) * 1000)
        let resolveMs = resolveDoneDate.map { Int($0.timeIntervalSince(attemptStart) * 1000) } ?? 0
        let loadMs = resolveDoneDate.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
        DiagLog.log("player", "press-to-firstframe attempt=\(attempt) total=\(total) (resolve=\(resolveMs) load=\(loadMs))")
    }

    /// The shared resume rule's outcome, reported by whichever
    /// host performed the seek (§5.2).
    func noteResumeSeek(attempt: Int, target: Double, finished: Bool) {
        guard attempt == attemptID else { return }
        DiagLog.log("player", "resume.seek attempt=\(attempt) target=\(Self.seconds(target)) finished=\(finished)")
    }

    /// A surface-level load failure (item failed, engine error).
    func itemFailed(attempt: Int, error: Error) {
        itemFailed(attempt: attempt, errorLabel: Self.errorLabel(error))
    }

    func itemFailed(attempt: Int, errorLabel: String) {
        guard attempt == attemptID, case .playing = phase else { return }
        DiagLog.log("player", "fail attempt=\(attempt) stage=load error=\(errorLabel)")
        phase = .failed(TVPlayerFailure(
            stage: .load,
            message: "Nguồn phát bị lỗi. Thử lại hoặc đổi nguồn khác.",
            errorLabel: errorLabel))
    }

    /// The waiting-state watchdog's verdict (§3.3/§3.4): the
    /// surface intended to play but produced nothing for the
    /// continuous-wait ceiling.
    ///
    /// L-T23 (1.3.3): this is also the stall signal the L-T21
    /// fast path exits through, so it is where auto selection
    /// reacts to a slow source — in an auto session with a
    /// measured, untried alternative, the attempt switches to
    /// the best measured source (position preserved) instead
    /// of dying on the slate. Exhausted candidates, a manual
    /// viewer pick, or the switch cap all fall through to the
    /// slate exactly as before.
    func watchdogFailed(attempt: Int, surface: String, waitedSeconds: Int) {
        guard attempt == attemptID, case .playing = phase else { return }
        if let next = nextAutoSourceCandidate() {
            DiagLog.log("player", "autosource.switch attempt=\(attempt) surface=\(surface) waited=\(waitedSeconds) from=\(currentRequest.episode.name) to=\(next.name)")
            autoSwitchCount += 1
            performSwitch(to: next, captured: captureLivePosition(), auto: true)
            return
        }
        DiagLog.log("player", "watchdog.fail attempt=\(attempt) surface=\(surface) waited=\(waitedSeconds)")
        phase = .failed(TVPlayerFailure(
            stage: .watchdog,
            message: "Nguồn không phát sau \(waitedSeconds) giây. Thử lại hoặc đổi nguồn khác.",
            errorLabel: nil))
    }

    /// Clean end of item: the title counts as finished, so its
    /// Continue Watching record is removed (the JoeTV rule).
    /// The phase guard matters: a watchdog-killed attempt's
    /// layer stop can also produce an end event, and a killed
    /// attempt is not a finished title.
    func itemEnded(attempt: Int) {
        guard attempt == attemptID, case .playing = phase else { return }
        if let record = history.record(for: currentRequest.pluginId, movieId: currentRequest.movie.id) {
            history.remove(record)
        }
    }

    // MARK: Position & history

    /// Hosts report the live playhead here (their own cadence).
    /// Updates the published position (cue overlay), the live
    /// position (switch-capture fallback) and the history
    /// record under the shared tick rule: ≤10 s or unknown
    /// duration records nothing; within the last 30 s the
    /// record is removed (finished); otherwise upsert (the
    /// manager throttles saves itself).
    func notePosition(attempt: Int, position: Double, duration: Double) {
        guard attempt == attemptID else { return }
        // Position ticks arriving while the next attempt is
        // still resolving belong to the dead surface — drop
        // them whole rather than recording a stale playhead.
        if case .resolving = phase { return }
        if position.isFinite, position >= 0 {
            livePosition = position
            // L-T11 (3) (1.3.0): hosts tick at 250 ms, but the
            // PUBLISHED position only changes when the displayed
            // second changes (≤1 Hz). Publishing every tick
            // re-rendered the whole session view (and re-ran its
            // body breadcrumb) four times a second for the whole
            // playback; livePosition above still updates at full
            // cadence for switch-capture and history, so nothing
            // that reads the live playhead loses precision.
            if Int(position) != Int(currentPosition) {
                currentPosition = position
            }
        }
        if duration.isFinite, duration > 0 { liveDuration = duration }
        guard livePosition > 10, liveDuration > 0 else { return }
        if livePosition >= liveDuration - 30 {
            if let record = history.record(for: currentRequest.pluginId, movieId: currentRequest.movie.id) {
                history.remove(record)
            }
            return
        }
        history.upsert(makeHistoryRecord(position: livePosition, duration: liveDuration))
    }

    private func flushHistory() {
        guard livePosition > 10, liveDuration > 0, livePosition < liveDuration - 30 else { return }
        history.upsert(makeHistoryRecord(position: livePosition, duration: liveDuration), force: true)
    }

    private func makeHistoryRecord(position: Double, duration: Double) -> HistoryRecord {
        HistoryRecord(
            pluginId: currentRequest.pluginId,
            pluginName: currentRequest.pluginName,
            isManga: currentRequest.isManga,
            movie: currentRequest.movie,
            serverName: currentRequest.serverName,
            episodeName: currentRequest.episode.name,
            episodeId: currentRequest.episode.id,
            streamURL: currentStream?.url ?? "",
            lastPosition: position,
            duration: duration,
            updatedAt: Date())
    }

    // MARK: Subtitles (§4)

    /// What the active host must apply at item-ready: the
    /// user's manual pick when one exists (session state,
    /// re-applied to every attempt — FL-049), else the default
    /// rule (Vietnamese if available, else English, once).
    func subtitleDirective() -> TVSubtitleDirective {
        if let manualChoice { return .applyManual(manualChoice) }
        return .applyDefault
    }

    /// The host reports its subtitle application (§6 subs line)
    /// exactly once per attempt. `overlayFile` is the file track
    /// the AV cue overlay must render — always nil from the KS
    /// host, whose layer renders file tracks itself (§4.2).
    func noteSubtitlesApplied(attempt: Int, embedded: Int, files: Int,
                              applied: String, effective: TVSubtitleChoice,
                              overlayFile: SubtitleTrack?) {
        guard attempt == attemptID else { return }
        effectiveChoice = effective
        setActiveFileTrack(overlayFile)
        DiagLog.log("player", "subs attempt=\(attempt) embedded=\(embedded) files=\(files) applied=\(applied)")
    }

    /// The active host publishes its embedded catalogue for the
    /// shared panel's rows.
    func updateCatalog(attempt: Int, embedded: [TVEmbeddedTrackRef]) {
        guard attempt == attemptID else { return }
        subtitleCatalog = TVSubtitleCatalog(embedded: embedded)
    }

    /// A pick in the shared panel: becomes session state at
    /// once (FL-049), applies to the live host immediately, and
    /// closes the panel (the iOS sheet / JoeTV picker shape).
    func selectSubtitle(_ choice: TVSubtitleChoice) {
        guard !isStopped else { return }
        manualChoice = choice
        // The host resolves the pick against ITS surface and
        // returns what actually took effect (a cross-surface
        // embedded pick resolves to this surface's key; a
        // pick that matches nothing is .off). The EFFECTIVE
        // choice is what session state — and therefore the
        // panel's checkmark and default focus — follows.
        let resolved = subtitleApplier?(choice) ?? choice
        effectiveChoice = resolved
        // The overlay follows the RESOLVED pick on the AV
        // surface only; on KS the layer renders the same
        // pick — the overlay never exists there (§4.2), and
        // TVPlayerView only mounts it over the AV host
        // regardless. The cue store's fetch therefore starts
        // only when the current attempt's route IS the AV
        // surface (.av or .proxy — both are the AV host); on
        // KS the host feeds the file to the layer itself, so
        // no fetch starts and no overlay track is set.
        if case .file(let track) = resolved, isAVSurface {
            setActiveFileTrack(track)
        } else {
            setActiveFileTrack(nil)
        }
        presentedPanel = nil
    }

    /// The Phase 4 placeholder row (§4.5): selecting it changes
    /// nothing, starts nothing, and leaves the §6 line.
    func selectAutoSubUnavailable() {
        DiagLog.log("player", "autosub-entry-unavailable")
    }

    /// Whether the "Tiếng Việt (dịch tự động)" row is offered
    /// (§4.5's rule): a usable non-Vietnamese source track
    /// exists and no native Vietnamese track exists anywhere
    /// (embedded or file).
    var autoSubOffered: Bool {
        let files = currentStream?.subtitles ?? []
        let hasVietnamese = subtitleCatalog.embedded.contains {
            TVSubtitleLanguage.isVietnamese(name: $0.displayName, code: $0.languageHint)
        } || files.contains {
            TVSubtitleLanguage.isVietnamese(name: $0.label, code: $0.lang)
        }
        if hasVietnamese { return false }
        return !subtitleCatalog.embedded.isEmpty || !files.isEmpty
    }

    /// Whether the current attempt plays on the AV surface
    /// (the `.proxy` route is the AV host with the proxy
    /// loader attached — §3.2, TVPlayerView's dispatch).
    private var isAVSurface: Bool {
        if case .playing(let route, _) = phase {
            return route == .av || route == .proxy
        }
        return false
    }

    private func setActiveFileTrack(_ track: SubtitleTrack?) {
        activeFileTrack = track
        if let track {
            fileSubtitles.load(track: track, headers: currentStream?.headers ?? [:])
        }
    }

    // MARK: Helpers

    static func errorLabel(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }

    /// One-decimal seconds for the switch/resume log lines; a
    /// non-finite read logs as 0.0 rather than "nan".
    static func seconds(_ value: Double) -> String {
        String(format: "%.1f", value.isFinite ? value : 0)
    }
}
