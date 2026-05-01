import AppKit
import Foundation

/// Inline calculator surfaced as the top result whenever the query parses as a
/// math expression. Mirrors WenZi's `CalculatorSource`:
///
/// - Default-source style: registered without a prefix, only emits a result
///   when the query "looks like math" so it never pollutes generic search.
/// - Enter pastes the raw numeric value to the previous app, ⌘-Enter copies it.
/// - Title shows `expr = formatted` (with thousands separators); the raw value
///   used for paste/copy is unformatted so it can be reused in code.
actor CalculatorProvider: SearchProvider {
    nonisolated static let itemIdPrefix = "calculator:"
    nonisolated static let baseScore: Double = 1_000

    nonisolated static let icon = NSImage(
        systemSymbolName: "function",
        accessibilityDescription: "Calculator"
    )

    func search(query: String) async -> [SearchResult] {
        guard let item = Self.makeResult(for: query) else { return [] }
        return [item]
    }

    /// Pure helper kept nonisolated so tests and `search` share the same logic.
    nonisolated static func makeResult(for query: String) -> SearchResult? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Strip a trailing `=` (and surrounding whitespace) so "1+2=" works.
        var expr = trimmed
        while let last = expr.last, last == "=" || last == " " {
            expr.removeLast()
        }
        guard !expr.isEmpty else { return nil }

        guard CalculatorEngine.looksLikeMath(expr),
              CalculatorEngine.isComplete(expr) else {
            return nil
        }

        let value: Double
        do {
            value = try CalculatorEngine.evaluate(expr)
        } catch {
            return nil
        }

        let (display, raw) = CalculatorEngine.formatNumber(value)
        let title = "\(expr) = \(display)"

        return SearchResult(
            itemId: "\(itemIdPrefix)\(expr)",
            icon: icon,
            name: title,
            subtitle: "Calculator",
            resultType: .calculator,
            url: nil,
            score: baseScore,
            modifierActions: [
                .command: ModifierAction(subtitle: "Copy to Clipboard") { _ in
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(raw, forType: .string)
                    return true
                },
            ],
            actionContext: raw,
            usageBoostEnabled: false
        )
    }
}

// MARK: - Engine

/// Safe expression evaluator. No use of `NSExpression` or any reflective API —
/// only a hand-written recursive descent parser that accepts numeric literals,
/// arithmetic operators, parenthesised sub-expressions, whitelisted constants
/// (`pi`, `e`), and whitelisted function calls.
enum CalculatorEngine {
    enum EvalError: Error, Equatable {
        case syntax
        case unknownIdentifier(String)
        case wrongArity(String)
        case divisionByZero
        case nonFinite
    }

    static let safeFunctions: Set<String> = [
        "sqrt", "sin", "cos", "tan", "asin", "acos", "atan",
        "log", "log2", "log10", "abs", "round", "ceil", "floor",
        "min", "max", "pow",
    ]

    static let safeNames: [String: Double] = [
        "pi": .pi,
        "e": M_E,
    ]

    /// Quick gate matching WenZi's heuristic: must contain at least one digit
    /// and either a function call or a binary operator. A bare negative number
    /// like `-5` should not count as math.
    static func looksLikeMath(_ expr: String) -> Bool {
        guard expr.contains(where: { $0.isNumber }) else { return false }

        for fn in safeFunctions {
            if expr.range(of: "\\b\(fn)\\s*\\(", options: .regularExpression) != nil {
                return true
            }
        }

        // Strip any number of leading unary `-` and whitespace before checking
        // for a binary operator, so `-5` alone returns false but `-5+3` is math.
        var stripped = Substring(expr)
        while let first = stripped.first, first == "-" || first == " " {
            stripped = stripped.dropFirst()
        }
        return stripped.contains(where: { "+-*/%^".contains($0) })
    }

    /// True when *expr* does not end with an operator or open paren.
    static func isComplete(_ expr: String) -> Bool {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return false }
        return !"+-*/%^(".contains(last)
    }

    static func evaluate(_ expr: String) throws -> Double {
        // Accept Python-style `**` by folding it into our `^` operator.
        let normalized = expr.replacingOccurrences(of: "**", with: "^")
        var parser = Parser(input: normalized)
        let value = try parser.parseExpression()
        try parser.expectEnd()
        guard value.isFinite else { throw EvalError.nonFinite }
        return value
    }

    /// Returns `(display, raw)`. `display` carries thousands separators for
    /// readability in the title; `raw` is plain so it pastes cleanly into code.
    static func formatNumber(_ value: Double) -> (display: String, raw: String) {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
            let intValue = Int64(value)
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = true
            formatter.groupingSeparator = ","
            let display = formatter.string(from: NSNumber(value: intValue)) ?? "\(intValue)"
            return (display, "\(intValue)")
        }
        let s = String(format: "%.10g", value)
        return (s, s)
    }
}

// MARK: - Parser

private struct Parser {
    private let chars: [Character]
    private var pos: Int = 0

    init(input: String) {
        self.chars = Array(input)
    }

    private var peek: Character? {
        pos < chars.count ? chars[pos] : nil
    }

    private mutating func skipWhitespace() {
        while let c = peek, c.isWhitespace { pos += 1 }
    }

    mutating func expectEnd() throws {
        skipWhitespace()
        if pos < chars.count {
            throw CalculatorEngine.EvalError.syntax
        }
    }

    mutating func parseExpression() throws -> Double {
        try parseAdditive()
    }

