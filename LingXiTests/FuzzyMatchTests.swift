import Foundation
import Testing
@testable import LingXi

@Suite
struct FuzzyMatchTests {

    // MARK: - Prefix match (100)

    @Test func prefixMatch() {
        let result = FuzzyMatch.match(query: "saf", text: "Safari")
        #expect(result?.score == FuzzyMatch.prefixScore)
        #expect(result?.matchedIndices == [0, 1, 2])
    }

    @Test func prefixMatchCaseInsensitive() {
        let result = FuzzyMatch.match(query: "SAF", text: "Safari")
        #expect(result?.score == FuzzyMatch.prefixScore)
    }

    @Test func exactMatch() {
        let result = FuzzyMatch.match(query: "safari", text: "Safari")
        #expect(result?.score == FuzzyMatch.prefixScore)
    }

    // MARK: - Initials match (75)

    @Test func initialsMatchSpaceSeparated() {
        let result = FuzzyMatch.match(query: "vsc", text: "Visual Studio Code")
        #expect(result?.score == FuzzyMatch.initialsScore)
        #expect(result?.matchedIndices == [0, 7, 14])
    }

    @Test func initialsMatchTwoWords() {
        let result = FuzzyMatch.match(query: "gc", text: "Google Chrome")
        #expect(result?.score == FuzzyMatch.initialsScore)
        #expect(result?.matchedIndices == [0, 7])
    }

    @Test func initialsMatchCamelCase() {
        let result = FuzzyMatch.match(query: "gubi", text: "getUserById")
        #expect(result?.score == FuzzyMatch.initialsScore)
        #expect(result?.matchedIndices == [0, 3, 7, 9])
    }

    @Test func initialsMatchHyphenSeparated() {
        let result = FuzzyMatch.match(query: "bms", text: "Bristol-Myers Squibb")
        #expect(result?.score == FuzzyMatch.initialsScore)
        #expect(result?.matchedIndices == [0, 8, 14])
    }

    @Test func initialsMatchUnderscoreSeparated() {
        let result = FuzzyMatch.match(query: "mu", text: "my_utility")
        #expect(result?.score == FuzzyMatch.initialsScore)
        #expect(result?.matchedIndices == [0, 3])
    }

    @Test func initialsPartialPrefix() {
        // "vs" matches first two initials of "Visual Studio Code"
        let result = FuzzyMatch.match(query: "vs", text: "Visual Studio Code")
        #expect(result?.score == FuzzyMatch.initialsScore)
    }

    // MARK: - Substring contains match (50)

    @Test func substringMatch() {
        let result = FuzzyMatch.match(query: "afar", text: "Safari")
        #expect(result?.score == FuzzyMatch.containsScore)
        #expect(result?.matchedIndices == [1, 2, 3, 4])
    }

    @Test func substringMatchMiddle() {
        let result = FuzzyMatch.match(query: "erm", text: "Terminal")
        #expect(result?.score == FuzzyMatch.containsScore)
    }

    // MARK: - Scattered characters match (25)

    @Test func scatteredMatch() {
        let result = FuzzyMatch.match(query: "sfri", text: "Safari")
        #expect(result?.score == FuzzyMatch.scatteredScore)
    }

    @Test func scatteredMatchIndices() {
        let result = FuzzyMatch.match(query: "sfri", text: "Safari")
        // S(0) a f(2) a r(4) i(5) -> s=0, f=2, r=4, i=5
        #expect(result?.matchedIndices == [0, 2, 4, 5])
    }

    // MARK: - Priority: highest score wins

    @Test func prefixWinsOverOtherMatches() {
        // "chrome" is a prefix of "Chrome" -> should be prefix score
        let result = FuzzyMatch.match(query: "chrome", text: "Chrome")
        #expect(result?.score == FuzzyMatch.prefixScore)
    }

    // MARK: - Edge cases

    @Test func emptyQueryReturnsNil() {
        let result = FuzzyMatch.match(query: "", text: "Safari")
        #expect(result == nil)
    }

    @Test func emptyTextReturnsNil() {
        let result = FuzzyMatch.match(query: "saf", text: "")
        #expect(result == nil)
    }

    @Test func queryLongerThanTextReturnsNil() {
        let result = FuzzyMatch.match(query: "very long query", text: "short")
        #expect(result == nil)
    }

