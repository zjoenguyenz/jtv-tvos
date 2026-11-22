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

    /// The session, built EAGERLY in init (L-T06 — JoeTV's
    /// pre-build shape, player map R-1): the session object
    /// exists before the cover's body/presentation machinery
    /// runs. Dependencies arrive as VALUES from TVRootView
    /// (which owns them); nothing in this cover's subtree
    /// reads an @EnvironmentObject, and no construction hides
    /// behind a StateObject autoclosure inside the presented
    /// tree — on device (1.2.3/6, jtv-log_6.txt) the process
    /// died in exactly that hand-off, after cover.presenting
    /// and before session.init.begin, on every Play tap.
    /// The built instance is anchored by TVPlayerSessionView's
    /// @StateObject box (JoeTV's box): the box's autoclosure
    /// merely returns this instance, and StateObject storage
    /// keeps the FIRST installed instance for the whole
    /// presentation even if this view value is re-created.
    private let builtSession: TVPlayerSession

    init(request: PlaybackRequest, service: MovieService, history: WatchHistoryManager,
         pinSession: PinSession, onDismiss: @escaping () -> Void) {
        self.request = request
        // L-T11 (1) (1.3.0) single-flight: SwiftUI evaluates the
        // fullScreenCover content closure MORE THAN ONCE for one
        // presentation (measured in jtv-log_7: the whole
        // cover.presenting → session.init chain ran twice, 16 ms
        // apart, for one tap). The eager build stays (L-T06),
        // but a second evaluation for the SAME request id now
        // reuses the first evaluation's session instead of
        // constructing — and logging — a second one. The entry
        // is cleared by the wrapped dismiss, so a later, separate
        // presentation of an equal request builds fresh.
        // Gate fix pass (Round 1 on R2, Lens 2 F3): the
        // claim-or-store is ATOMIC — lookup and store happen
        // under ONE lock scope inside claimOrStore, so two
        // racing cover evaluations can no longer both miss,
        // both construct, and have the second store silently
        // overwrite (orphan) the first session. The create
        // closure runs only on a genuine miss, so the
        // breadcrumb chain below still prints exactly once
        // per constructed session.
        builtSession = TVPlayerSessionReuse.claimOrStore(for: request.id) {
            // L-T04 probe breadcrumb P1: the cover's content view
            // exists — cover presentation has begun.
            DiagLog.log("player", "cover.presenting plugin=\(request.pluginId) episode=\(request.episode.id)")
            // L-T06 split breadcrumbs: bracket the eager session
            // construction (session.init.begin/done print between
            // these two) — a plain assignment, evaluated NOW, in
            // init. A session built for a view value SwiftUI never
            // installs does no work: its init is assignments plus
            // its two breadcrumb lines, and only start() (from the
            // cover's onAppear) begins work.
            DiagLog.log("player", "cover.session.creating plugin=\(request.pluginId)")
            var created: TVPlayerSession!
            let session = TVPlayerSession(
                request: request, service: service, history: history,
                pinSession: pinSession,
                autoMeasureArmed: TVAutoMeasureArming.isArmed(requestID: request.id),
                onDismiss: {
                    // Instance-matched clear (Lens 2 F3): the
                    // dismiss clears the registry ONLY when the
                    // stored entry IS this session — a stale
                    // dismiss can never evict a newer session
                    // stored under the same request id.
                    if let created {
                        TVPlayerSessionReuse.clear(session: created)
                    }
                    onDismiss()
                })
            created = session
            DiagLog.log("player", "cover.session.created")
            return session
        }
    }

    var body: some View {
        // L-T06 split breadcrumb: the cover root's body was
        // reached — init and session construction survived.
        DiagLog.log("player", "cover.view.body")
        return TVPlayerSessionView(session: builtSession)
    }
}

// MARK: - Auto-measure arming hand-off (L-T23, gate fix C-1)

