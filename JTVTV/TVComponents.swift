import SwiftUI
import UIKit

/// JTV tvOS Phase 2 — shared leaf components (foundation, fixed
/// contract). Every component is theme-aware via
/// `@Environment(\.tvTheme)` and built with the proven Settings
/// focus construction (TVTheme.swift): label-untouched
/// TVCardButtonStyle + element-level focus + `.focusEffectDisabled()`
/// + a self-drawn INSET ring on the element's own rounded rect.
/// No List, no `.onMoveCommand`, no container-level `.focusable()`,
/// no scale effects anywhere.

// MARK: - Remote image (bucketed pipeline view)

/// Poster/backdrop image with JoeTV's JoeRemoteImage discipline
/// (PHASE2-JOETV-STUDY §5e):
/// - first paint is the SYNCHRONOUS bucketed cache read, so a
///   warm image is on screen with no task hop;
/// - the load runs in `.task(id:)` keyed by url|bucket|retryToken,
///   so a result can only land on the identity that asked for it;
/// - disappearing does NOT cancel the manager-level load — the
///   manager owns its in-flight tasks, and the bitmap is cached
///   for the next appearance instead of restarting;
/// - loading paints a plain cardFill rectangle (no spinner on
///   poster cells — cells stay clean); failure paints the fill
///   plus a `photo` glyph in textFaint and reports through the
///   `failed` binding.
///
/// `bucket` is the caller's pixel-width bucket (poster rail/grid
/// 720, landscape 720, backdrop 1920, detail poster 960).
struct TVRemoteImage: View {
    let urlString: String
    var headers: [String: String] = [:]
    let bucket: Int
    var contentMode: ContentMode = .fill
    var failed: Binding<Bool>?
    var retryToken: Int = 0

    @Environment(\.tvTheme) private var theme
    @State private var loadedImage: UIImage?
    @State private var loadedKey: String?
    @State private var failedKey: String?

    init(urlString: String,
         headers: [String: String] = [:],
         bucket: Int,
         contentMode: ContentMode = .fill,
         failed: Binding<Bool>? = nil,
         retryToken: Int = 0) {
        self.urlString = urlString
        self.headers = headers
        self.bucket = bucket
        self.contentMode = contentMode
        self.failed = failed
        self.retryToken = retryToken
    }

    private var taskKey: String { "\(urlString)|\(bucket)|\(retryToken)" }

    private var syncCached: UIImage? {
        ImageCacheManager.shared.cachedImage(urlString: urlString, headers: headers, bucket: bucket)
    }

    private var shown: UIImage? {
        if loadedKey == taskKey, let loadedImage { return loadedImage }
        return syncCached
    }

    private var isFailed: Bool { failedKey == taskKey }

    var body: some View {
        ZStack {
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if isFailed {
                Rectangle()
                    .fill(theme.cardFill)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(theme.textFaint)
                    }
            } else {
                Rectangle()
                    .fill(theme.cardFill)
            }
        }
        .task(id: taskKey) {
            let key = taskKey
            if urlString.isEmpty {
                failedKey = key
                failed?.wrappedValue = true
                return
            }
            if let cached = ImageCacheManager.shared.cachedImage(urlString: urlString, headers: headers, bucket: bucket) {
                loadedImage = cached
                loadedKey = key
                if failedKey == key { failedKey = nil }
                failed?.wrappedValue = false
                return
            }
            // L-T04 breadcrumb D4: bracket the 1920-rung
            // (backdrop) load — begin/end, host only. Other
            // buckets stay unlogged (every poster would flood
            // the log); the memory-cached early return above
            // serves an already-decoded image and is not the
            // first-decode path D4 exists to bracket.
            if bucket == 1920 {
                DiagLog.log("detail", "backdrop.load.begin host=\(URL(string: urlString)?.host ?? "?")")
            }
            // 1.3.19 (L-T50): a retry tap (retryToken > 0) is
            // an explicit user retry — it bypasses the manager's
            // permanent-failure memo.
            let loaded = await ImageCacheManager.shared.loadImage(urlString: urlString, headers: headers, bucket: bucket,
                                                                  force: retryToken > 0)
            if bucket == 1920 {
                DiagLog.log("detail", "backdrop.load.end host=\(URL(string: urlString)?.host ?? "?") ok=\(loaded != nil)")
            }
            // The task id already guarantees this result belongs
            // to the current identity; the key check is the
            // explicit form of the same guarantee.
            guard key == taskKey else { return }
            if let loaded {
                apply(loaded, key: key)
                return
            }
            failedKey = key
            failed?.wrappedValue = true
            // 1.3.19 (L-T50): when the failure came from a host
            // the breaker is holding, the cell schedules its own
            // retry for when the cooldown ends (bounded: four
            // rounds, then it waits for the user / a rebuild),
            // so posters of a host that comes back fill in by
            // themselves instead of staying blank until the view
            // is recreated. The sleep dies with the view (.task
            // cancellation), so off-screen cells cost nothing.
            for _ in 0..<4 {
                guard let delay = ImageCacheManager.shared.retryDelay(urlString: urlString) else { return }
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000) + Int.random(in: 0...750)))
                if Task.isCancelled || key != taskKey { return }
                if let again = await ImageCacheManager.shared.loadImage(urlString: urlString, headers: headers, bucket: bucket) {
                    guard key == taskKey else { return }
                    apply(again, key: key)
                    return
                }
            }
        }
    }

    private func apply(_ image: UIImage, key: String) {
        loadedImage = image
        loadedKey = key
        if failedKey == key { failedKey = nil }
        failed?.wrappedValue = false
    }
}

