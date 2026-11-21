import AVFoundation
import SwiftUI
import UIKit

/// Shared kill-switch key for the Detail backdrop preview
/// (NEXT-D §3.6): TVSettingsView writes it, TVDetailView's
/// dwell task reads it. Default ON.
enum TVPreviewSettings {
    static let defaultsKey = "jtv_backdrop_preview_enabled"
}

/// JTV tvOS 1.3.0 (NEXT-D D1) — the muted backdrop-preview
/// player host: a non-focusable, interaction-disabled
/// `AVPlayerLayer` view plus its coordinator. It is NOT either
/// player host: no session, no controls, no focus, no resume,
/// no history — a preview only, discarded (never adopted) when
/// the real player is presented.
///
/// Discipline (NEXT-D §3.3/§3.4, FL-201/FL-202):
/// - muted is set on the player BEFORE any item is assigned;
///   the audio session is never touched;
/// - play is ready-gated: play() only after the item reaches
///   .readyToPlay, and the fade-in callback fires only when
///   ready AND timeControlStatus == .playing (first frame);
/// - plays ONCE from 0 with a 90 s cap, then fades out and
///   retires;
/// - the ready wait is bounded at 15 s — a preview that is not
///   ready by then retires silently to the still;
/// - every observer registration is paired with its removal;
/// - teardown (pause + replaceCurrentItem(nil) + invalidate)
///   runs on dismantle, on end, on cap, and on any failure.
/// DiagLog `preview.*` lines carry kind + host only — never a
/// full URL for a credential host, never a token.
struct TVBackdropPreviewHost: UIViewRepresentable {
    let stream: StreamInfo
    let onFirstFrame: () -> Void
    let onRetire: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFirstFrame: onFirstFrame, onRetire: onRetire)
    }

    func makeUIView(context: Context) -> TVBackdropPreviewView {
        let view = TVBackdropPreviewView()
        context.coordinator.start(view: view, stream: stream)
        return view
    }

    func updateUIView(_ uiView: TVBackdropPreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: TVBackdropPreviewView,
                                coordinator: Coordinator) {
        coordinator.teardown()
    }

    // MARK: - View

    final class TVBackdropPreviewView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Non-focusable, non-interactive by construction:
            // the preview must never enter Detail's focus chain.
            isUserInteractionEnabled = false
            playerLayer.videoGravity = .resizeAspectFill
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        private let onFirstFrame: () -> Void
        private let onRetire: (String) -> Void

        private var player: AVPlayer?
        private weak var view: TVBackdropPreviewView?
        private var statusObservation: NSKeyValueObservation?
        private var timeControlObservation: NSKeyValueObservation?
        private var notificationTokens: [NSObjectProtocol] = []
        private var readyWatchdog: Task<Void, Never>?
        private var capTask: Task<Void, Never>?
        private var retireTask: Task<Void, Never>?
        private var itemReady = false
        private var firstFrameShown = false
        private var retired = false

        init(onFirstFrame: @escaping () -> Void, onRetire: @escaping (String) -> Void) {
            self.onFirstFrame = onFirstFrame
            self.onRetire = onRetire
        }

        func start(view: TVBackdropPreviewView, stream: StreamInfo) {
            self.view = view
            guard let url = URL(string: stream.url) else {
                retire(reason: "bad-url", animated: false)
                return
            }
            DiagLog.log("preview", "resolved kind=video host=\(url.host ?? "?")")
            var options: [String: Any] = [:]
            if !stream.headers.isEmpty {
                options[AVURLAssetHTTPHeaderFieldsKey] = stream.headers
            }
            let asset = AVURLAsset(url: url, options: options)
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 5
            let player = AVPlayer()
            // Mute BEFORE the item is assigned — the preview has
            // no audio path at all.
            player.isMuted = true
            self.player = player
            view.playerLayer.player = player
            observe(item: item, player: player)
            player.replaceCurrentItem(with: item)
            // Bounded ready wait (15 s): a preview that never
            // becomes ready retires to the still, silently.
            readyWatchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled, !self.itemReady else { return }
                self.retire(reason: "ready-timeout", animated: false)
            }
        }

        private func observe(item: AVPlayerItem, player: AVPlayer) {
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    // Only Sendable values cross this hop
                    // (TVAVPlayerHost's shipped shape): the
                    // observed item is re-read from self.player
                    // inside the MainActor task instead of being
                    // captured into the @Sendable closure.
                    guard let self, let item = self.player?.currentItem else { return }
                    switch item.status {
                    case .readyToPlay:
                        self.itemReady = true
                        self.readyWatchdog?.cancel()
                        // Ready-gated play (FL-201).
                        self.player?.play()
                        self.armCap()
                    case .failed:
                        let error = item.error as NSError?
                        DiagLog.log("preview", "failed kind=item domain=\(error?.domain ?? "?")#\(error?.code ?? 0)")
                        self.retire(reason: "item-failed", animated: false)
                    default:
                        break
                    }
                }
            }
            timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    // Same discipline as above: the player's
                    // status is re-read from self.player here,
                    // never captured into the @Sendable closure.
                    guard let self, self.itemReady, !self.firstFrameShown,
                          self.player?.timeControlStatus == .playing else { return }
                    self.firstFrameShown = true
                    DiagLog.log("preview", "first-frame")
                    self.onFirstFrame()
                }
            }
            let center = NotificationCenter.default
            notificationTokens.append(center.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.retire(reason: "ended", animated: true)
                }
            })
            notificationTokens.append(center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    DiagLog.log("preview", "failed kind=play-to-end")
                    self?.retire(reason: "play-failed", animated: false)
                }
            })
        }

        /// The 90 s play-once cap: at the cap the preview fades
        /// back to the still and retires (NEXT-D §3.3).
        private func armCap() {
            capTask?.cancel()
            capTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard let self, !Task.isCancelled else { return }
                self.retire(reason: "cap", animated: true)
            }
        }

        /// Fade out (when a frame was shown), then tear down and
        /// notify the owner, which clears its preview state.
        private func retire(reason: String, animated: Bool) {
            guard !retired else { return }
            retired = true
            DiagLog.log("preview", "retired reason=\(reason)")
            if animated, firstFrameShown {
                // The owner's opacity state follows onRetire;
                // teardown after the fade so the layer does not
                // vanish mid-animation.
                onRetire(reason)
                retireTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(650))
                    self?.teardown()
                }
            } else {
                onRetire(reason)
                teardown()
            }
        }

        /// Pause + empty + invalidate every observer — the one
        /// teardown every exit path funnels through.
        func teardown() {
            readyWatchdog?.cancel()
            readyWatchdog = nil
            capTask?.cancel()
            capTask = nil
            statusObservation?.invalidate()
            statusObservation = nil
            timeControlObservation?.invalidate()
            timeControlObservation = nil
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            notificationTokens = []
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            view?.playerLayer.player = nil
            player = nil
        }
    }
}
