import AVFoundation
import AVKit
import Foundation
import SwiftUI

/// JTV tvOS Phase 3 — the AV surface (plan §3.3).
///
/// A stock `AVPlayerViewController` (system transport, system
/// rendering of embedded subtitle groups) fed an `AVURLAsset`
/// built the JoeTV way: `AVURLAssetHTTPHeaderFieldsKey` carries
/// the StreamInfo headers (plus the house UA when the stream
/// set none). For `requiresProxy` streams the asset is the
/// core's `HLSProxyLoader` custom-scheme asset instead — the
/// loader fetches every resource itself with the same headers.
///
/// Discipline: initial play is gated on `.readyToPlay`
/// (FL-201); every observer registration below has its removal
/// written beside it in `invalidate()` (FL-202); interruption /
/// end-of-item / stall observers are registered from the start
/// (FL-206); the freeze watchdog reads the waiting state with a
/// ~30 s continuous-wait ceiling (FL-042).
struct TVAVPlayerHost: UIViewControllerRepresentable {
    let stream: StreamInfo
    let attemptID: Int
    let useProxy: Bool
    let session: TVPlayerSession

    @MainActor
    final class Coordinator {
        weak var controller: AVPlayerViewController?
        var player: AVPlayer?
        var proxyLoader: HLSProxyLoader?

        private var stream: StreamInfo?
        private var attemptID = 0
        private var session: TVPlayerSession?

        // Observer tokens — every registration's removal lives
        // in invalidate() (FL-202).
        private var statusObservation: NSKeyValueObservation?
        private var timeControlObservation: NSKeyValueObservation?
        private var periodicObserver: Any?
        private var notificationTokens: [NSObjectProtocol] = []

        private var watchdogTask: Task<Void, Never>?
        private var waitingSince: Date?

        private var readyHandled = false
        /// A resume seek was attempted at ready and is still
        /// IN FLIGHT. The flag's guarded window is the seek's
        /// flight only: it is set when the seek starts and
        /// cleared in the seek completion, whatever the result
        /// (finished true or false). Inside the window a
        /// `.paused` read may be the seek's own dead pause, so
        /// the watchdog counts it as waiting; once the seek has
        /// completed the window is over and a `.paused` read is
        /// a user pause again, holding the watchdog clock open
        /// like any other user pause (FL-204: playback may
        /// only follow a finished seek).
        private var resumeSeekAwaitingPlayback = false
        /// Set when the user pauses DURING the seek window:
        /// the timeControlStatus observer saw a transition to
        /// `.paused` after the status had left `.paused` since
        /// the seek started (playback or waiting had begun, so
        /// the pause is the user's act, not the seek's own
        /// starting state, which is `.paused` throughout and
        /// produces no such transition). A marked pause vetoes
        /// the seek completion's play() — user intent wins.
        private var userPausedDuringSeek = false
        /// Whether timeControlStatus has left `.paused` at all
        /// since the current resume seek started; the witness
        /// that distinguishes a user pause transition from the
        /// seek's own dead pause (see userPausedDuringSeek).
        private var resumeSeekSawNonPaused = false
        private var firstFrameReported = false
        /// L-T04 probe: P11 logs the FIRST item-status callback
        /// only — the flag flips once and never affects flow.
        private var statusFirstLogged = false
        private var failed = false
        private var ended = false

        // MARK: Start