// MARK: - Badges (poster cells)

private struct TVBadge: View {
    let text: String
    let background: Color
    let foreground: Color

    var body: some View {
        Text(text)
            .font(.system(size: 19, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(background))
    }
}

// MARK: - Poster card (rail form)

/// One poster cell: 2:3 art via TVRemoteImage (bucket 720)
/// clipped to RoundedRectangle(24), with the focus ring drawn
/// on the IDENTICAL rounded rect, inset in the art's own frame
/// (owner amendment 4 — ring and image share one rounded rect
/// by construction, `.focusEffectDisabled()` always, plus a
/// subtle fill lift when focused). The ring rides the ART only
/// (JoeTV Ultra precedent, study §1.5); the WHOLE card — art +
/// title/meta block — is one Button.
///
/// Select behaviour: if the image failed, the FIRST tap
/// retries the image (internal retryToken bump) and does NOT
/// select; a SECOND tap on a still-failed image selects
/// anyway (A-3, 1.3.9 — a dead image host must not turn the
/// card into a dead button; the detail screen can still
/// load from its own host).
struct TVPosterCard: View {
    let movie: Movie
    var width: CGFloat = 240
    let isFavorite: Bool
    let onSelect: () -> Void
    let onLongPress: () -> Void
    /// Phase 2 opt-ins (both default to the pre-Phase-2
    /// behaviour, so every existing call site is unchanged):
    /// - `onFocusChange`: the actor screen's dwell preview and
    ///   focus counter need to know WHICH card holds focus;
    ///   the card's focus state itself stays internal.
    /// - `selectOnImageFailure`: the flow audit's A-3 rule
    ///   for a card whose image failed. The DEFAULT (flag
    ///   off) is two-tap everywhere: tap 1 retries the
    ///   image, and tap 2 — the failure still standing —
    ///   opens the film, so the card never reads as a dead
    ///   button. The flag opts a surface OUT of the retry
    ///   tap: the actor screen (audit P-4's drawing rule)
    ///   selects on the FIRST tap even when the image
    ///   failed.
    var onFocusChange: ((Bool) -> Void)? = nil
    var selectOnImageFailure: Bool = false
    /// A-6 (1.3.9): an optional EXTERNAL entry-focus binding
    /// (a grid's first cell as its screen's landing focus).
    /// Same contract as TVChip's: when handed in it replaces
    /// the card's own focus binding — exactly one binding is
    /// ever attached — and drawing reads `focusActive`.
    var entryFocus: FocusState<Bool>.Binding? = nil

    @Environment(\.tvTheme) private var theme
    @FocusState private var isFocused: Bool
    @State private var imageFailed = false
    @State private var retryToken = 0
    /// A-3: the current failure has already had its one
    /// retry tap; the next tap selects. Reset whenever the
    /// image state clears or the movie changes.
    @State private var retriedSinceFailure = false

    private var focusActive: Bool {
        entryFocus?.wrappedValue ?? isFocused
    }

    init(movie: Movie,
         width: CGFloat = 240,
         isFavorite: Bool,
         onSelect: @escaping () -> Void,
         onLongPress: @escaping () -> Void,
         onFocusChange: ((Bool) -> Void)? = nil,
         selectOnImageFailure: Bool = false,
         entryFocus: FocusState<Bool>.Binding? = nil) {
        self.movie = movie
        self.width = width
        self.isFavorite = isFavorite
        self.onSelect = onSelect
        self.onLongPress = onLongPress
        self.onFocusChange = onFocusChange
        self.selectOnImageFailure = selectOnImageFailure
        self.entryFocus = entryFocus
    }