/// Carries ONE bit from TVDetailView.play() to the session
/// built for that play: whether the started episode is the
/// detail's DEFAULT pick (the Play button's target — the
/// first non-empty server's first episode). It exists
/// because the bit cannot ride the PlaybackRequest itself:
/// the request type is shared core (JTV/Models.swift) and
/// must not grow a TV-only field, and the presenter is core
/// too. Single slot, keyed by the request's id (a fresh UUID
/// per play()): Detail writes it in the same update that
/// hands the request to the presenter, and TVPlayerView.init
/// reads it when the cover builds the session. A read for
/// any other id — a request that never passed through
/// play() — is false, so auto-selection can never arm by
/// accident; a stale entry is overwritten by the next play()
/// and can only ever match its own request's id.
enum TVAutoMeasureArming {
    private static let lock = NSLock()
    // Lock-guarded on every access (the house idiom, same as
    // TVPlayerSessionReuse below).
    private nonisolated(unsafe) static var entry: (id: UUID, armed: Bool)?

    static func arm(requestID: UUID, armed: Bool) {
        lock.withLock { entry = (requestID, armed) }
    }

    static func isArmed(requestID: UUID) -> Bool {
        lock.withLock { entry?.id == requestID ? entry?.armed == true : false }
    }
}

// MARK: - Single-flight session reuse (L-T11 (1))

/// Holds the ONE eagerly built session for the presentation
/// currently on screen, keyed by the PlaybackRequest's id.
/// TVPlayerView.init consults it before constructing; the
/// session's wrapped dismiss clears it. Lock-guarded (the
/// house NSLock idiom) for the atomic claim-or-store, and
/// @MainActor (gate fix pass, Round 1 on R3): the registry
/// reads the session's `isStopped`, a MainActor-isolated
/// property, so its entry points are MainActor-isolated too
/// and never cross the isolation boundary. Every call site
/// is a MainActor context — TVPlayerView.init (SwiftUI View
/// construction), TVPlayerSession.stop() (a @MainActor
/// class), and the session's wrapped onDismiss (invoked
/// from the session's MainActor dismiss()).
enum TVPlayerSessionReuse {
    private static let lock = NSLock()
    // Lock-guarded by `lock` on every access (Swift 6:
    // nonisolated(unsafe) is the honest spelling of that).
    private nonisolated(unsafe) static var entry: (id: UUID, session: TVPlayerSession)?

    /// Atomic claim-or-store (Lens 2 F3): lookup AND store in
    /// ONE lock scope. A stored session is handed back only
    /// when its id matches AND it has not been stopped — a
    /// stopped session (see TVPlayerSession.stop(), which also
    /// clears its entry) can never be reused; a stopped or
    /// mismatched entry is replaced by a fresh construction.
    /// `create` runs under the lock and only on a miss: the
    /// session's init is assignments + breadcrumbs and never
    /// calls back into this registry, so holding the lock
    /// across it cannot deadlock.
    @MainActor
    static func claimOrStore(for id: UUID, create: () -> TVPlayerSession) -> TVPlayerSession {
        lock.withLock {
            if let entry, entry.id == id, !entry.session.isStopped {
                return entry.session
            }
            let session = create()
            entry = (id, session)
            return session
        }
    }

    /// Instance-matched clear (Lens 2 F3): removes the entry
    /// ONLY when the stored session IS `session` (identity,
    /// not merely the same request id) — a stop/dismiss of an
    /// old session never evicts a newer one. Called by
    /// TVPlayerSession.stop() (every teardown path funnels
    /// through the cover's onDisappear → stop()) and by the
    /// session's wrapped onDismiss.
    @MainActor
    static func clear(session: TVPlayerSession) {
        lock.withLock { if entry?.session === session { entry = nil } }
    }
}

// MARK: - Session view

private struct TVPlayerSessionView: View {
    /// JoeTV's box: the pre-built session is handed to a
    /// @StateObject whose autoclosure merely returns the
    /// existing instance — StateObject storage evaluates it
    /// once and keeps that first instance for the whole
    /// presentation, so a re-created parent view value can
    /// never swap the playing session mid-presentation.
    @StateObject private var session: TVPlayerSession
    @Environment(\.tvTheme) private var theme

    init(session: TVPlayerSession) {
        _session = StateObject(wrappedValue: session)
    }

