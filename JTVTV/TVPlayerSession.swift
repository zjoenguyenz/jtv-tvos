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

    // Host registrations (attempt-scoped; a stale host's
    // deregistration must not clear the live host's handlers).
    private var registeredAttempt = 0
    private var positionProvider: (@MainActor () -> Double)?
    private var subtitleApplier: (@MainActor (TVSubtitleChoice) -> TVSubtitleChoice)?

    init(request: PlaybackRequest,
         service: MovieService,
         history: WatchHistoryManager,
         pinSession: PinSession,
         onDismiss: @escaping () -> Void) {
        self.currentRequest = request
        self.service = service
        self.history = history
        self.pinSession = pinSession
        self.onDismiss = onDismiss
    }

    // MARK: Lifecycle

    /// Called once from the cover's onAppear. Logs the §6 tap
    /// line (the session's birth — Detail stays untouched, per
    /// the plan's preference) and starts the first attempt.
    func start() {
        guard !started else { return }
        started = true
        pinSession.setPlaybackActive(true)
        tapDate = Date()
        DiagLog.log("player", "tap attempt=1 plugin=\(currentRequest.pluginId) server=\(currentRequest.serverName)")
        beginAttempt(resumeTarget: currentRequest.startPosition)
    }

    /// Called from the cover's onDisappear: playback no longer
    /// counts as activity, the final position is flushed to
    /// history, and every in-flight task is cancelled.
    func stop() {
        pinSession.setPlaybackActive(false)
        flushHistory()
        resolveTask?.cancel()
        resolveTask = nil
        resolveTimeoutTask?.cancel()
        resolveTimeoutTask = nil
        positionProvider = nil
        subtitleApplier = nil
    }

    func dismiss() {
        onDismiss()
    }

    // MARK: Attempts & resolve

    private func beginAttempt(resumeTarget: Double) {
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

        DiagLog.log("player", "resolve.begin attempt=\(attempt)")
        let request = currentRequest
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolution = try await self.service.resolveEpisode(request)
                self.resolveSucceeded(attempt: attempt, resolution: resolution)
            } catch {
                self.resolveFailed(attempt: attempt, error: error)
            }
        }
        // Resolve deadline (FL-005/FL-152): EVERY attempt gets
        // a session-level ceiling, so no resolve can spin
        // forever without reaching the error slate (§3.5's
        // "no silent infinite loading"). Non-debrid attempts
        // keep the iOS resolver's 45 s. Debrid (`jtvhash:`)
        // attempts get a longer 120 s ceiling: the resolver's
        // own internal budgets govern the normal debrid case,
        // and this task is only the session's last-resort
        // deadline behind them — never the primary budget.
        // A timed-out attempt lands on the error slate; the
        // late completion is dropped by the phase guard in
        // resolveSucceeded/resolveFailed.
        let resolveTimeoutSeconds: Double = request.episode.id.hasPrefix("jtvhash:") ? 120 : 45
        resolveTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(resolveTimeoutSeconds))
            guard let self, !Task.isCancelled else { return }
            guard self.attemptID == attempt, case .resolving = self.phase else { return }
            DiagLog.log("player", "fail attempt=\(attempt) stage=resolve error=player#timeout")
            self.phase = .failed(TVPlayerFailure(
                stage: .resolve,
                message: "Không tải được nguồn phát. Kiểm tra mạng rồi thử lại.",
                errorLabel: "player#timeout"))
        }
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
            DiagLog.log("player", "resolve.done attempt=\(attempt) ms=\(ms) route=\(token)")
            phase = .playing(route: route, attempt: attempt)
        case .manga(let stream):
            currentStream = stream
            DiagLog.log("player", "resolve.done attempt=\(attempt) ms=\(ms) route=manga")
            phase = .manga(stream)
        case .embed:
            // No webview exists on tvOS (gaps G-2/G-3): the
            // designed error state (§3.5), never a black trap.
            DiagLog.log("player", "resolve.done attempt=\(attempt) ms=\(ms) route=embed")
            phase = .failed(TVPlayerFailure(
                stage: .embed,
                message: "Nguồn này cần trình phát web, chưa hỗ trợ trên TV. Hãy đổi nguồn khác.",
                errorLabel: nil))
        }
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
        let captured = captureLivePosition()
        beginAttempt(resumeTarget: captured > 0 ? captured : recordedSeekTarget)
    }

    // MARK: Source switching (§5)

    /// Switch targets: the torrenthub shortlist when present
    /// (its episodes ARE the cross-server sources), else the
    /// current server's episode list (the iOS rule).
    var switchTargets: [Episode] {
        let list = currentRequest.switchList.isEmpty
            ? currentRequest.allEpisodes
            : currentRequest.switchList
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

    private func performSwitch(to episode: Episode, captured: Double) {
        guard episode.id != currentRequest.episode.id else { return }
        let from = currentRequest.episode.name
        // The switch line names the NEW attempt (beginAttempt
        // increments to exactly this number).
        DiagLog.log("player", "switch attempt=\(attemptID + 1) from=\(from) to=\(episode.name) captured=\(Self.seconds(captured))s")
        currentRequest.episode = episode
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
    func watchdogFailed(attempt: Int, surface: String, waitedSeconds: Int) {
        guard attempt == attemptID, case .playing = phase else { return }
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
            currentPosition = position
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