    var body: some View {
        Button {
            if imageFailed && !selectOnImageFailure && !retriedSinceFailure {
                retriedSinceFailure = true
                retryToken += 1
            } else {
                // L-T04 breadcrumb D0 (card form): the tap is
                // leaving the poster card. The card carries no
                // plugin id; D1 in TVNavPath.push logs it.
                DiagLog.log("detail", "tap.card movie=\(movie.id)")
                onSelect()
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                art
                VStack(alignment: .leading, spacing: 4) {
                    Text(movie.title)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(focusActive && theme.isUltra ? theme.focusRing : theme.textPrimary)
                        .lineLimit(2)
                        .frame(width: width, alignment: .leading)
                    HStack(spacing: 8) {
                        if movie.year > 0 {
                            Text(String(movie.year))
                        }
                        if !movie.lang.isEmpty {
                            Text(movie.lang)
                        }
                    }
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(theme.textFaint)
                    .frame(width: width, alignment: .leading)
                }
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .tvCardButton()
        .focused(entryFocus ?? $isFocused)
        .onChange(of: movie.id) { imageFailed = false; retryToken = 0; retriedSinceFailure = false }
        .onChange(of: imageFailed) { _, failed in
            if !failed { retriedSinceFailure = false }
        }
        .onChange(of: focusActive) { _, focused in onFocusChange?(focused) }
        .onLongPressGesture(minimumDuration: 0.5) {
            onLongPress()
        }
    }

    /// Ultra poster slot colour is #26262B (study §1.5); the
    /// Original theme's slot is its cardFill.
    private var slotColor: Color {
        theme.isUltra ? Color(red: 0.149, green: 0.149, blue: 0.169) : theme.cardFill
    }

    private var art: some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous)
                .fill(slotColor)
            // FL-488: the movie's serving page rides as the
            // Referer when it carries one; absent = today's
            // host-root synthesis inside fetchBytes.
            TVRemoteImage(urlString: movie.posterUrl,
                          headers: movie.sourcePageURL.map { ["Referer": $0] } ?? [:],
                          bucket: 720,
                          failed: $imageFailed, retryToken: retryToken)
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous))
        .overlay(alignment: .topLeading) {
            if !movie.quality.isEmpty {
                TVBadge(text: movie.quality, background: theme.badgeQuality, foreground: .black)
                    .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !movie.episode_current.isEmpty {
                TVBadge(text: movie.episode_current,
                        background: theme.badgeEpisode,
                        foreground: theme.isUltra ? .white : .black)
                    .padding(10)
            }
        }
        // The focus ring: the identical RoundedRectangle(24) as
        // the art clip, inset in the art's own frame, plus the
        // subtle focused fill lift. No second frame.
        .overlay {
            RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous)
                .fill(Color.white.opacity(focusActive ? 0.08 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous)
                .strokeBorder(focusActive ? theme.focusRing : .clear,
                              lineWidth: focusActive ? theme.ringWidth : 0)
        }
    }
}

// MARK: - Poster cell (grid form)

/// Grid-column form of TVPosterCard: identical contract and
/// identical visuals (it IS the poster card, sized by the
/// caller's column width) — one implementation, so the rail
/// and grid forms can never drift apart.
struct TVGridPosterCell: View {
    let movie: Movie
    var width: CGFloat = 240
    let isFavorite: Bool
    let onSelect: () -> Void
    let onLongPress: () -> Void
    var onFocusChange: ((Bool) -> Void)? = nil
    var selectOnImageFailure: Bool = false
    var entryFocus: FocusState<Bool>.Binding? = nil

    init(movie: Movie,
         width: CGFloat = 240,
         isFavorite: Bool,
         onSelect: @escaping () -> Void,
         onLongPress: @escaping () -> Void,
         onFocusChange: ((Bool) -> Void)? = nil,
         selectOnImageFailure: Bool = false,
         entryFocus: FocusState<Bool>.Binding? = nil) {
        self.movie = movie
        self.width = width
        self.isFavorite = isFavorite
        self.onSelect = onSelect
        self.onLongPress = onLongPress
        self.onFocusChange = onFocusChange
        self.selectOnImageFailure = selectOnImageFailure
        self.entryFocus = entryFocus
    }

    var body: some View {
        TVPosterCard(movie: movie, width: width, isFavorite: isFavorite,
                     onSelect: onSelect, onLongPress: onLongPress,
                     onFocusChange: onFocusChange,
                     selectOnImageFailure: selectOnImageFailure,
                     entryFocus: entryFocus)
    }
}

// MARK: - Landscape card (Continue Watching)