        func start(controller: AVPlayerViewController, stream: StreamInfo,
                   attemptID: Int, session: TVPlayerSession, useProxy: Bool) {
            self.controller = controller
            self.stream = stream
            self.attemptID = attemptID
            self.session = session

            guard let url = stream.streamURL else {
                session.itemFailed(attempt: attemptID, errorLabel: "player#invalid-url")
                return
            }

            let asset: AVURLAsset
            if useProxy, let proxied = HLSProxyLoader.proxiedURL(for: url) {
                // The rescue route (§3.2): the loader fetches
                // playlist AND segments itself, with the
                // stream's headers on every request.
                let loader = HLSProxyLoader(headers: stream.headers)
                proxyLoader = loader
                let proxiedAsset = AVURLAsset(url: proxied)
                proxiedAsset.resourceLoader.setDelegate(
                    loader, queue: DispatchQueue(label: "jtv.hlsproxy.delegate"))
                asset = proxiedAsset
            } else {
                var headers = stream.headers
                if headers["User-Agent"] == nil {
                    headers["User-Agent"] = Net.desktopUA
                }
                asset = AVURLAsset(url: url,
                                   options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            }

            // L-T04 probe breadcrumb P9: the asset exists —
            // proxyLoader is non-nil exactly when the proxy
            // fork built it.
            DiagLog.log("player", "asset.built route=\(proxyLoader != nil ? "proxy" : "plain")")
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            self.player = player
            controller.player = player
            controller.showsPlaybackControls = true

            observe(item: item, player: player)
            buildTransportMenu()
            // L-T04 probe breadcrumb P10a: the transport menu
            // was built inside start() (shortlist row 3's site).
            DiagLog.log("player", "menu.built")
            session.registerHost(
                attempt: attemptID,
                positionProvider: { [weak self] in
                    guard let self, let player = self.player else { return 0 }
                    let seconds = player.currentTime().seconds
                    return seconds.isFinite ? seconds : 0
                },
                subtitleApplier: { [weak self] choice in
                    // A live panel pick: drives the surface
                    // and returns what actually took effect;
                    // the session stores that as the
                    // effective choice (selectSubtitle).
                    self?.applyChoiceToItem(choice) ?? choice
                })
            armWatchdog()
            // A fast item may already be ready before the
            // observers settle (the JoeTV warmed-item check).
            if item.status == .readyToPlay {
                handleReady(item: item)
            }
            // L-T04 probe breadcrumb P10b: start() completed.
            DiagLog.log("player", "start.done")
        }

        // MARK: Observers (FL-202/FL-206)

        private func observe(item: AVPlayerItem, player: AVPlayer) {
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, let item = self.player?.currentItem else { return }
                    self.handleItemStatus(item)
                }
            }
            timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.handleTimeControlStatus()
                }
            }
            periodicObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                // queue: .main — the handler provably runs on
                // the main actor (the house pattern, iOS
                // PlayerView).
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let position = time.seconds.isFinite ? time.seconds : 0
                    let duration = self.player?.currentItem?.duration.seconds ?? 0
                    self.session?.notePosition(attempt: self.attemptID,
                                               position: position,
                                               duration: duration.isFinite ? duration : 0)
                }
            }
            let center = NotificationCenter.default
            notificationTokens.append(center.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.ended else { return }
                    self.ended = true
                    self.session?.itemEnded(attempt: self.attemptID)
                }
            })
            notificationTokens.append(center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] note in
                // Only the Sendable label crosses the hop
                // (Swift 6) — JoeTV's proven shape at this
                // site: domain#code is all failLoad needs.
                let nsError = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                let label = nsError.map { "\($0.domain)#\($0.code)" }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.failLoad(errorLabel: label ?? "player#play-to-end-failed")
                }
            })
            notificationTokens.append(center.addObserver(
                forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    // A stall is evidence, not a verdict: the
                    // waiting-state watchdog judges it (§3.3).
                    DiagLog.log("player", "stall attempt=\(self?.attemptID ?? -1) surface=av")
                }
            })
            notificationTokens.append(center.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let began = raw == AVAudioSession.InterruptionType.began.rawValue
                Task { @MainActor [weak self] in
                    guard let self, began else { return }
                    self.player?.pause()
                    DiagLog.log("player", "interruption attempt=\(self.attemptID) surface=av")
                }
            })
        }

        /// Symmetric teardown for every registration above
        /// (FL-202), plus the watchdog (FL-210: dismantle is
        /// one of its two cancellation paths — the session's
        /// own stop is the other, via the attempt guards).
        func invalidate() {
            watchdogTask?.cancel()
            watchdogTask = nil
            statusObservation?.invalidate()
            statusObservation = nil
            timeControlObservation?.invalidate()
            timeControlObservation = nil
            if let periodicObserver, let player {
                player.removeTimeObserver(periodicObserver)
            }
            periodicObserver = nil
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            notificationTokens.removeAll()
            player?.pause()
            session?.deregisterHost(attempt: attemptID)
        }

        // MARK: Ready / first frame / failure

        private func handleItemStatus(_ item: AVPlayerItem) {
            // L-T04 probe breadcrumb P11: first status callback.
            if !statusFirstLogged {
                statusFirstLogged = true
                let token: String
                switch item.status {
                case .readyToPlay: token = "ready"
                case .failed: token = "failed"
                default: token = "unknown"
                }
                DiagLog.log("player", "item.status.first value=\(token)")
            }
            guard !failed else { return }
            switch item.status {
            case .readyToPlay:
                handleReady(item: item)
            case .failed:
                if let error = item.error {
                    failLoad(error: error)
                } else {
                    failLoad(errorLabel: "player#item-failed")
                }
            default:
                break
            }
        }

        /// The gated start (FL-201): subtitles first (the
        /// default/manual application, §4.4), then the shared
        /// resume rule (§5.2) — seek once if the recorded
        /// target > 5 s, zero tolerance, play only on a
        /// finished seek; otherwise play directly.
        private func handleReady(item: AVPlayerItem) {
            guard !readyHandled, !failed else { return }
            readyHandled = true
            // L-T04 probe breadcrumb P12a: ready handling began.
            DiagLog.log("player", "ready.handled")
            guard let session, let player else { return }
            let target = session.itemReady(attempt: attemptID)
            applySubtitleDirective(item: item)
            buildTransportMenu()
            if TVResumeRule.shouldSeek(target) {
                resumeSeekAwaitingPlayback = true
                userPausedDuringSeek = false
                resumeSeekSawNonPaused = false
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.session?.noteResumeSeek(attempt: self.attemptID,
                                                     target: target, finished: finished)
                        // The window ends HERE, whatever the
                        // result: clear the flag (and the
                        // window's intent marks) in the
                        // completion itself, not on the road
                        // to first .playing.
                        let userPaused = self.userPausedDuringSeek
                        self.resumeSeekAwaitingPlayback = false
                        self.userPausedDuringSeek = false
                        self.resumeSeekSawNonPaused = false
                        // Play only on a finished seek
                        // (FL-204) AND only when no user
                        // pause intervened during the window.
                        if finished, !userPaused {
                            // L-T04 probe breadcrumb P12b.
                            DiagLog.log("player", "play.called")
                            self.player?.play()
                        }
                    }
                }
            } else {
                // L-T04 probe breadcrumb P12b.
                DiagLog.log("player", "play.called")
                player.play()
            }
            handleTimeControlStatus()
        }

        private func handleTimeControlStatus() {
            guard let player else { return }
            // User-intent tracking for the resume-seek window
            // (Fix 2): a transition INTO .paused after the
            // status had left .paused since the seek started
            // is a user pause; the seek's own state never
            // leaves .paused, so it can never mark itself.
            if resumeSeekAwaitingPlayback {
                switch player.timeControlStatus {
                case .playing, .waitingToPlayAtSpecifiedRate:
                    resumeSeekSawNonPaused = true
                case .paused:
                    if resumeSeekSawNonPaused {
                        userPausedDuringSeek = true
                    }
                @unknown default:
                    break
                }
            }
            guard readyHandled, !firstFrameReported, !failed else { return }
            // §6: AV first frame = first .playing with the
            // item .readyToPlay. (The resume-seek flag is NOT
            // cleared here — the seek completion clears it.)
            if player.timeControlStatus == .playing,
               player.currentItem?.status == .readyToPlay {
                firstFrameReported = true
                session?.noteFirstFrame(attempt: attemptID, surface: "av", via: nil)
            }
        }

        private func failLoad(error: Error) {
            failLoad(errorLabel: TVPlayerSession.errorLabel(error))
        }

        private func failLoad(errorLabel: String) {
            guard !failed else { return }
            failed = true
            watchdogTask?.cancel()
            watchdogTask = nil
            player?.pause()
            session?.itemFailed(attempt: attemptID, errorLabel: errorLabel)
        }

        // MARK: Watchdog (FL-042)

        /// While the player waits to play at the specified
        /// rate (or the item has not readied at all, or a
        /// resume seek is still in flight) the wait clock
        /// runs; ~30 s of CONTINUOUS waiting fails the
        /// attempt. A user pause (.paused — including one
        /// made during the seek window, once that seek has
        /// completed and its flag has cleared) and actual
        /// playing both hold the clock open. The
        /// watchdog failing the attempt — never an auto-play
        /// after an unfinished seek — is the recovery
        /// (FL-204).
        private func armWatchdog() {
            watchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    self.watchdogTick()
                }
            }
        }

        private func watchdogTick() {
            guard !failed, !ended, let player else { return }
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                || (!readyHandled && player.currentItem?.status == .unknown)
                || (resumeSeekAwaitingPlayback && player.timeControlStatus != .playing)
            if waiting {
                if waitingSince == nil { waitingSince = Date() }
                if let since = waitingSince, Date().timeIntervalSince(since) >= 30 {
                    let waited = Int(Date().timeIntervalSince(since))
                    failed = true
                    watchdogTask?.cancel()
                    watchdogTask = nil
                    player.pause()
                    session?.watchdogFailed(attempt: attemptID, surface: "av", waitedSeconds: waited)
                }
            } else {
                waitingSince = nil
            }
        }

        // MARK: Transport menu (§3.3)

        /// Đổi nguồn (submenu of the session's switch targets,
        /// the current one checked) + Phụ đề (opens the shared
        /// panel) — JoeTV's AV-surface pattern. Rebuilt at
        /// ready so the check mark is never stale. Picking a
        /// source captures the LIVE playhead synchronously in
        /// the action, before anything moves (FL-041).
        private func buildTransportMenu() {
            guard let controller, let session else { return }
            var children: [UIMenuElement] = []
            let targets = session.switchTargets
            if targets.count > 1 {
                let currentID = session.currentRequest.episode.id
                let switchMenu = UIMenu(
                    title: "Đổi nguồn",
                    image: UIImage(systemName: "arrow.triangle.2.circlepath"),
                    children: targets.map { episode in
                        UIAction(title: episode.name,
                                 state: episode.id == currentID ? .on : .off) { [weak self] _ in
                            guard let self else { return }
                            let now = self.player?.currentTime().seconds ?? 0
                            self.session?.switchSource(
                                to: episode,
                                capturedPosition: (now.isFinite && now > 0) ? now : nil)
                        }
                    })
                children.append(switchMenu)
            }
            children.append(UIAction(
                title: "Phụ đề",
                image: UIImage(systemName: "captions.bubble")
            ) { [weak self] _ in
                self?.session?.presentedPanel = .subtitles
            })
            controller.transportBarCustomMenuItems = [
                UIMenu(title: "Media Service", children: children)
            ]
        }

        // MARK: Subtitles (§4.2/§4.4)

        private func legibleGroup(for item: AVPlayerItem) -> AVMediaSelectionGroup? {
            item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
        }

        private func applySubtitleDirective(item: AVPlayerItem) {
            guard let session else { return }
            // Publish the embedded catalogue for the panel.
            let group = legibleGroup(for: item)
            let options = group?.options ?? []
            session.updateCatalog(attempt: attemptID, embedded: options.map {
                TVEmbeddedTrackRef(key: Self.key(for: $0),
                                   displayName: $0.displayName,
                                   languageHint: $0.extendedLanguageTag ?? "")
            })
            switch session.subtitleDirective() {
            case .applyManual(let choice):
                applyManualChoice(choice, item: item)
            case .applyDefault:
                applySubtitleDefault(item: item, options: options)
            }
        }

        /// A selection applied to the live item. Embedded
        /// picks select the group option (AVFoundation
        /// renders); file picks clear the group and hand the
        /// track to the cue overlay; Off clears both (§4.2).
        /// The two renderers are mutually exclusive by
        /// construction. Returns what actually took effect.
        @discardableResult
        func applyChoiceToItem(_ choice: TVSubtitleChoice) -> TVSubtitleChoice {
            guard let item = player?.currentItem else { return .off }
            return applyChoice(choice, to: item)
        }

        private func applyChoice(_ choice: TVSubtitleChoice, to item: AVPlayerItem) -> TVSubtitleChoice {
            let group = legibleGroup(for: item)
            switch choice {
            case .off:
                if let group { item.select(nil, in: group) }
                return .off
            case .embedded(let key, let displayName):
                // Resolve through the shared cross-surface
                // order (§4.4: exact key → display name →
                // language): a pick stored on the KS surface
                // carries a KS key that matches nothing here.
                // Returns the track ACTUALLY selected (in this
                // surface's key space), or .off when no
                // candidate matches at all.
                if let group {
                    let catalog = group.options.map {
                        TVEmbeddedTrackRef(key: Self.key(for: $0),
                                           displayName: $0.displayName,
                                           languageHint: $0.extendedLanguageTag ?? "")
                    }
                    if let resolved = TVEmbeddedPickResolver.resolve(key: key, displayName: displayName, in: catalog),
                       let option = group.options.first(where: { Self.key(for: $0) == resolved.key }) {
                        item.select(option, in: group)
                        return .embedded(key: resolved.key, displayName: resolved.displayName)
                    }
                }
                // Unresolved: ENFORCE the reported .off, as
                // every sibling branch does — a fresh item
                // can carry an automatic legible selection,
                // and "off" must mean nothing renders.
                if let group { item.select(nil, in: group) }
                return .off
            case .file(let track):
                if let group { item.select(nil, in: group) }
                // Validate against THIS attempt's sidecar
                // list, exactly as the KS surface does (§4.4):
                // a pick stored on a previous item that is
                // absent here resolves to .off — never a
                // claimed "file" that would render the
                // previous item's cues over this content.
                if let stream, stream.subtitles.contains(track) {
                    return choice
                }
                return .off
            }
        }

        /// The directive's manual branch at ready: apply the
        /// session's stored pick and report the attempt's §6
        /// subs line (the live panel-pick path deliberately
        /// does not re-log it).
        private func applyManualChoice(_ choice: TVSubtitleChoice, item: AVPlayerItem) {
            guard let session else { return }
            let effective = applyChoice(choice, to: item)
            let applied: String
            var overlayFile: SubtitleTrack?
            switch effective {
            case .off: applied = "off"
            case .embedded: applied = "track"
            case .file(let track):
                applied = "file"
                overlayFile = track
            }
            session.noteSubtitlesApplied(attempt: attemptID,
                                         embedded: legibleGroup(for: item)?.options.count ?? 0,
                                         files: stream?.subtitles.count ?? 0,
                                         applied: applied,
                                         effective: effective,
                                         overlayFile: overlayFile)
        }

        /// The default rule (§4.4), applied ONCE per item:
        /// Vietnamese if available, else English, in the ONE
        /// shared ranking (TVSubtitleDefaultRanking: file-VI
        /// → embedded-VI → embedded-EN → file-EN). Every
        /// branch ENFORCES what it reports, exactly as
        /// applyChoice does: file winners and the no-slot
        /// case clear the legible group (a fresh item can
        /// carry an automatic selection — §4.2's mutual
        /// exclusion and the honesty of "default-none" both
        /// depend on it).
        private func applySubtitleDefault(item: AVPlayerItem, options: [AVMediaSelectionOption]) {
            guard let session, let stream else { return }
            let group = legibleGroup(for: item)
            var applied = "default-none"
            var effective: TVSubtitleChoice = .off
            var overlayFile: SubtitleTrack?
            let viFile = stream.subtitles.first(where: {
                TVSubtitleLanguage.isVietnamese(name: $0.label, code: $0.lang)
            })
            let enFile = stream.subtitles.first(where: {
                TVSubtitleLanguage.isEnglish(name: $0.label, code: $0.lang)
            })
            let vi = options.first(where: {
                TVSubtitleLanguage.isVietnamese(name: $0.displayName,
                                                code: $0.extendedLanguageTag ?? $0.locale?.identifier ?? "")
            })
            let en = options.first(where: {
                TVSubtitleLanguage.isEnglish(name: $0.displayName,
                                              code: $0.extendedLanguageTag ?? $0.locale?.identifier ?? "")
            })
            switch TVSubtitleDefaultRanking.winningSlot(
                hasFileVietnamese: viFile != nil,
                hasEmbeddedVietnamese: vi != nil,
                hasEmbeddedEnglish: en != nil,
                hasFileEnglish: enFile != nil) {
            case .some(.fileVietnamese):
                if let viFile {
                    // The overlay renders the file; the
                    // legible group must render NOTHING
                    // (§4.2 mutual exclusion) — a fresh item
                    // can carry an automatic selection.
                    group.map { item.select(nil, in: $0) }
                    applied = "default-vi"
                    effective = .file(viFile)
                    overlayFile = viFile
                }
            case .some(.embeddedVietnamese):
                if let vi {
                    group.map { item.select(vi, in: $0) }
                    applied = "default-vi"
                    effective = .embedded(key: Self.key(for: vi), displayName: vi.displayName)
                }
            case .some(.embeddedEnglish):
                if let en {
                    group.map { item.select(en, in: $0) }
                    applied = "default-en"
                    effective = .embedded(key: Self.key(for: en), displayName: en.displayName)
                }
            case .some(.fileEnglish):
                if let enFile {
                    group.map { item.select(nil, in: $0) }
                    applied = "default-en"
                    effective = .file(enFile)
                    overlayFile = enFile
                }
            case .none:
                // "default-none" must be enforced, not
                // just reported: clear any automatic
                // legible selection so nothing renders,
                // exactly as the manual path enforces .off.
                group.map { item.select(nil, in: $0) }
            }
            session.noteSubtitlesApplied(attempt: attemptID,
                                         embedded: options.count,
                                         files: stream.subtitles.count,
                                         applied: applied,
                                         effective: effective,
                                         overlayFile: overlayFile)
        }

        // MARK: Track matching (iOS D-1, verbatim rule)

        static func key(for option: AVMediaSelectionOption) -> String {
            (option.extendedLanguageTag ?? option.locale?.identifier ?? "") + "|" + option.displayName
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // L-T04 probe breadcrumb P8: the AV host is being made.
        DiagLog.log("player", "host.make surface=av")
        let controller = AVPlayerViewController()
        context.coordinator.start(controller: controller, stream: stream,
                                  attemptID: attemptID, session: session, useProxy: useProxy)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController,
                                          coordinator: Coordinator) {
        coordinator.invalidate()
        controller.player = nil
    }
}
