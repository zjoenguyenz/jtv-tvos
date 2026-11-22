import CoreGraphics
import Foundation

/// One page of a manga image in PIXEL space: a contiguous
/// vertical crop of the decoded image (y from the image's top,
/// matching CGImage.cropping's coordinate convention — the
/// convention the 1.3.2 reader's fixed cuts already use).
struct TVMangaPageRect: Equatable {
    let y: Int
    let height: Int
}

/// JTV tvOS 1.3.3 — gutter-snapped page planning (L-T27 /
/// FL-412, owner-approved method A′; spec:
/// RESEARCH-SAYHENTAI-READING-2026-11-22.md §6).
///
/// The 1.3.2 reader cut every strip at fixed screen-ratio
/// offsets with zero content analysis, so the blade landed
/// mid-panel and mid-speech-bubble (owner's device verdict:
/// "Cách cắt trang của sayhentai không sài được"). This planner
/// changes ONLY where the cuts land; the reader's page-turn
/// frame (discrete turns, Trang X/Y, chapter chaining) is
/// untouched.
///
/// Scoping is by per-image DATA SHAPE, never by plugin name
/// (research §7):
/// • height ≤ one screen → one page, the whole image.
/// • a DISCRETE image (height < 3 screens — the misskon
///   shape: measured 1024×1536 = 2.7 screens at full width)
///   → one page, the whole image, kept as a single unit.
/// • a TALL STRIP (height ≥ 3 screens — the sayhentai shape:
///   measured 8.6–49 screens) → gutter-snapped packing:
///   detect near-uniform horizontal bands (panel gutters),
///   pack whole inter-gutter segments greedily into pages of
///   at most one screen height; a segment that ALONE exceeds
///   a screen is sub-cut inside itself (weakest local gutter
///   first, fixed cut as the last resort); if no gutter is
///   found at all, the plan degrades to exactly the 1.3.2
///   fixed-cut geometry — never worse than the status quo.
///
/// Thresholds are the research's measured working point (§2/§6):
/// rows are sampled on a grayscale copy at most 200 px wide;
/// a row is a STRICT gutter row when its standard deviation
/// is < 7 and ≥ 97% of its pixels lie within ±10 of the row
/// median (black and white gutters both qualify — the test is
/// uniformity, not brightness); a WEAK gutter row relaxes to
/// std < 14 and ≥ 93% within ±16. A strict band is a run of
/// ≥ 6 strict rows, a weak band ≥ 4 weak rows. Segments
/// shorter than 48 px (lettering gaps inside a panel, research
/// §2.3) NEVER stand alone as a page: a post-pass merges any
/// sub-48 px page into its neighbour (the previous page, or
/// the next one when it is the first) — unconditionally, per
/// §6 ("không bao giờ đứng một mình — luôn gộp với đoạn kề");
/// the merged crop may exceed one screen height by less than
/// 48 px and simply renders aspect-fit, whole, like a
/// discrete image.
///
/// Cost: one pass over a ≤200-px-wide grayscale copy —
/// measured ≈0.1 s per strip on the shared VM for the
/// reference implementation (research §4A′); it runs once per
/// strip at decode time inside the reader's existing load
/// tasks, never in the view body.
enum TVMangaPagePlanner {

    // MARK: Working point (research §6)

    private static let scanWidthCap = 200
    private static let strictStdMax = 7.0
    private static let strictWithinBand = 10
    private static let strictWithinFraction = 0.97
    private static let weakStdMax = 14.0
    private static let weakWithinBand = 16
    private static let weakWithinFraction = 0.93
    private static let strictBandMinRows = 6
    private static let weakBandMinRows = 4
    private static let microSegmentFloor = 48
    /// An image at least this many screens tall is a strip;
    /// below it, a discrete page image (measured gap between
    /// the two shapes: misskon 2.7 screens vs sayhentai 8.6).
    private static let stripScreenMultiple = 3

    // MARK: Plan