/// 16:9 Continue Watching card: art from
/// `record.movie.displayBackdrop` (bucket 720) at radius 18
/// with the radius-matched inset ring on the same rect, a
/// bottom gradient, play glyph + episode name bottom-leading,
/// an accent progress bar when progress is meaningful
/// (!isManga && duration > 0), and title + plugin name under
/// the art. One Button for the whole card.
struct TVLandscapeCard: View {
    let record: HistoryRecord
    var width: CGFloat = 400
    let onSelect: () -> Void
    let onLongPress: () -> Void
    /// L-T41 (1.3.15): an optional focus-change hook, the
    /// poster card's contract — Home's focus diagnostics
    /// need to know when a Continue Watching card takes or
    /// leaves focus. Default nil: every existing call site
    /// is unchanged.
    var onFocusChange: ((Bool) -> Void)? = nil

    @Environment(\.tvTheme) private var theme
    @FocusState private var isFocused: Bool

    init(record: HistoryRecord,
         width: CGFloat = 400,
         onSelect: @escaping () -> Void,
         onLongPress: @escaping () -> Void,
         onFocusChange: ((Bool) -> Void)? = nil) {
        self.record = record
        self.width = width
        self.onSelect = onSelect
        self.onLongPress = onLongPress
        self.onFocusChange = onFocusChange
    }

    private var artHeight: CGFloat { width * 9 / 16 }
    private var artRadius: CGFloat { 18 }

    var body: some View {
        Button {
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                art
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.movie.title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .frame(width: width, alignment: .leading)
                    if !record.pluginName.isEmpty {
                        Text(record.pluginName)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(theme.textFaint)
                            .lineLimit(1)
                            .frame(width: width, alignment: .leading)
                    }
                }
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .tvCardButton()
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in onFocusChange?(focused) }
        .onLongPressGesture(minimumDuration: 0.5) {
            onLongPress()
        }
    }

    private var art: some View {
        ZStack {
            RoundedRectangle(cornerRadius: artRadius, style: .continuous)
                .fill(theme.cardFill)
            TVRemoteImage(urlString: record.movie.displayBackdrop,
                          headers: record.movie.sourcePageURL.map { ["Referer": $0] } ?? [:],
                          bucket: 720)
        }
        .frame(width: width, height: artHeight)
        .overlay {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: Color.black.opacity(0.78), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 10) {
                Image(systemName: record.isManga ? "book.fill" : "play.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                if !record.episodeName.isEmpty {
                    Text(record.episodeName)
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.leading, 16)
            .padding(.bottom, showProgress ? 18 : 12)
        }
        .overlay(alignment: .bottom) {
            if showProgress {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(theme.accent)
                        .frame(width: width * CGFloat(record.progress))
                }
                .frame(height: 5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: artRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: artRadius, style: .continuous)
                .fill(Color.white.opacity(isFocused ? 0.08 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: artRadius, style: .continuous)
                .strokeBorder(isFocused ? theme.focusRing : .clear,
                              lineWidth: isFocused ? theme.ringWidth : 0)
        }
    }

    private var showProgress: Bool {
        !record.isManga && record.duration > 0 && record.progress > 0
    }
}

// MARK: - Chip (plugin switcher / filters)

/// Capsule chip: selected = black text on the accent fill;
/// unselected = white text on cardFill with a cardStroke edge.
/// Optional leading icon and an amber "18+" marker. Focus is
/// the inset capsule ring in the theme's focus colour.
struct TVChip: View {
    let title: String
    var iconURL: String? = nil
    var badge18: Bool = false
    let selected: Bool
    let onSelect: () -> Void
    /// A-7 (1.3.9): an optional EXTERNAL entry-focus binding
    /// (the Settings screen's landing focus). When handed in
    /// it replaces the chip's own focus binding — exactly one
    /// binding is ever attached — and the ring reads both
    /// states, so the chip that carries a screen's entry
    /// focus still draws its ring.
    var entryFocus: FocusState<Bool>.Binding? = nil
    /// L-T41 (1.3.15): an optional focus-change hook, the
    /// poster card's contract — Home's focus diagnostics
    /// need to know when a chip takes or leaves focus.
    /// Default nil: every existing call site is unchanged.
    var onFocusChange: ((Bool) -> Void)? = nil
    /// 1.3.19 (L-T48): an optional VALUE-form focus identity —
    /// the chip is focused exactly when `valueFocus` holds
    /// `focusID`. Home gives every chip on its rail the SAME
    /// String? FocusState with the chip's own plugin id, so a
    /// chip's focus identity never changes when the active
    /// plugin does (the 1.3.15 shape moved ONE Bool binding from
    /// chip to chip, and each move bounced focus). When handed
    /// in it replaces both other bindings.
    var valueFocus: FocusState<String?>.Binding? = nil
    var focusID: String? = nil

    @Environment(\.tvTheme) private var theme
    @FocusState private var isFocused: Bool

