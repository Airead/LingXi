import Foundation

nonisolated struct FuzzyMatchResult {
    let score: Double
    let matchedIndices: [Int]
}

nonisolated enum FuzzyMatch {
    static let prefixScore: Double = 100
    static let initialsScore: Double = 75
    static let containsScore: Double = 50
    static let scatteredScore: Double = 25

    /// Match query against a single text field. Returns nil if no match.
    static func match(query: String, text: String) -> FuzzyMatchResult? {
        guard !query.isEmpty, !text.isEmpty else { return nil }

        let qChars = Array(query.lowercased())
        let tLower = Array(text.lowercased())
        let tOriginal = Array(text)

        guard qChars.count <= tLower.count else { return nil }

        // Level 1: Prefix match
        if tLower.starts(with: qChars) {
            return FuzzyMatchResult(score: prefixScore, matchedIndices: Array(0..<qChars.count))
        }

        // Level 2: Initials/abbreviation match (needs original casing for camelCase detection)
        if let indices = initialsMatch(query: qChars, originalChars: tOriginal) {
            return FuzzyMatchResult(score: initialsScore, matchedIndices: indices)
        }

        // Level 3: Substring contains match
        if let indices = substringMatch(query: qChars, textChars: tLower) {
            return FuzzyMatchResult(score: containsScore, matchedIndices: indices)
        }

        // Level 4: Scattered characters match
        if let indices = charsInOrder(query: qChars, textChars: tLower) {
            return FuzzyMatchResult(score: scatteredScore, matchedIndices: indices)
        }

        return nil
    }

    /// Multi-field AND match: split query by spaces into terms,
    /// each term must match at least one field. Returns average of best scores.
    static func matchFields(query: String, fields: [String]) -> Double? {
        guard !query.isEmpty else { return nil }

        let terms = query.split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return nil }

        var totalScore: Double = 0

        for term in terms {
            var bestScore: Double = 0
            for field in fields {
                if let result = match(query: term, text: field) {
                    bestScore = max(bestScore, result.score)
                }
            }
            guard bestScore > 0 else { return nil }
            totalScore += bestScore
        }

        return totalScore / Double(terms.count)
    }

    // MARK: - Word initials extraction

    /// Extract characters at word boundaries (space, hyphen, underscore, dot, camelCase).
    /// Returns (lowercased character, index) pairs.
    static func wordInitials(_ chars: [Character]) -> [(character: Character, index: Int)] {
        var result: [(character: Character, index: Int)] = []

        for i in chars.indices {
            let isWordStart: Bool
            if i == 0 {
                isWordStart = chars[i].isLetter || chars[i].isNumber
            } else if chars[i - 1].isWordBoundary {
                isWordStart = chars[i].isLetter || chars[i].isNumber
            } else if chars[i].isUppercase && chars[i - 1].isLowercase {
                // camelCase boundary
                isWordStart = true
            } else {
                isWordStart = false
            }

            if isWordStart {
                result.append((Character(String(chars[i]).lowercased()), i))
            }
        }

        return result
    }

    // MARK: - Internal matching functions

    /// Check if query characters match the initials of text (as a prefix of initials).
    static func initialsMatch(query: [Character], originalChars: [Character]) -> [Int]? {
        let initials = wordInitials(originalChars)
        guard query.count <= initials.count else { return nil }

        var indices: [Int] = []
        for i in 0..<query.count {
            guard query[i] == initials[i].character else { return nil }
            indices.append(initials[i].index)
        }

        return indices
    }

    /// Find query as a contiguous substring in text.
    static func substringMatch(query: [Character], textChars: [Character]) -> [Int]? {
        guard query.count <= textChars.count else { return nil }

        for start in 0...(textChars.count - query.count) {
            if textChars[start..<(start + query.count)].elementsEqual(query) {
                return Array(start..<(start + query.count))
            }
        }

        return nil
    }

    /// Find query characters scattered in order within text.
    static func charsInOrder(query: [Character], textChars: [Character]) -> [Int]? {
        var indices: [Int] = []
        var searchFrom = 0

        for qChar in query {
            guard let i = textChars[searchFrom...].firstIndex(of: qChar) else { return nil }
            indices.append(i)
            searchFrom = i + 1
        }

        return indices
    }
}

// MARK: - Character extension

nonisolated private extension Character {
    var isWordBoundary: Bool {
        self == " " || self == "-" || self == "_" || self == "."
    }
}
