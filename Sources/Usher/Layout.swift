import CoreGraphics

/// Where the focused window and each side window go. `side[i]` belongs to the i-th most recent other window;
/// windows past `side.count` are left where they are.
struct LayoutPlan {
    var main: CGRect
    var side: [CGRect]
}

/// Picks a layout that keeps every window a usable shape instead of slicing the leftover space into strips.
enum Layout {
    /// Smaller than this and most apps are cramped or refuse to shrink.
    static let minCell = CGSize(width: 640, height: 420)
    /// A "third" on a laptop would be too narrow to use.
    static let minMainWidth: CGFloat = 900
    static let maxSideWindows = 6
    /// Leaving a window untiled costs about as much as one badly shaped cell.
    static let dropCost: CGFloat = 0.25

    static func plan(area: CGRect, share: Share, sideCount: Int, gap: CGFloat) -> LayoutPlan {
        if share == .full { return LayoutPlan(main: area, side: []) }

        let width = area.width
        let mainWidth = min(width, max(floor(width * share.fraction), min(minMainWidth, width)))
        let wanted = min(sideCount, maxSideWindows)

        // Nothing to share the screen with: center the window instead of pinning it to the left edge.
        if wanted == 0 {
            return LayoutPlan(main: CGRect(x: floor(area.midX - mainWidth / 2), y: area.minY, width: mainWidth, height: area.height), side: [])
        }

        // On an ultrawide, a half-or-narrower window reads best in the middle, with side windows on both flanks.
        let ultrawide = width / area.height >= 2
        let centered = ultrawide && share.fraction <= 0.5 && wanted >= 2
        let main: CGRect
        var regions: [CGRect]
        if centered {
            let flank = floor((width - mainWidth - 2 * gap) / 2)
            main = CGRect(x: area.minX + flank + gap, y: area.minY, width: mainWidth, height: area.height)
            regions = [
                CGRect(x: main.maxX + gap, y: area.minY, width: area.maxX - main.maxX - gap, height: area.height),
                CGRect(x: area.minX, y: area.minY, width: flank, height: area.height),
            ]
        } else {
            main = CGRect(x: area.minX, y: area.minY, width: mainWidth, height: area.height)
            regions = [CGRect(x: main.maxX + gap, y: area.minY, width: area.maxX - main.maxX - gap, height: area.height)]
        }
        regions = regions.filter { $0.width > 0 }

        // Try tiling every window, then fewer, and keep whichever leaves the best-shaped cells.
        var best: (score: CGFloat, side: [CGRect])?
        for count in stride(from: wanted, through: 1, by: -1) {
            let counts = split(count, into: regions.count)
            var cells: [[CGRect]] = []
            var score = CGFloat(wanted - count) * dropCost
            var valid = true
            for (region, n) in zip(regions, counts) where n > 0 {
                guard let grid = bestGrid(in: region, count: n, gap: gap) else { valid = false; break }
                cells.append(grid.cells)
                score += grid.score
            }
            guard valid else { continue }
            let side = interleave(cells)
            if best == nil || score < best!.score { best = (score, side) }
        }
        return LayoutPlan(main: main, side: best?.side ?? [])
    }

    /// 0 for normal window shapes, rising for strips (too wide) and slivers (too tall).
    static func shapePenalty(_ size: CGSize) -> CGFloat {
        let aspect = size.width / size.height
        return max(0, log(aspect / 1.8)) + max(0, log(0.65 / aspect))
    }

    /// Rows of near-equal size; a short last row stretches its windows to fill the width rather than leaving a hole.
    private static func bestGrid(in region: CGRect, count: Int, gap: CGFloat) -> (cells: [CGRect], score: CGFloat)? {
        var best: (cells: [CGRect], score: CGFloat)?
        for rows in 1...count {
            let perRow = split(count, into: rows)
            let height = floor((region.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
            var cells: [CGRect] = []
            var total: CGFloat = 0
            var fits = height >= minCell.height
            for (r, cols) in perRow.enumerated() where fits {
                let width = floor((region.width - gap * CGFloat(cols - 1)) / CGFloat(cols))
                if width < minCell.width { fits = false; break }
                for c in 0..<cols {
                    let cell = CGRect(x: region.minX + CGFloat(c) * (width + gap),
                                      y: region.minY + CGFloat(r) * (height + gap),
                                      width: width, height: height)
                    cells.append(cell)
                    total += shapePenalty(cell.size)
                }
            }
            guard fits else { continue }
            let score = total / CGFloat(count)
            if best == nil || score < best!.score { best = (cells, score) }
        }
        return best
    }

    /// Splits n into k parts that differ by at most one, larger parts first.
    private static func split(_ n: Int, into k: Int) -> [Int] {
        guard k > 0 else { return [] }
        return (0..<k).map { n / k + ($0 < n % k ? 1 : 0) }
    }

    /// Alternates between regions so the most recent windows land next to the main window on both sides.
    private static func interleave(_ groups: [[CGRect]]) -> [CGRect] {
        var out: [CGRect] = []
        for i in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where i < group.count { out.append(group[i]) }
        }
        return out
    }
}