    static func plan(cgImage cg: CGImage, segmentHeight segH: Int) -> [TVMangaPageRect] {
        let height = cg.height
        guard segH > 0, height > 0 else {
            return [TVMangaPageRect(y: 0, height: max(1, height))]
        }
        if height <= segH {
            return [TVMangaPageRect(y: 0, height: height)]
        }
        // Discrete image — one unit, whole (the misskon shape).
        if height < stripScreenMultiple * segH {
            return [TVMangaPageRect(y: 0, height: height)]
        }
        let (strictBands, weakBands) = gutterBands(of: cg)
        guard !strictBands.isEmpty else {
            // Detection failure degrades to the 1.3.2 geometry.
            return mergeMicroPages(fixedPlan(height: height, segmentHeight: segH))
        }
        // Content segments: the runs between strict bands.
        var segments: [(start: Int, end: Int)] = []
        var cursor = 0
        for band in strictBands {
            if band.start > cursor { segments.append((cursor, band.start)) }
            cursor = max(cursor, band.end)
        }
        if cursor < height { segments.append((cursor, height)) }
        guard segments.count > 1 else {
            return mergeMicroPages(fixedPlan(height: height, segmentHeight: segH))
        }
        // Split over-tall segments first (weakest local gutter
        // inside the screen window, else a fixed cut), so the
        // packing pass below only ever sees screen-fitting
        // pieces.
        var pieces: [(start: Int, end: Int)] = []
        for segment in segments {
            guard segment.end - segment.start > segH else {
                pieces.append(segment)
                continue
            }
            var y = segment.start
            while segment.end - y > segH {
                let limit = y + segH
                // §6: the sub-cut lands at the WEAKEST weak
                // gutter inside the window — the band whose
                // rows are least uniform (highest worst-row
                // std) while still qualifying as a weak band;
                // ties go to the deepest band. The piece ends
                // at the band's START (≤ limit, so the piece
                // never exceeds one screen height) and reading
                // resumes at the band's END: the near-uniform
                // band rows themselves are gutter, shown on no
                // page.
                var cutEnd: Int?
                var resumeY = limit
                var weakestStrength = -1.0
                for band in weakBands
                where band.start > y + microSegmentFloor && band.start <= limit {
                    if band.strength > weakestStrength
                        || (band.strength == weakestStrength
                            && (cutEnd == nil || band.start > cutEnd!)) {
                        weakestStrength = band.strength
                        cutEnd = band.start
                        resumeY = band.end
                    }
                }
                if let cutEnd {
                    pieces.append((y, cutEnd))
                    y = resumeY
                } else {
                    pieces.append((y, limit))
                    y = limit
                }
            }
            if segment.end > y { pieces.append((y, segment.end)) }
        }
        // Greedy packing: accumulate whole pieces while the
        // crop (first piece's start → last piece's end, the
        // thin gutters between them included) fits one screen.
        var rects: [TVMangaPageRect] = []
        var i = 0
        while i < pieces.count {
            let start = pieces[i].start
            var j = i
            while j + 1 < pieces.count, pieces[j + 1].end - start <= segH {
                j += 1
            }
            rects.append(TVMangaPageRect(y: start, height: pieces[j].end - start))
            i = j + 1
        }
        return rects.isEmpty
            ? mergeMicroPages(fixedPlan(height: height, segmentHeight: segH))
            : mergeMicroPages(rects)
    }

    /// §6's micro-segment rule, applied as a post-pass over
    /// every strip plan (gutter-packed and fixed alike): a
    /// page shorter than the 48 px floor NEVER stands alone —
    /// it merges into the previous page (or the next one when
    /// it is the first page), the merged crop spanning from
    /// the keeper's start to the micro page's end, gutter rows
    /// between them included. Unconditional: the merged crop
    /// may exceed one screen height by less than the floor
    /// and renders aspect-fit, whole. Repeats until no micro
    /// page remains (a merge can itself follow a micro page).
    static func mergeMicroPages(_ rects: [TVMangaPageRect]) -> [TVMangaPageRect] {
        var rects = rects
        var changed = true
        while changed, rects.count > 1 {
            changed = false
            for i in rects.indices where rects[i].height < microSegmentFloor {
                if i > 0 {
                    let prev = rects[i - 1]
                    let cur = rects[i]
                    rects[i - 1] = TVMangaPageRect(
                        y: prev.y, height: (cur.y + cur.height) - prev.y)
                    rects.remove(at: i)
                } else {
                    let cur = rects[0]
                    let next = rects[1]
                    rects[0] = TVMangaPageRect(
                        y: cur.y, height: (next.y + next.height) - cur.y)
                    rects.remove(at: 1)
                }
                changed = true
                break
            }
        }
        return rects
    }

