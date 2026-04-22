import Foundation

/// Lightweight TOML parser supporting only the subset needed for plugin manifests.
/// Zero external dependencies.
enum TOMLParser {
    enum Error: Swift.Error {
        case syntaxError(line: Int, message: String)
    }

    nonisolated struct Document {
        var tables: [String: [String: TOMLValue]] = [:]
        var tableArrays: [String: [[String: TOMLValue]]] = [:]

        subscript(table: String, key: String) -> TOMLValue? {
            tables[table]?[key]
        }

        func string(_ table: String, _ key: String) -> String? {
            tables[table]?[key]?.stringValue
        }

        func bool(_ table: String, _ key: String) -> Bool? {
            tables[table]?[key]?.boolValue
        }

        func int(_ table: String, _ key: String) -> Int? {
            tables[table]?[key]?.intValue
        }

        func stringArray(_ table: String, _ key: String) -> [String]? {
            tables[table]?[key]?.stringArrayValue
        }

        func tableArray(_ table: String) -> [[String: TOMLValue]]? {
            tableArrays[table]
        }
    }

    nonisolated enum TOMLValue {
        case string(String)
        case bool(Bool)
        case int(Int)
        case array([TOMLValue])
        case tableArray([[String: TOMLValue]])

        var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        var boolValue: Bool? {
            if case .bool(let b) = self { return b }
            return nil
        }

        var intValue: Int? {
            if case .int(let i) = self { return i }
            return nil
        }

        var stringArrayValue: [String]? {
            if case .array(let arr) = self {
                return arr.compactMap { $0.stringValue }
            }
            return nil
        }

        var tableArrayValue: [[String: TOMLValue]]? {
            if case .tableArray(let arr) = self { return arr }
            return nil
        }
    }

    nonisolated static func parse(_ text: String) throws -> Document {
        var document = Document()
        var currentTable = ""
        var currentArrayTable: String? = nil
        var currentArrayItems: [[String: TOMLValue]] = []
        var currentArrayItem: [String: TOMLValue] = [:]

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        for (lineIndex, line) in lines.enumerated() {
            let lineNo = lineIndex + 1
            let trimmed = trimComment(from: line)
            guard !trimmed.isEmpty else { continue }

            // Table header: [section]
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                // Flush any pending array table
                if let arrayTable = currentArrayTable {
                    currentArrayItems.append(currentArrayItem)
                    if document.tableArrays[arrayTable] != nil {
                        document.tableArrays[arrayTable]!.append(contentsOf: currentArrayItems)
                    } else {
                        document.tableArrays[arrayTable] = currentArrayItems
                    }
                    currentArrayTable = nil
                    currentArrayItems = []
                    currentArrayItem = [:]
                }

                let inner = String(trimmed.dropFirst().dropLast())
                if inner.hasPrefix("[") && inner.hasSuffix("]") {
                    // Array of tables: [[section]]
                    let tableName = String(inner.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    currentArrayTable = tableName
                    currentArrayItems = []
                    currentArrayItem = [:]
                } else {
                    currentTable = inner.trimmingCharacters(in: .whitespaces)
                    if document.tables[currentTable] == nil {
                        document.tables[currentTable] = [:]
                    }
                }
                continue
            }

            // Key-value pair
            guard let eqIndex = trimmed.firstIndex(of: "=") else {
                throw Error.syntaxError(line: lineNo, message: "Expected key = value")
            }

            let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let valueStr = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty else {
                throw Error.syntaxError(line: lineNo, message: "Empty key")
            }

            let value = try parseValue(valueStr, line: lineNo)

            if currentArrayTable != nil {
                currentArrayItem[key] = value
            } else {
                // Store in current table (empty string = root/implicit table)
                if document.tables[currentTable] == nil {
                    document.tables[currentTable] = [:]
                }
                document.tables[currentTable]?[key] = value
            }
        }

        // Flush final array table
        if let arrayTable = currentArrayTable {
            currentArrayItems.append(currentArrayItem)
            if document.tableArrays[arrayTable] != nil {
                document.tableArrays[arrayTable]!.append(contentsOf: currentArrayItems)
            } else {
                document.tableArrays[arrayTable] = currentArrayItems
            }
        }

        return document
    }

    // MARK: - Private

    private nonisolated static func trimComment(from line: Substring) -> String {
        var result = ""
        var inString = false
        var prevChar: Character?

        for char in line {
            if char == "\"" && prevChar != "\\" {
                inString.toggle()
            }
            if !inString && char == "#" {
                break
            }
            result.append(char)
            prevChar = char
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func parseValue(_ text: String, line: Int) throws -> TOMLValue {
        // String
        if text.hasPrefix("\"") && text.hasSuffix("\"") {
            let inner = String(text.dropFirst().dropLast())
            return .string(inner)
        }

        // Array
        if text.hasPrefix("[") && text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            let elements = splitArrayElements(inner)
            let values = try elements.map { try parseValue($0, line: line) }
            return .array(values)
        }

        // Bool
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }

        // Integer
        if let intValue = Int(text) {
            return .int(intValue)
        }

        throw Error.syntaxError(line: line, message: "Unsupported value: \(text)")
    }

    private nonisolated static func splitArrayElements(_ text: String) -> [String] {
        var elements: [String] = []
        var current = ""
        var inString = false
        var depth = 0

        for char in text {
            if char == "\"" {
                inString.toggle()
            }

            if char == "[" && !inString {
                depth += 1
            } else if char == "]" && !inString {
                depth -= 1
            }

            if char == "," && !inString && depth == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    elements.append(trimmed)
                }
                current = ""
            } else {
                current.append(char)
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            elements.append(trimmed)
        }

        return elements
    }
}
