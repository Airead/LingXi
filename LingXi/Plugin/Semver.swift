import Foundation

/// Semantic version comparison supporting `major.minor.patch`.
nonisolated enum Semver {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = parse(lhs)
        let right = parse(rhs)

        for i in 0..<max(left.count, right.count) {
            let l = i < left.count ? left[i] : 0
            let r = i < right.count ? right[i] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func parse(_ version: String) -> [Int] {
        version
            .split(separator: ".")
            .compactMap { Int($0) }
    }
}
