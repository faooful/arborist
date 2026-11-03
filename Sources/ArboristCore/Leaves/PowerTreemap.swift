import Foundation

/// Weighted (power-diagram) Voronoi treemap, a small deterministic port of the idea behind
/// d3-voronoi-map as used by h8.js: sites move to their cell centroids and weights adapt until
/// each cell's area matches its share. Cells are convex, built by half-plane clipping.
enum PowerTreemap {
    /// SplitMix64 seeded from a string, so the same seed always gives the same map.
    struct Rng {
        var state: UInt64
        init(seed: String) {
            var h: UInt64 = 1469598103934665603 // FNV-1a
            for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            state = h
        }
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }

    /// Power cell of each site inside convex `clip`.
    static func cells(sites: [Pt], weights: [Double], clip: [Pt]) -> [[Pt]] {
        sites.indices.map { i in
            var poly = clip
            for j in sites.indices where j != i {
                // Keep x where |x-si|² - wi <= |x-sj|² - wj  <=>  x·(sj-si) <= (|sj|²-|si|² - wj + wi)/2
                let n = sites[j] - sites[i]
                guard n.length > 1e-9 else { continue }
                let c = (sites[j].dot(sites[j]) - sites[i].dot(sites[i]) - weights[j] + weights[i]) / 2
                // Rewrite as (x - o)·m >= 0 with m = -n and o on the line.
                let o = n * (c / n.dot(n))
                poly = Geo.clipHalf(poly, o: o, n: n * -1)
                if poly.count < 3 { return [] }
            }
            return poly
        }
    }

    /// Splits `clip` into cells with areas proportional to `values`.
    static func split(values: [Double], clip: [Pt], rng: inout Rng, maxIterations: Int = 200, convergence: Double = 0.001) -> [[Pt]] {
        let n = values.count
        guard n > 1 else { return n == 1 ? [clip] : [] }
        let total = values.reduce(0, +), clipArea = Geo.area(clip)
        let targets = values.map { $0 / total * clipArea }
        let (x0, y0, x1, y1) = Geo.bbox(clip)

        var sites: [Pt] = []
        while sites.count < n {
            let p = Pt(x0 + rng.next() * (x1 - x0), y0 + rng.next() * (y1 - y0))
            if Geo.inside(clip, p) { sites.append(p) }
        }
        let base = clipArea / Double(n) / 100
        var weights = [Double](repeating: base, count: n)
        var best: [[Pt]] = []
        var bestError = Double.infinity

        for _ in 0..<maxIterations {
            let cs = cells(sites: sites, weights: weights, clip: clip)
            var error = 0.0
            for i in 0..<n {
                let a = Geo.area(cs[i])
                error += abs(a - targets[i])
                if a > 1e-6 {
                    sites[i] = Geo.centroid(cs[i])
                    weights[i] = max(1e-6, weights[i] * targets[i] / a)
                } else {
                    weights[i] = base // empty cell: reset and nudge
                    sites[i] = sites[i] + Pt(rng.next() - 0.5, rng.next() - 0.5)
                }
            }
            error /= clipArea
            if error < bestError && cs.allSatisfy({ $0.count >= 3 }) { bestError = error; best = cs }
            if error < convergence { break }
            // A site whose weight exceeds a neighbour's by more than their squared distance swallows it; cap.
            for i in 0..<n { for j in 0..<n where i != j {
                let d2 = (sites[i] - sites[j]).dot(sites[i] - sites[j])
                if weights[i] - weights[j] > 0.9 * d2 { weights[i] = weights[j] + 0.9 * d2 }
            } }
        }
        return best.isEmpty ? cells(sites: sites, weights: weights, clip: clip) : best
    }
}