    init(title: String,
         iconURL: String? = nil,
         badge18: Bool = false,
         selected: Bool,
         entryFocus: FocusState<Bool>.Binding? = nil,
         valueFocus: FocusState<String?>.Binding? = nil,
         focusID: String? = nil,
         onFocusChange: ((Bool) -> Void)? = nil,
         onSelect: @escaping () -> Void) {
        self.title = title
        self.iconURL = iconURL
        self.badge18 = badge18
        self.selected = selected
        self.entryFocus = entryFocus
        self.valueFocus = valueFocus
        self.focusID = focusID
        self.onFocusChange = onFocusChange
        self.onSelect = onSelect
    }

    private var focusActive: Bool {
        if let valueFocus, let focusID {
            return valueFocus.wrappedValue == focusID
        }
        return isFocused || (entryFocus?.wrappedValue ?? false)
    }

    @ViewBuilder
    var body: some View {
        if let valueFocus, let focusID {
            button
                .focused(valueFocus, equals: focusID)
                .onChange(of: focusActive) { _, focused in onFocusChange?(focused) }
        } else {
            button
                .focused(entryFocus ?? $isFocused)
                .onChange(of: focusActive) { _, focused in onFocusChange?(focused) }
        }
    }

    private var button: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 12) {
                if let iconURL, !iconURL.isEmpty {
                    CachedAsyncImage(urlString: iconURL)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
                if badge18 {
                    Text("18+")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(theme.badgeQuality)
                }
            }
            .foregroundStyle(selected ? theme.onAccent : theme.textPrimary)
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .background(Capsule().fill(selected ? theme.accent : theme.cardFill))
            .overlay(Capsule().strokeBorder(
                focusActive ? theme.focusRing : (selected ? Color.clear : theme.cardStroke),
                lineWidth: focusActive ? theme.ringWidth : 1.5))
            .contentShape(Capsule())
        }
        .tvCardButton()
    }
}

// MARK: - Backdrop

/// Full-screen backdrop: the image (bucket 1920, .fill) under
/// the theme's scrim gradients. Fills its container exactly;
/// `.ignoresSafeArea()` is the CALLER's job. The vertical scrim
/// comes from the tokens (study §2.4 — Ultra detail stops; the
/// Original theme's iOS hero fade); a leading horizontal scrim
/// keeps the text zone readable, byte-matched to the Ultra
/// detail stops under Ultra.
///
/// Stand-in when `urlString` is empty: the theme background
/// gradient plus the fallback title in large faint text — a
/// designed no-backdrop tile (FL-156), never a broken hole.
/// When the URL is a portrait poster, the .fill crop is
/// acceptable (content identity preserved).
struct TVBackdropView: View {
    let urlString: String
    /// FL-488: image headers (the serving page as Referer when
    /// the caller has one); empty = today's behaviour.
    var headers: [String: String] = [:]
    let fallbackTitle: String
    /// NEXT-D D2 (1.3.0, study §3.1 option (a)): the preview
    /// layer slot — a resolved preview stream fades in BETWEEN
    /// the still image and the scrims. Call sites that pass no
    /// preview keep today's exact rendering.
    var previewStream: StreamInfo? = nil
    var previewGeneration: Int = 0
    var onPreviewRetired: ((String) -> Void)? = nil

    @Environment(\.tvTheme) private var theme
    @State private var imageFailed = false
    @State private var previewVisible = false

    /// ONE explicit init covering every stored property
    /// (review-gate fix, 1.3.0): declaring this init suppresses
    /// the memberwise init, so the preview properties must be
    /// parameters here — with defaults, so call sites that pass
    /// no preview stay terse.
    init(urlString: String, headers: [String: String] = [:], fallbackTitle: String,
         previewStream: StreamInfo? = nil,
         previewGeneration: Int = 0,
         onPreviewRetired: ((String) -> Void)? = nil) {
        self.urlString = urlString
        self.headers = headers
        self.fallbackTitle = fallbackTitle
        self.previewStream = previewStream
        self.previewGeneration = previewGeneration
        self.onPreviewRetired = onPreviewRetired
    }

