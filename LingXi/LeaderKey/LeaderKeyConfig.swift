import CoreGraphics
import Foundation

/// A single key-to-action mapping within a leader key group.
struct LeaderMapping: Codable, Sendable {
    /// Sub-key name (e.g. "w", "s", "1").
    let key: String
    /// Human-readable description shown in the HUD panel.
    let desc: String?
    /// App name or bundle path to launch (e.g. "WeChat", "/Applications/Slack.app").
    let app: String?
    /// Shell command to execute.
    let exec: String?

    /// Display label for the HUD row: desc > app > exec > "action".
    var displayText: String {
        desc ?? app ?? exec ?? "action"
    }
}

/// A complete leader-key configuration bound to a single trigger key.
struct LeaderConfig: Codable, Sendable {
    /// Trigger key name (e.g. "cmd_r", "alt_r", "fn").
    let triggerKey: String
    /// Where to display the panel.
    let position: PanelPosition
    /// Sub-key mappings.
    let mappings: [LeaderMapping]
    /// Pre-built lookup table for O(1) sub-key matching (lowercased keys).
    let mappingsByKey: [String: LeaderMapping]

    init(triggerKey: String, position: PanelPosition = .center, mappings: [LeaderMapping]) {
        self.triggerKey = triggerKey
        self.position = position
        self.mappings = mappings
        var table = [String: LeaderMapping]()
        for m in mappings { table[m.key.lowercased()] = m }
        self.mappingsByKey = table
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            triggerKey: try container.decode(String.self, forKey: .triggerKey),
            position: try container.decodeIfPresent(PanelPosition.self, forKey: .position) ?? .center,
            mappings: try container.decode([LeaderMapping].self, forKey: .mappings)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case triggerKey, position, mappings
    }
}

/// Panel positioning options.
enum PanelPosition: String, Codable, Sendable {
    case center
    case top
    case bottom
    case mouse
}

/// Root configuration loaded from the JSON file.
struct LeaderKeyFile: Codable, Sendable {
    let leaders: [LeaderConfig]
}

// MARK: - Virtual keycode mapping

/// Maps trigger key names to their virtual keycodes and CGEventFlags masks.
enum LeaderKeycode {
    /// Modifier keys with (virtualKeyCode, CGEventFlags rawValue bit).
    /// Left/right variants are distinguished by keycode.
    static let modifierKeys: [String: (keycode: UInt16, flagBit: UInt64)] = [
        "cmd":     (55, CGEventFlags.maskCommand.rawValue),
        "cmd_r":   (54, CGEventFlags.maskCommand.rawValue),
        "ctrl":    (59, CGEventFlags.maskControl.rawValue),
        "ctrl_r":  (62, CGEventFlags.maskControl.rawValue),
        "alt":     (58, CGEventFlags.maskAlternate.rawValue),
        "alt_r":   (61, CGEventFlags.maskAlternate.rawValue),
        "shift":   (56, CGEventFlags.maskShift.rawValue),
        "shift_r": (60, CGEventFlags.maskShift.rawValue),
        "fn":      (63, CGEventFlags.maskSecondaryFn.rawValue),
    ]

    /// Regular key names to virtual keycodes.
    static let regularKeys: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    /// Reverse map: virtual keycode → key name (for regular keys).
    static let keycodeToName: [UInt16: String] = {
        var map = [UInt16: String]()
        for (name, code) in regularKeys { map[code] = name }
        return map
    }()

    /// Reverse map: virtual keycode → trigger key name (for modifier keys).
    static let keycodeToModifierName: [UInt16: String] = {
        var map = [UInt16: String]()
        for (name, info) in modifierKeys { map[info.keycode] = name }
        return map
    }()

    /// All known trigger key names (modifier keys that can be used as leader triggers).
    static let allTriggerNames: Set<String> = Set(modifierKeys.keys)
}

// MARK: - Config loading

enum LeaderKeyConfigLoader {
    /// Default config file path: ~/.config/LingXi/leader.jsonc
    static func defaultConfigPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/LingXi/leader.jsonc")
    }

    /// Load leader configurations from a JSONC file (JSON with comments).
    /// Returns an empty array if the file does not exist or fails to parse.
    static func load(from url: URL = defaultConfigPath()) -> [LeaderConfig] {
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let stripped = stripJSONComments(raw)
            let data = Data(stripped.utf8)
            let file = try JSONDecoder().decode(LeaderKeyFile.self, from: data)
            return file.leaders.filter { config in
                LeaderKeycode.allTriggerNames.contains(config.triggerKey)
            }
        } catch {
            print("LeaderKeyConfig: failed to load \(url.path): \(error)")
            return []
        }
    }

    /// Strip single-line (`//`) and block (`/* */`) comments from JSONC text,
    /// respecting double-quoted strings so that `"http://..."` is not mangled.
    static func stripJSONComments(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var i = input.startIndex
        let end = input.endIndex

        while i < end {
            let c = input[i]

            // Quoted string — copy verbatim including escapes
            if c == "\"" {
                result.append(c)
                i = input.index(after: i)
                while i < end {
                    let sc = input[i]
                    result.append(sc)
                    if sc == "\\" {
                        // Copy the escaped character too
                        i = input.index(after: i)
                        if i < end {
                            result.append(input[i])
                            i = input.index(after: i)
                        }
                    } else if sc == "\"" {
                        i = input.index(after: i)
                        break
                    } else {
                        i = input.index(after: i)
                    }
                }
                continue
            }

            // Potential comment start
            if c == "/" {
                let next = input.index(after: i)
                if next < end {
                    if input[next] == "/" {
                        // Single-line comment — skip until newline
                        i = input.index(after: next)
                        while i < end, input[i] != "\n" {
                            i = input.index(after: i)
                        }
                        continue
                    } else if input[next] == "*" {
                        // Block comment — skip until */
                        i = input.index(after: next)
                        i = input.index(after: i)
                        while i < end {
                            if input[i] == "*" {
                                let afterStar = input.index(after: i)
                                if afterStar < end, input[afterStar] == "/" {
                                    i = input.index(after: afterStar)
                                    break
                                }
                            }
                            i = input.index(after: i)
                        }
                        continue
                    }
                }
            }

            result.append(c)
            i = input.index(after: i)
        }

        return result
    }
}
