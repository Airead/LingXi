import Foundation
import Testing
@testable import LingXi

@MainActor
@Suite(.serialized)
struct CalculatorProviderTests {
    private static let provider = CalculatorProvider()

    // MARK: - Engine: arithmetic

    @Test func engineSimpleAddition() throws {
        #expect(try CalculatorEngine.evaluate("1+2") == 3)
    }

    @Test func engineRespectsOperatorPrecedence() throws {
        #expect(try CalculatorEngine.evaluate("2+3*4") == 14)
    }

    @Test func engineHandlesParentheses() throws {
        #expect(try CalculatorEngine.evaluate("(2+3)*4") == 20)
    }

    @Test func engineUnaryMinus() throws {
        #expect(try CalculatorEngine.evaluate("-5+3") == -2)
        #expect(try CalculatorEngine.evaluate("--5") == 5)
    }

    @Test func engineDivision() throws {
        #expect(try CalculatorEngine.evaluate("10/4") == 2.5)
    }

    @Test func engineModulo() throws {
        #expect(try CalculatorEngine.evaluate("10%3") == 1)
    }

    @Test func enginePowerWithCaret() throws {
        #expect(try CalculatorEngine.evaluate("2^10") == 1024)
    }

    @Test func enginePowerWithDoubleStar() throws {
        // Python-style `**` is normalized to `^` before parsing.
        #expect(try CalculatorEngine.evaluate("2**10") == 1024)
    }

    @Test func enginePowerIsRightAssociative() throws {
        #expect(try CalculatorEngine.evaluate("2^3^2") == 512)
    }

    @Test func engineScientificNotation() throws {
        #expect(try CalculatorEngine.evaluate("1.5e3") == 1500)
    }

    // MARK: - Engine: functions and constants

    @Test func engineSqrt() throws {
        #expect(try CalculatorEngine.evaluate("sqrt(16)") == 4)
    }

    @Test func engineSinZero() throws {
        #expect(try CalculatorEngine.evaluate("sin(0)") == 0)
    }

    @Test func enginePowFunction() throws {
        #expect(try CalculatorEngine.evaluate("pow(2,8)") == 256)
    }

    @Test func engineMinMaxVariadic() throws {
        #expect(try CalculatorEngine.evaluate("min(3,1,2)") == 1)
        #expect(try CalculatorEngine.evaluate("max(3,1,2)") == 3)
    }

    @Test func engineLog10() throws {
        #expect(try CalculatorEngine.evaluate("log10(1000)") == 3)
    }

    @Test func engineConstantPi() throws {
        let value = try CalculatorEngine.evaluate("pi")
        #expect(abs(value - .pi) < 1e-12)
    }

    @Test func engineConstantE() throws {
        let value = try CalculatorEngine.evaluate("e*2")
        #expect(abs(value - M_E * 2) < 1e-12)
    }

    @Test func engineNestedFunction() throws {
        #expect(try CalculatorEngine.evaluate("sqrt(pow(3,2)+pow(4,2))") == 5)
    }

    // MARK: - Engine: errors