    /// Designed stand-in for the no-backdrop case — also used
    /// when the backdrop image fails to load.
    private var standIn: some View {
        ZStack {
            theme.backgroundGradient
            Text(fallbackTitle)
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(theme.textFaint)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(80)
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if urlString.isEmpty {
                    standIn
                } else {
                    TVRemoteImage(urlString: urlString, headers: headers, bucket: 1920, contentMode: .fill, failed: $imageFailed)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    if imageFailed {
                        standIn
                    }
                }
                // NEXT-D preview layer: still → video → scrims.
                // Opacity 0 until the host reports the first
                // frame (ready AND playing); retirement fades
                // it back out and the owner clears the stream.
                if let previewStream {
                    TVBackdropPreviewHost(
                        stream: previewStream,
                        onFirstFrame: {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                previewVisible = true
                            }
                        },
                        onRetire: { reason in
                            withAnimation(.easeInOut(duration: 0.6)) {
                                previewVisible = false
                            }
                            onPreviewRetired?(reason)
                        })
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .opacity(previewVisible ? 1 : 0)
                        .id(previewGeneration)
                }
                // Horizontal scrim (text zone, leading → trailing).
                LinearGradient(
                    stops: theme.isUltra
                        ? [.init(color: Color.black.opacity(0.85), location: 0),
                           .init(color: Color.black.opacity(0.40), location: 0.5),
                           .init(color: Color.black.opacity(0.05), location: 1)]
                        : [.init(color: Color.black.opacity(0.60), location: 0),
                           .init(color: Color.black.opacity(0.30), location: 0.5),
                           .init(color: .clear, location: 1)],
                    startPoint: .leading, endPoint: .trailing
                )
                // Vertical scrim from the tokens.
                theme.backdropScrim
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onChange(of: urlString) { imageFailed = false }
        .onChange(of: previewGeneration) { previewVisible = false }
    }
}

// MARK: - Empty / error states

/// Shared capsule action label for the state surfaces: accent
/// fill, inset focus ring.
private struct TVStateActionLabel: View {
    let title: String
    let isFocused: Bool

    @Environment(\.tvTheme) private var theme

    var body: some View {
        Text(title)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, 38)
            .padding(.vertical, 16)
            .background(Capsule().fill(theme.accent))
            .overlay(Capsule().strokeBorder(
                isFocused ? theme.focusRing : .clear,
                lineWidth: isFocused ? theme.ringWidth : 0))
    }
}

/// Designed empty surface: centred icon + title (+ message),
/// with an optional focusable action button. The action can
/// opt in to being the default focus via `actionIsDefaultFocus`
/// (default false, so existing call sites are unchanged): a
/// state surface that is the ONLY focusable on a pushed screen
/// must declare its landing, otherwise the screen is a focus
/// dead state.
struct TVEmptyState: View {
    let icon: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var actionIsDefaultFocus: Bool = false
    /// L-T41 (1.3.15): an optional focus-change hook for
    /// the action button, the poster card's contract —
    /// Home's focus diagnostics need to know when an empty
    /// state's button takes or leaves focus. Default nil:
    /// every existing call site is unchanged.
    var onFocusChange: ((Bool) -> Void)? = nil

    @Environment(\.tvTheme) private var theme
    @FocusState private var actionFocused: Bool

    init(icon: String,
         title: String,
         message: String? = nil,
         actionTitle: String? = nil,
         action: (() -> Void)? = nil,
         actionIsDefaultFocus: Bool = false,
         onFocusChange: ((Bool) -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.actionIsDefaultFocus = actionIsDefaultFocus
        self.onFocusChange = onFocusChange
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(theme.textFaint)
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.system(size: 24))
                    .foregroundStyle(theme.textDim)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button {
                    action()
                } label: {
                    TVStateActionLabel(title: actionTitle, isFocused: actionFocused)
                }
                .tvCardButton()
                .focused($actionFocused)
                .onChange(of: actionFocused) { _, focused in onFocusChange?(focused) }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
        .defaultFocus($actionFocused, actionIsDefaultFocus && action != nil)
    }
}

/// Designed loading surface: spinner + message + a focusable
/// "Thử lại" button built exactly like TVErrorState's retry
/// (TVStateActionLabel + tvCardButton + own @FocusState), so a
/// loading screen is never a focus dead zone. The retry button
/// is the default focus inside the component.
struct TVLoadingState: View {
    let message: String
    let onRetry: () -> Void

    @Environment(\.tvTheme) private var theme
    @FocusState private var retryFocused: Bool

    init(message: String = "Đang tải…", onRetry: @escaping () -> Void) {
        self.message = message
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .tint(.white)
            Text(message)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            Button {
                onRetry()
            } label: {
                TVStateActionLabel(title: "Thử lại", isFocused: retryFocused)
            }
            .tvCardButton()
            .focused($retryFocused)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
        .defaultFocus($retryFocused, true)
    }
}

/// Designed error surface with a focusable "Thử lại" button.
/// `retryIsDefaultFocus` is the flow audit's A-9 opt-in (an
/// error surface that is the only focusable on its screen
/// must declare its landing — the actor screen passes true,
/// audit P-4); default false keeps existing call sites as-is.
struct TVErrorState: View {
    let message: String
    let onRetry: () -> Void
    var retryIsDefaultFocus: Bool = false

    @Environment(\.tvTheme) private var theme
    @FocusState private var retryFocused: Bool

