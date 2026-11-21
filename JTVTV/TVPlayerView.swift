import SwiftUI

/// JTV tvOS Phase 3 — the player cover content (plan §3.1,
/// §10): replaces `TVPlaybackPlaceholderView` in TVRootView's
/// full-screen cover slot for video requests. It hosts the
/// session's surfaces (AV / KS, recreated per attempt via
/// `.id(attemptID)` — JoeTV's attempt-identity mechanism), the
/// loading state, the designed error state (§3.5), the shared
/// subtitle panel and the source panel, and it owns Menu
/// arbitration with the shell: panel open → Menu closes the
/// panel only; no panel → Menu dismisses the player (FL-048).
/// `.manga` resolutions keep the Phase 4 placeholder state
/// inside this view.
struct TVPlayerView: View {
    let request: PlaybackRequest

    init(request: PlaybackRequest) {
        self.request = request
        // L-T04 probe breadcrumb P1: the cover's content view
        // exists — cover presentation has begun.
        DiagLog.log("player", "cover.presenting plugin=\(request.pluginId) episode=\(request.episode.id)")
    }

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var history: WatchHistoryManager
    @EnvironmentObject private var presenter: PlaybackPresenter
    @EnvironmentObject private var pinSession: PinSession

    var body: some View {
        TVPlayerSessionView(request: request, service: service, history: history,
                            pinSession: pinSession) {
            presenter.request = nil
        }
    }
}

// MARK: - Session view

private struct TVPlayerSessionView: View {
    @StateObject private var session: TVPlayerSession
    @Environment(\.tvTheme) private var theme

    init(request: PlaybackRequest, service: MovieService, history: WatchHistoryManager,
         pinSession: PinSession, onDismiss: @escaping () -> Void) {
        _session = StateObject(wrappedValue: TVPlayerSession(
            request: request, service: service, history: history,
            pinSession: pinSession, onDismiss: onDismiss))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            if session.presentedPanel == .subtitles {
                TVSubtitlePanelView(session: session)
            } else if session.presentedPanel == .sources {
                TVSourcePanelView(session: session)
            }
        }
        .onExitCommand {
            // THE single Menu arbiter for this cover — the
            // only such handler in the player files. The
            // panels carry none: panel open → close the panel
            // only; no panel → dismiss the player (FL-048).
            if session.presentedPanel != nil {
                session.presentedPanel = nil
            } else {
                session.dismiss()
            }
        }
        .onAppear {
            // L-T04 probe breadcrumb P4: the cover is on
            // screen — session start is next.
            DiagLog.log("player", "cover.presented")
            session.start()
        }
        .onDisappear { session.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .resolving:
            loadingView
        case .playing(let route, let attempt):
            surfaceView(route: route, attempt: attempt)
        case .manga:
            // Phase 4 placeholder state, unchanged behaviour —
            // named so it is not mistaken for a dead end.
            TVPlaybackPlaceholderView(request: session.currentRequest)
        case .failed(let failure):
            TVPlayerErrorView(session: session, failure: failure)
        }
    }

    @ViewBuilder
    private func surfaceView(route: TVSurfaceRoute, attempt: Int) -> some View {
        if let stream = session.currentStream {
            if route == .ks {
                TVKSPlayerHost(stream: stream, attemptID: attempt, session: session)
                    .id(attempt)
                    .ignoresSafeArea()
            } else {
                ZStack {
                    TVAVPlayerHost(stream: stream, attemptID: attempt,
                                   useProxy: route == .proxy, session: session)
                        .id(attempt)
                        .ignoresSafeArea()
                    // The AV file-track cue overlay (§4.2) —
                    // mounted only over the AV surface, only
                    // while a file track is selected.
                    if session.activeFileTrack != nil {
                        TVSubtitleCueOverlayView(session: session)
                            .ignoresSafeArea()
                    }
                }
            }
        } else {
            loadingView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 22) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.4)
            Text(session.currentRequest.movie.title)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(session.currentRequest.episode.name)
                .font(.system(size: 26))
                .foregroundStyle(theme.textDim)
            Text("Đang tải…")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(theme.textDim)
            Text("Nhấn Menu để đóng")
                .font(.system(size: 22))
                .foregroundStyle(theme.textFaint)
                .padding(.top, 8)
        }
        .padding(60)
    }
}