    @Test func noMatchReturnsNil() {
        let result = FuzzyMatch.match(query: "xyz", text: "Safari")
        #expect(result == nil)
    }

    @Test func chineseCharactersDoNotCrash() {
        let result = FuzzyMatch.match(query: "微", text: "微信")
        #expect(result?.score == FuzzyMatch.prefixScore)
    }

    @Test func numbersMatch() {
        let result = FuzzyMatch.match(query: "7z", text: "7-Zip")
        // "7" and "Z" are word initials (start + after hyphen)
        #expect(result?.score == FuzzyMatch.initialsScore)
    }

    @Test func specialCharactersDoNotCrash() {
        let result = FuzzyMatch.match(query: "@#$", text: "normal text")
        // Should not crash, just no match
        #expect(result == nil)
    }

    // MARK: - Word initials extraction

    @Test func wordInitialsSpaceSeparated() {
        let initials = FuzzyMatch.wordInitials(Array("Visual Studio Code"))
        let chars = initials.map(\.character)
        #expect(chars == ["v", "s", "c"])
    }

    @Test func wordInitialsCamelCase() {
        let initials = FuzzyMatch.wordInitials(Array("getUserById"))
        let chars = initials.map(\.character)
        #expect(chars == ["g", "u", "b", "i"])
    }

    @Test func wordInitialsHyphen() {
        let initials = FuzzyMatch.wordInitials(Array("Bristol-Myers Squibb"))
        let chars = initials.map(\.character)
        #expect(chars == ["b", "m", "s"])
    }

    @Test func wordInitialsUnderscore() {
        let initials = FuzzyMatch.wordInitials(Array("my_utility_func"))
        let chars = initials.map(\.character)
        #expect(chars == ["m", "u", "f"])
    }

    @Test func wordInitialsDotSeparated() {
        let initials = FuzzyMatch.wordInitials(Array("com.apple.Safari"))
        let chars = initials.map(\.character)
        #expect(chars == ["c", "a", "s"])
    }

    // MARK: - Multi-field AND match

    @Test func matchFieldsSingleTerm() {
        let score = FuzzyMatch.matchFields(query: "safari", fields: ["Safari", "com.apple.Safari"])
        #expect(score == FuzzyMatch.prefixScore)
    }

    @Test func matchFieldsMultiTermSameField() {
        // "google chrome" -> "google" prefix-matches (100), "chrome" contains-matches (50)
        let score = FuzzyMatch.matchFields(query: "google chrome", fields: ["Google Chrome"])
        #expect(score != nil)
        // Average of 100 and 50 = 75
        #expect(score == 75.0)
    }

    @Test func matchFieldsMultiTermCrossField() {
        // "goo com" -> "goo" matches "Google Chrome", "com" matches "com.google.chrome"
        let score = FuzzyMatch.matchFields(
            query: "goo com",
            fields: ["Google Chrome", "com.google.chrome"]
        )
        #expect(score != nil)
    }

    @Test func matchFieldsReversedOrder() {
        // "chrome google" -> both terms match "Google Chrome" (as substrings)
        let score = FuzzyMatch.matchFields(query: "chrome google", fields: ["Google Chrome"])
        #expect(score != nil)
    }

    @Test func matchFieldsOneTermFails() {
        // "safari xyz" -> "safari" matches but "xyz" matches nothing
        let score = FuzzyMatch.matchFields(query: "safari xyz", fields: ["Safari"])
        #expect(score == nil)
    }

    @Test func matchFieldsEmptyQuery() {
        let score = FuzzyMatch.matchFields(query: "", fields: ["Safari"])
        #expect(score == nil)
    }

    @Test func matchFieldsAverageScore() {
        // "saf com" -> "saf" prefix-matches "Safari" (100), "com" prefix-matches "com.apple.Safari" (100)
        let score = FuzzyMatch.matchFields(
            query: "saf com",
            fields: ["Safari", "com.apple.Safari"]
        )
        #expect(score == FuzzyMatch.prefixScore)
    }

    @Test func matchFieldsMixedScores() {
        // "safari apple" -> "safari" prefix-matches "Safari" (100), "apple" prefix-matches in "com.apple.Safari" via contains (50)
        let score = FuzzyMatch.matchFields(
            query: "safari apple",
            fields: ["Safari", "com.apple.Safari"]
        )
        // Average of 100 and 50 = 75
        #expect(score != nil)
        #expect(score == 75.0)
    }
}