    init(message: String, onRetry: @escaping () -> Void, retryIsDefaultFocus: Bool = false) {
        self.message = message
        self.onRetry = onRetry
        self.retryIsDefaultFocus = retryIsDefaultFocus
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(theme.badgeQuality)
            Text(message)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            Button {
                onRetry()
            } label: {
                TVStateActionLabel(title: "Thử lại", isFocused: retryFocused)
            }
            .tvCardButton()
            .focused($retryFocused)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
        .defaultFocus($retryFocused, retryIsDefaultFocus)
    }
}

// MARK: - Engine focus probe (shared, 1.3.19)

/// Where the ENGINE says focus is — read from
/// `UIFocusSystem.focusedItem`, the UIKit-level witness SwiftUI's
/// FocusState hooks cannot be. Moved here from Home's private
/// tracker (L-T43, 1.3.17) so the Browse screen's landing check
/// can ask the same question. The classes: `focusedItem == nil`
/// → .nowhere (a genuine void); an item with a UITabBar ancestor
/// → .onTabBar (focus belongs to the shell); anything else →
/// .inWindow. The description is the moveFail line's format:
/// item class, a `tabbar:` marker, the folded accessibility
/// label (ids/labels only — the DiagLog discipline) — or "nil".
enum TVFocusProbe {
    enum Place {
        case nowhere
        case onTabBar
        case inWindow
    }

    struct Reading {
        let state: Place
        let description: String
        var label: String {
            switch state {
            case .nowhere: return "nowhere"
            case .onTabBar: return "tabbar"
            case .inWindow: return "window"
            }
        }
    }

    @MainActor
    static func engineFocus() -> Reading {
        guard let window = activeKeyWindow() else {
            return Reading(state: .nowhere, description: "nil")
        }
        return classify(UIFocusSystem(for: window)?.focusedItem)
    }

    /// 1.3.20: the classification on its own, so the focus
    /// monitor can classify the `nextFocusedItem` of a focus
    /// update without re-reading the engine.
    @MainActor
    static func classify(_ item: UIFocusItem?) -> Reading {
        guard let item else { return Reading(state: .nowhere, description: "nil") }
        var desc = String(describing: type(of: item))
        var onTabBar = false
        if let view = item as? UIView {
            var ancestor: UIView? = view
            while let a = ancestor {
                if a is UITabBar {
                    onTabBar = true
                    break
                }
                ancestor = a.superview
            }
            if onTabBar { desc = "tabbar:" + desc }
            if let label = view.accessibilityLabel, !label.isEmpty {
                let folded = label.replacingOccurrences(of: " ", with: "_")
                desc += " label=\(String(folded.prefix(40)))"
            }
        }
        return Reading(state: onTabBar ? .onTabBar : .inWindow, description: desc)
    }

    @MainActor
    static func activeKeyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState == .foregroundActive
            else { continue }
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
            return windowScene.windows.first
        }
        return nil
    }
}

// MARK: - Engine focus monitor (1.3.20)

/// The app-wide, PASSIVE witness of where the focus ENGINE put
/// focus after every update — `UIFocusSystem.didUpdateNotification`,
/// classified by TVFocusProbe into tab bar / window / nowhere.
///
/// Why it exists (log_9): Home's hooks only see Home elements, so
/// every move onto the TAB BAR read as `home lost …` with no gain
/// anywhere (11:58:46.772 — the owner's "focus vanished" moment
/// was focus going to the tab bar, then a second Menu press
/// exiting the app). The monitor writes one `[focus] engine
/// place=…` line whenever the CLASS of the focused item changes
/// (tab bar ↔ content ↔ nowhere), so every `lost` now pairs with
/// a destination in the log.
///
/// It also drives behaviour: the root Menu net is installed only
/// while focus is NOT in content (TVRootView), and Home/Browse
/// rescue a void (`place == .nowhere` that lasts) onto a stable
/// element. Created once by TVRootView, injected through the
/// environment. Main-actor only.
@MainActor
@Observable
final class TVFocusMonitor {
    private(set) var place: TVFocusProbe.Place = .inWindow
    /// Bumped on every transition INTO .nowhere — the void
    /// rescues key off it.
    private(set) var voidEpoch = 0
    @ObservationIgnored private var token: NSObjectProtocol?

    func install() {
        guard token == nil else { return }
        place = TVFocusProbe.engineFocus().state
        token = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
                self?.update(TVFocusProbe.classify(context?.nextFocusedItem))
            }
        }
        DiagLog.log("focus", "engine monitor installed place=\(TVFocusProbe.engineFocus().label)")
    }

    private func update(_ reading: TVFocusProbe.Reading) {
        guard reading.state != place else { return }
        place = reading.state
        if reading.state == .nowhere { voidEpoch &+= 1 }
        DiagLog.log("focus", "engine place=\(reading.label) item=\(reading.description)")
    }
}