    private mutating func parseAdditive() throws -> Double {
        var left = try parseMultiplicative()
        while true {
            skipWhitespace()
            guard let op = peek, op == "+" || op == "-" else { break }
            pos += 1
            let right = try parseMultiplicative()
            left = (op == "+") ? left + right : left - right
        }
        return left
    }

    private mutating func parseMultiplicative() throws -> Double {
        var left = try parsePower()
        while true {
            skipWhitespace()
            guard let op = peek, op == "*" || op == "/" || op == "%" else { break }
            pos += 1
            let right = try parsePower()
            switch op {
            case "*":
                left = left * right
            case "/":
                if right == 0 { throw CalculatorEngine.EvalError.divisionByZero }
                left = left / right
            case "%":
                if right == 0 { throw CalculatorEngine.EvalError.divisionByZero }
                left = left.truncatingRemainder(dividingBy: right)
            default:
                break
            }
        }
        return left
    }

    private mutating func parsePower() throws -> Double {
        let base = try parseUnary()
        skipWhitespace()
        if peek == "^" {
            pos += 1
            // Right-associative: 2^3^2 == 2^(3^2)
            let exponent = try parsePower()
            return Foundation.pow(base, exponent)
        }
        return base
    }

    private mutating func parseUnary() throws -> Double {
        skipWhitespace()
        if peek == "+" {
            pos += 1
            return try parseUnary()
        }
        if peek == "-" {
            pos += 1
            return -(try parseUnary())
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> Double {
        skipWhitespace()
        guard let c = peek else { throw CalculatorEngine.EvalError.syntax }

        if c == "(" {
            pos += 1
            let value = try parseExpression()
            skipWhitespace()
            guard peek == ")" else { throw CalculatorEngine.EvalError.syntax }
            pos += 1
            return value
        }

        if c.isNumber || c == "." {
            return try parseNumber()
        }

        if c.isLetter || c == "_" {
            return try parseNameOrCall()
        }

        throw CalculatorEngine.EvalError.syntax
    }

    private mutating func parseNumber() throws -> Double {
        let start = pos
        while let c = peek, c.isNumber || c == "." {
            pos += 1
        }
        if let c = peek, c == "e" || c == "E" {
            // Only consume exponent if it's well-formed, otherwise leave it for
            // the name parser (e.g. `2e` should not eat the `e` constant).
            let saved = pos
            pos += 1
            if let s = peek, s == "+" || s == "-" {
                pos += 1
            }
            var sawDigit = false
            while let d = peek, d.isNumber {
                pos += 1
                sawDigit = true
            }
            if !sawDigit {
                pos = saved
            }
        }
        let s = String(chars[start..<pos])
        guard let v = Double(s) else { throw CalculatorEngine.EvalError.syntax }
        return v
    }

    private mutating func parseNameOrCall() throws -> Double {
        let start = pos
        while let c = peek, c.isLetter || c.isNumber || c == "_" {
            pos += 1
        }
        let name = String(chars[start..<pos]).lowercased()
        skipWhitespace()
        if peek == "(" {
            pos += 1
            var args: [Double] = []
            skipWhitespace()
            if peek != ")" {
                args.append(try parseExpression())
                skipWhitespace()
                while peek == "," {
                    pos += 1
                    args.append(try parseExpression())
                    skipWhitespace()
                }
            }
            guard peek == ")" else { throw CalculatorEngine.EvalError.syntax }
            pos += 1
            return try Self.callFunction(name: name, args: args)
        }
        if let v = CalculatorEngine.safeNames[name] {
            return v
        }
        throw CalculatorEngine.EvalError.unknownIdentifier(name)
    }

    private static func callFunction(name: String, args: [Double]) throws -> Double {
        guard CalculatorEngine.safeFunctions.contains(name) else {
            throw CalculatorEngine.EvalError.unknownIdentifier(name)
        }
        switch name {
        case "sqrt":
            try requireArity(name, args, 1)
            return sqrt(args[0])
        case "sin":
            try requireArity(name, args, 1)
            return sin(args[0])
        case "cos":
            try requireArity(name, args, 1)
            return cos(args[0])
        case "tan":
            try requireArity(name, args, 1)
            return tan(args[0])
        case "asin":
            try requireArity(name, args, 1)
            return asin(args[0])
        case "acos":
            try requireArity(name, args, 1)
            return acos(args[0])
        case "atan":
            try requireArity(name, args, 1)
            return atan(args[0])
        case "log":
            try requireArity(name, args, 1)
            return Foundation.log(args[0])
        case "log2":
            try requireArity(name, args, 1)
            return Foundation.log2(args[0])
        case "log10":
            try requireArity(name, args, 1)
            return Foundation.log10(args[0])
        case "abs":
            try requireArity(name, args, 1)
            return Swift.abs(args[0])
        case "round":
            try requireArity(name, args, 1)
            return args[0].rounded()
        case "ceil":
            try requireArity(name, args, 1)
            return Foundation.ceil(args[0])
        case "floor":
            try requireArity(name, args, 1)
            return Foundation.floor(args[0])
        case "min":
            guard !args.isEmpty else { throw CalculatorEngine.EvalError.wrongArity(name) }
            return args.min()!
        case "max":
            guard !args.isEmpty else { throw CalculatorEngine.EvalError.wrongArity(name) }
            return args.max()!
        case "pow":
            try requireArity(name, args, 2)
            return Foundation.pow(args[0], args[1])
        default:
            throw CalculatorEngine.EvalError.unknownIdentifier(name)
        }
    }

    private static func requireArity(_ name: String, _ args: [Double], _ expected: Int) throws {
        if args.count != expected {
            throw CalculatorEngine.EvalError.wrongArity(name)
        }
    }
}