// MARK: - Error state (§3.5)

/// A designed surface, never a black trap: the classified
/// message plus focusable Thử lại / Đổi nguồn (when switch
/// targets exist) / Đóng — Đóng always present and
/// default-focused (FL-152).
private struct TVPlayerErrorView: View {
    @ObservedObject var session: TVPlayerSession
    let failure: TVPlayerFailure

    @Environment(\.tvTheme) private var theme
    @FocusState private var focusedAction: Action?

    private enum Action: Hashable {
        case retry
        case sources
        case close
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 68, weight: .light))
                .foregroundStyle(theme.badgeQuality)
            Text(session.currentRequest.movie.title)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(failure.message)
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(theme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1100)
            HStack(spacing: 18) {
                actionButton(.retry, title: "Thử lại", filled: false) {
                    session.retry()
                }
                if session.hasSwitchTargets {
                    actionButton(.sources, title: "Đổi nguồn", filled: false) {
                        session.presentedPanel = .sources
                    }
                }
                actionButton(.close, title: "Đóng", filled: true) {
                    session.dismiss()
                }
            }
            .padding(.top, 10)
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focusedAction, .close)
    }

    private func actionButton(_ action: Action, title: String, filled: Bool,
                              handler: @escaping () -> Void) -> some View {
        let isFocused = focusedAction == action
        return Button {
            handler()
        } label: {
            Text(title)
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(filled ? theme.onAccent : theme.textPrimary)
                .padding(.horizontal, 42)
                .padding(.vertical, 16)
                .background(Capsule().fill(filled ? theme.accent : theme.cardFill))
                .overlay(Capsule().strokeBorder(
                    isFocused ? theme.focusRing : (filled ? Color.clear : theme.cardStroke),
                    lineWidth: isFocused ? theme.ringWidth : 1))
                .contentShape(Capsule())
        }
        .tvCardButton()
        .focused($focusedAction, equals: action)
    }
}

// MARK: - Source panel

/// The switch-target list (session.switchTargets), shared by
/// the error slate's Đổi nguồn and the KS bar's Đổi nguồn
/// button. (The AV surface offers the same targets through
/// its native transport-bar submenu instead — JoeTV's
/// pattern.) The current source is checked and disabled;
/// picking a row switches through the session (which captures
/// the live position at the tap, §5.1) and closes the panel.
/// The panel carries no Back handler of its own — the
/// shell's single Menu arbiter closes it (FL-048).
private struct TVSourcePanelView: View {
    @ObservedObject var session: TVPlayerSession

    @Environment(\.tvTheme) private var theme
    @FocusState private var focusedID: String?

    private let cancelID = "__cancel"

    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(spacing: 26) {
                Text("Đổi nguồn")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(session.switchTargets) { episode in
                            let isCurrent = episode.id == session.currentRequest.episode.id
                            row(id: episode.id, title: episode.name, checked: isCurrent,
                                disabled: isCurrent) {
                                session.switchSource(to: episode)
                                session.presentedPanel = nil
                            }
                        }
                        row(id: cancelID, title: "Huỷ", checked: false, disabled: false) {
                            session.presentedPanel = nil
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(44)
            .frame(width: 920)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(theme.surfaceGradient))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .defaultFocus($focusedID, defaultTargetID)
    }

    /// Default focus lands on the first switchable (enabled)
    /// target — the current episode's row is always disabled,
    /// so focusing it would strand the panel. When no other
    /// target exists, fall back to the current episode's id.
    private var defaultTargetID: String {
        session.switchTargets.first(where: {
            $0.id != session.currentRequest.episode.id
        })?.id ?? session.currentRequest.episode.id
    }

    private func row(id: String, title: String, checked: Bool, disabled: Bool,
                     action: @escaping () -> Void) -> some View {
        let isFocused = focusedID == id
        return Button {
            action()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .opacity(checked ? 1 : 0)
                    .frame(width: 30)
                Text(title)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .tvCardButton()
        .focused($focusedID, equals: id)
        .disabled(disabled)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isFocused ? Color.white.opacity(0.14) : theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isFocused ? theme.focusRing : .clear,
                          lineWidth: isFocused ? theme.ringWidth : 0))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