// MARK: - Tab-bar focus bridge (1.3.20, F-1/F-2)

/// UP from the content's top row must always reach the tab bar
/// (the owner's "main menu").
///
/// log_9: every run of dead presses on a chip in the MIDDLE or
/// RIGHT of the source rail was the owner pressing UP to reach
/// the menu — misskon 11:57:47.500–47.928 (4×, arriving from the
/// header below, pressing up), hentaihub 11:58:20.792–22.315 (5×,
/// arriving UP from the hero). UP worked only from the chips that
/// sit under the tab bar's own buttons (missav 11:58:40.547,
/// 123av 11:56:34.213, sextop1 11:57:00.755): the focus engine
/// searches straight up, the tab bar's buttons cover only part of
/// the screen's width, and a chip with no tab button above it has
/// no candidate. He then walked the rail end to end hunting for a
/// spot where UP worked (the row-end runs at javmost and missav),
/// found it at missav, and finally left with Menu.
///
/// The bridge is the platform's own tool for exactly this gap: a
/// `UIFocusGuide` spanning the FULL width of the window along its
/// top edge, whose preferred focus environment is the tab bar.
/// An UP search from anywhere along the top row now meets the
/// guide and is redirected to the tab bar (its selected tab). It
/// sits above everything, so no DOWN/LEFT/RIGHT search from the
/// content can reach it, and a search from the tab bar itself is
/// redirected to the tab bar (a no-op). Installed in the tab bar
/// controller's view (idempotent), re-pointed when the tab bar
/// instance changes (the PIN gate rebuilds the root).
@MainActor
enum TVTabBarFocusBridge {
    private static weak var guide: UIFocusGuide?
    private static weak var tabBar: UITabBar?
    /// Whether the bridge should be live: only while the
    /// selected tab's stack is at its ROOT (TVRootView drives
    /// it). On a pushed screen Back is the way home, and a wide
    /// UP-to-tab-bar would only pull focus out of the screen —
    /// where its own Back can no longer receive the press.
    private static var wanted = true

    static func setEnabled(_ enabled: Bool) {
        wanted = enabled
        guide?.isEnabled = enabled
    }

    /// Returns a short status for the log line.
    @discardableResult
    static func install(reason: String) -> String {
        guard let window = TVFocusProbe.activeKeyWindow() else {
            DiagLog.log("focus", "tabbar-bridge unavailable reason=no-window via=\(reason)")
            return "no-window"
        }
        guard let bar = findTabBar(in: window) else {
            DiagLog.log("focus", "tabbar-bridge unavailable reason=no-tabbar via=\(reason)")
            return "no-tabbar"
        }
        // The guide lives in the TAB BAR CONTROLLER's own view
        // (the TabView's hierarchy), not on the window: when a
        // full-screen cover (the player, the filter sheet) is
        // presented, that hierarchy is outside the focus scope,
        // so the guide cannot redirect anything there.
        guard let host = owningController(of: bar)?.view ?? bar.superview else {
            DiagLog.log("focus", "tabbar-bridge unavailable reason=no-host via=\(reason)")
            return "no-host"
        }
        if let guide, guide.owningView === host {
            if tabBar !== bar {
                guide.preferredFocusEnvironments = [bar]
                tabBar = bar
                DiagLog.log("focus", "tabbar-bridge repointed tabs=\(bar.items?.count ?? 0) via=\(reason)")
                return "repointed"
            }
            return "present"
        }
        let newGuide = UIFocusGuide()
        host.addLayoutGuide(newGuide)
        NSLayoutConstraint.activate([
            newGuide.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            newGuide.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            newGuide.topAnchor.constraint(equalTo: host.topAnchor),
            newGuide.heightAnchor.constraint(equalToConstant: 2)
        ])
        newGuide.preferredFocusEnvironments = [bar]
        newGuide.isEnabled = wanted
        guide = newGuide
        tabBar = bar
        DiagLog.log("focus", "tabbar-bridge installed host=\(String(describing: type(of: host))) width=\(Int(host.bounds.width)) tabs=\(bar.items?.count ?? 0) via=\(reason)")
        return "installed"
    }

    /// The UITabBarController that owns this tab bar, found
    /// through the responder chain.
    private static func owningController(of bar: UITabBar) -> UITabBarController? {
        var responder: UIResponder? = bar.next
        while let r = responder {
            if let controller = r as? UITabBarController { return controller }
            responder = r.next
        }
        return nil
    }

    private static func findTabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for sub in view.subviews {
            if let found = findTabBar(in: sub) { return found }
        }
        return nil
    }
}