    @Test func engineRejectsUnknownIdentifier() {
        #expect(throws: CalculatorEngine.EvalError.self) {
            _ = try CalculatorEngine.evaluate("foo(1)")
        }
    }

    @Test func engineRejectsDivisionByZero() {
        #expect(throws: CalculatorEngine.EvalError.divisionByZero) {
            _ = try CalculatorEngine.evaluate("1/0")
        }
    }

    @Test func engineRejectsModuloByZero() {
        #expect(throws: CalculatorEngine.EvalError.divisionByZero) {
            _ = try CalculatorEngine.evaluate("1%0")
        }
    }

    @Test func engineRejectsNonFiniteFromOverflow() {
        // 10^400 overflows Double to infinity; the evaluator must reject it.
        #expect(throws: CalculatorEngine.EvalError.nonFinite) {
            _ = try CalculatorEngine.evaluate("10^400")
        }
    }

    @Test func engineRejectsTrailingGarbage() {
        #expect(throws: CalculatorEngine.EvalError.self) {
            _ = try CalculatorEngine.evaluate("1+2 garbage")
        }
    }

    @Test func engineRejectsWrongArity() {
        #expect(throws: CalculatorEngine.EvalError.self) {
            _ = try CalculatorEngine.evaluate("sqrt(1,2)")
        }
    }

    // MARK: - Engine: heuristics

    @Test func looksLikeMathRequiresDigit() {
        #expect(!CalculatorEngine.looksLikeMath("abc"))
        #expect(!CalculatorEngine.looksLikeMath("a+b"))
    }

    @Test func looksLikeMathRejectsBareNumber() {
        // Plain integers/floats are not "math" — they're just numbers.
        #expect(!CalculatorEngine.looksLikeMath("123"))
        #expect(!CalculatorEngine.looksLikeMath("1.5"))
    }

    @Test func looksLikeMathRejectsBareNegativeNumber() {
        // Per WenZi: a leading unary minus alone doesn't count as math.
        #expect(!CalculatorEngine.looksLikeMath("-5"))
    }

    @Test func looksLikeMathAcceptsBinaryOperators() {
        #expect(CalculatorEngine.looksLikeMath("1+2"))
        #expect(CalculatorEngine.looksLikeMath("-5+3"))
        #expect(CalculatorEngine.looksLikeMath("2*pi"))
    }

    @Test func looksLikeMathAcceptsFunctionCalls() {
        #expect(CalculatorEngine.looksLikeMath("sqrt(16)"))
        #expect(CalculatorEngine.looksLikeMath("pow(2, 3)"))
    }

    @Test func isCompleteRejectsTrailingOperators() {
        #expect(!CalculatorEngine.isComplete("1+"))
        #expect(!CalculatorEngine.isComplete("2*("))
        #expect(!CalculatorEngine.isComplete("3^"))
    }

    @Test func isCompleteAcceptsClosedExpressions() {
        #expect(CalculatorEngine.isComplete("1+2"))
        #expect(CalculatorEngine.isComplete("sqrt(4)"))
    }

    // MARK: - Engine: formatting

    @Test func formatNumberAddsThousandsSeparator() {
        let (display, raw) = CalculatorEngine.formatNumber(1_234_567)
        #expect(display == "1,234,567")
        #expect(raw == "1234567")
    }

    @Test func formatNumberCollapsesIntegralFloat() {
        // 1000.0 should display as "1,000", not "1000.0".
        let (display, raw) = CalculatorEngine.formatNumber(1000.0)
        #expect(display == "1,000")
        #expect(raw == "1000")
    }

    @Test func formatNumberKeepsFractionalPart() {
        let (display, raw) = CalculatorEngine.formatNumber(2.5)
        #expect(display == "2.5")
        #expect(raw == "2.5")
    }

    // MARK: - Provider: end-to-end

    @Test func providerReturnsCalculatorResult() async {
        let results = await Self.provider.search(query: "1+2")
        #expect(results.count == 1)
        let r = try? #require(results.first)
        #expect(r?.resultType == .calculator)
        #expect(r?.name == "1+2 = 3")
        #expect(r?.actionContext == "3")
        #expect(r?.subtitle == "Calculator")
    }

    @Test func providerHandlesTrailingEquals() async {
        let results = await Self.provider.search(query: "2*3=")
        #expect(results.count == 1)
        #expect(results.first?.name == "2*3 = 6")
    }

    @Test func providerEmptyQueryYieldsNothing() async {
        let results = await Self.provider.search(query: "")
        #expect(results.isEmpty)
    }

    @Test func providerNonMathQueryYieldsNothing() async {
        // Plain searches must never accidentally trigger the calculator.
        #expect(await Self.provider.search(query: "hello").isEmpty)
        #expect(await Self.provider.search(query: "calculator").isEmpty)
        #expect(await Self.provider.search(query: "123").isEmpty)
    }

    @Test func providerIncompleteExpressionYieldsNothing() async {
        // While the user is mid-typing, no result should flash in.
        #expect(await Self.provider.search(query: "1+").isEmpty)
        #expect(await Self.provider.search(query: "sqrt(").isEmpty)
    }

    @Test func providerRejectsWhitelistViolations() async {
        // Anything that resembles code injection must be quietly dropped, not
        // surfaced as a result.
        #expect(await Self.provider.search(query: "system(\"ls\")").isEmpty)
        #expect(await Self.provider.search(query: "1+foo").isEmpty)
    }

    @Test func providerSurvivesDivisionByZero() async {
        // Should not crash and should not emit a misleading inf/nan result.
        #expect(await Self.provider.search(query: "1/0").isEmpty)
    }

    @Test func providerHighScoreEnsuresTopRanking() async {
        let results = await Self.provider.search(query: "100+1")
        let r = try? #require(results.first)
        // Score should beat the FuzzyMatch ceiling (100 + boost cap 50).
        #expect((r?.score ?? 0) > 200)
    }

    @Test func providerDisablesUsageBoost() async {
        // Each expression is unique; usage boosting would just be noise.
        let results = await Self.provider.search(query: "1+1")
        let r = try? #require(results.first)
        #expect(r?.usageBoostEnabled == false)
    }
}