    var body: some View {
        // L-T06 split breadcrumb: the session view's body was
        // reached with the pre-built session in hand.
        // L-T11 (3) (1.3.0): FIRST-ONLY — this body re-runs on
        // every session publish (progress ticks included), and
        // logging every run produced 386 lines in one ~30 min
        // session in jtv-log_7. The breadcrumb's job (proving
        // the body was reached once per presentation) is done
        // by the first run.
        if !session.sessionViewBodyLogged {
            session.sessionViewBodyLogged = true
            DiagLog.log("player", "cover.sessionview.body")
        }
        return ZStack {
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
        case .manga(let stream):
            // NEXT-B (1.3.0): the focus-stepped manga reader
            // replaces the Phase 4 placeholder. It is a child of
            // the session (dependencies as values — no
            // @EnvironmentObject in this subtree, L-T06 rule);
            // chapter switches resolve inside the reader.
            TVMangaReaderView(session: session, initialStream: stream)
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
            // NEXT-C C3 (1.3.0): the source-switch list on the
            // LOADING state (iOS parity — PlayerView's sourceList
            // under the resolving spinner). A switch during
            // resolving works through the existing
            // performSwitch/beginAttempt cancellation: the
            // in-flight resolve and its deadline are cancelled
            // and stale completions are dropped by the attempt
            // guard. Semantics mirror TVSourcePanelView: current
            // source checked + disabled, default focus on the
            // first switchable row.
            // L-T13 (1.3.1): for a TORRENT (hash) title the list
            // is NOT gated on the episode count — the provider
            // rows are the switchable sources there, and an
            // uncached torrent's exempt-from-deadline wait is
            // exactly when the list must exist.
            if session.hasSwitchTargets || session.isTorrentHashTitle {
                TVLoadingSourceListView(session: session)
                    .padding(.top, 6)
            }
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
                if session.hasSwitchRows {
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
                        // L-T13: provider rows (same hash,
                        // chosen debrid provider + live cache
                        // state) under the variant rows.
                        if !session.providerRows.isEmpty {
                            Text("Nguồn debrid cho file này")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(theme.textDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 10)
                            ForEach(session.providerRows) { providerRow in
                                let isPinned = session.forcedProvider == providerRow.provider
                                // Gate fix pass (C-F4): a
                                // .checking provider row is not
                                // actionable — disabled until its
                                // probe verdict lands.
                                row(id: providerRow.id, title: providerRow.title, checked: isPinned,
                                    disabled: isPinned || providerRow.state == .checking) {
                                    session.switchProvider(to: providerRow.provider)
                                    session.presentedPanel = nil
                                }
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
    /// episode target exists, the first unpinned provider row
    /// (L-T13) takes it; last resort is the current episode.
    private var defaultTargetID: String {
        if let episode = session.switchTargets.first(where: {
            $0.id != session.currentRequest.episode.id
        }) { return episode.id }
        // Gate fix pass (C-F4): default focus skips disabled
        // rows — a .checking provider row is disabled, so it
        // cannot take the panel's default focus.
        if let providerRow = session.providerRows.first(where: {
            session.forcedProvider != $0.provider && $0.state != .checking
        }) { return providerRow.id }
        // Guaranteed-enabled fallback: the Huỷ row is always
        // present and enabled (the current episode's row is
        // disabled, so it must never be the fallback).
        return cancelID
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

// MARK: - Loading-state source list (NEXT-C C3)

/// The switch list rendered on the resolving/loading state —
/// the tvOS port of iOS's `sourceList` under the spinner
/// (PlayerView.swift:2413-2452). Same session semantics as
/// TVSourcePanelView (current source checked + disabled,
/// default focus on the first switchable row), minus the
/// panel chrome: it lives inline under the spinner so a long
/// or doomed resolve — notably an exempt-from-deadline torrent
/// resolve (C2) — can be abandoned without leaving the player.
/// Picking a row calls session.switchSource(to:), which runs
/// performSwitch → beginAttempt: the in-flight resolve is
/// cancelled and its stale completion dropped by the attempt
/// guard. No Back handler of its own (FL-048).
private struct TVLoadingSourceListView: View {
    @ObservedObject var session: TVPlayerSession

    @Environment(\.tvTheme) private var theme
    @FocusState private var focusedID: String?

    var body: some View {
        VStack(spacing: 14) {
            Text("Nguồn khác — chọn để đổi ngay")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.textDim)
            // Review-gate fix (1.3.0): the row list is BOUNDED
            // like TVSourcePanelView — a ScrollView with a fixed
            // max height, so a long switch list cannot push the
            // loading state off screen; focus movement scrolls
            // rows into view.
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(session.switchTargets) { episode in
                        let isCurrent = episode.id == session.currentRequest.episode.id
                        row(episode: episode, isCurrent: isCurrent)
                    }
                    // L-T13: provider rows on the loading list
                    // too — for a torrent title these are the
                    // rows that make the list exist at all.
                    if !session.providerRows.isEmpty {
                        Text("Nguồn debrid cho file này")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(theme.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                        ForEach(session.providerRows) { providerRow in
                            providerRowView(providerRow)
                        }
                    }
                    // Gate fix pass (C-F5): the guaranteed
                    // focusable fallback row — always present,
                    // always enabled, so the loading list can
                    // never be focus-less even when every other
                    // row is disabled (current episode, pinned
                    // or .checking providers, probe filtering
                    // every provider out).
                    closeRow
                }
                .padding(.vertical, 6)
            }
            .frame(width: 860)
            .frame(maxHeight: 430)
        }
        .defaultFocus($focusedID, defaultTargetID)
    }

    /// Gate fix pass (C-F5): the loading list's fallback row
    /// id — the close affordance below, always enabled.
    private var closeID: String { "__close" }

    private var defaultTargetID: String {
        // Gate fix pass (C-F4/C-F5): default focus = the first
        // ENABLED row — non-current episodes are enabled;
        // provider rows only when unpinned AND not .checking.
        if let episode = session.switchTargets.first(where: {
            $0.id != session.currentRequest.episode.id
        }) { return episode.id }
        if let providerRow = session.providerRows.first(where: {
            session.forcedProvider != $0.provider && $0.state != .checking
        }) { return providerRow.id }
        // No row is enabled: the guaranteed focusable close
        // row takes default focus — never the disabled current
        // episode's row.
        return closeID
    }

    private var closeRow: some View {
        let isFocused = focusedID == closeID
        return Button {
            session.dismiss()
        } label: {
            HStack(spacing: 16) {
                Spacer().frame(width: 30)
                Text("Đóng")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .tvCardButton()
        .focused($focusedID, equals: closeID)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isFocused ? Color.white.opacity(0.14) : theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isFocused ? theme.focusRing : .clear,
                          lineWidth: isFocused ? theme.ringWidth : 0))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func providerRowView(_ providerRow: TVPlayerSession.ProviderRow) -> some View {
        let isPinned = session.forcedProvider == providerRow.provider
        let isFocused = focusedID == providerRow.id
        return Button {
            session.switchProvider(to: providerRow.provider)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .opacity(isPinned ? 1 : 0)
                    .frame(width: 30)
                Text(providerRow.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .tvCardButton()
        .focused($focusedID, equals: providerRow.id)
        // Gate fix pass (C-F4): a .checking provider row is not
        // actionable on the loading list either.
        .disabled(isPinned || providerRow.state == .checking)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isFocused ? Color.white.opacity(0.14) : theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isFocused ? theme.focusRing : .clear,
                          lineWidth: isFocused ? theme.ringWidth : 0))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(episode: Episode, isCurrent: Bool) -> some View {
        let isFocused = focusedID == episode.id
        return Button {
            session.switchSource(to: episode)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 30)
                Text(episode.name)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .tvCardButton()
        .focused($focusedID, equals: episode.id)
        .disabled(isCurrent)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isFocused ? Color.white.opacity(0.14) : theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isFocused ? theme.focusRing : .clear,
                          lineWidth: isFocused ? theme.ringWidth : 0))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