    /// The 1.3.2 geometry verbatim: cuts at fixed multiples of
    /// the segment height. The degradation floor of every
    /// failure path above.
    static func fixedPlan(height: Int, segmentHeight segH: Int) -> [TVMangaPageRect] {
        guard segH > 0, height > 0 else {
            return [TVMangaPageRect(y: 0, height: max(1, height))]
        }
        var rects: [TVMangaPageRect] = []
        var y = 0
        while y < height {
            let h = min(segH, height - y)
            rects.append(TVMangaPageRect(y: y, height: h))
            y += h
        }
        return rects
    }

    // MARK: Gutter scan

    /// Strict and weak gutter bands of the image, as
    /// (start, end, strength) in top-origin pixel space,
    /// ascending. Strength is the band's WORST (highest)
    /// row standard deviation — the sub-cut's weakest-gutter
    /// ranking (§6) compares it across weak bands. The scan
    /// draws the image into a grayscale context at most
    /// `scanWidthCap` px wide and the FULL height (rows are
    /// never resampled vertically, so band positions are
    /// exact image rows). The context is flipped so buffer
    /// row 0 is the image's TOP row — the same top-origin
    /// space CGImage.cropping uses.
    private static func gutterBands(of cg: CGImage)
        -> (strict: [(start: Int, end: Int, strength: Double)],
            weak: [(start: Int, end: Int, strength: Double)]) {
        let width = min(cg.width, scanWidthCap)
        let height = cg.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let base = context.data else {
            return ([], [])
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = base.bindMemory(to: UInt8.self, capacity: width * height)

        var strictRows = [Bool](repeating: false, count: height)
        var weakRows = [Bool](repeating: false, count: height)
        var rowStd = [Double](repeating: 0, count: height)
        var histogram = [Int](repeating: 0, count: 256)
        for row in 0..<height {
            for i in histogram.indices { histogram[i] = 0 }
            let offset = row * width
            var sum = 0
            for x in 0..<width {
                let v = Int(bytes[offset + x])
                histogram[v] += 1
                sum += v
            }
            let mean = Double(sum) / Double(width)
            var cumulative = 0
            var median = 0
            for v in 0..<256 {
                cumulative += histogram[v]
                if cumulative * 2 >= width { median = v; break }
            }
            var squared = 0.0
            for v in 0..<256 where histogram[v] > 0 {
                let d = Double(v) - mean
                squared += d * d * Double(histogram[v])
            }
            let std = (squared / Double(width)).squareRoot()
            rowStd[row] = std
            if std < strictStdMax {
                var within = 0
                let lo = max(0, median - strictWithinBand)
                let hi = min(255, median + strictWithinBand)
                for v in lo...hi { within += histogram[v] }
                strictRows[row] = Double(within) >= strictWithinFraction * Double(width)
            }
            if std < weakStdMax {
                var within = 0
                let lo = max(0, median - weakWithinBand)
                let hi = min(255, median + weakWithinBand)
                for v in lo...hi { within += histogram[v] }
                weakRows[row] = Double(within) >= weakWithinFraction * Double(width)
            }
        }
        return (bands(from: strictRows, stds: rowStd, minRows: strictBandMinRows),
                bands(from: weakRows, stds: rowStd, minRows: weakBandMinRows))
    }

    /// Maximal runs of `true` rows at least `minRows` long, as
    /// (start, end, strength) with end exclusive, ascending;
    /// strength = the highest row std inside the run.
    private static func bands(from rows: [Bool], stds: [Double], minRows: Int)
        -> [(start: Int, end: Int, strength: Double)] {
        var result: [(start: Int, end: Int, strength: Double)] = []
        var runStart: Int?
        func closeRun(end: Int) {
            guard let start = runStart, end - start >= minRows else { return }
            var strength = 0.0
            for row in start..<end where stds[row] > strength {
                strength = stds[row]
            }
            result.append((start, end, strength))
        }
        for (index, flag) in rows.enumerated() {
            if flag {
                if runStart == nil { runStart = index }
            } else if runStart != nil {
                closeRun(end: index)
                runStart = nil
            }
        }
        if runStart != nil { closeRun(end: rows.count) }
        return result
    }
}
