import CoreServices
import Foundation

enum ContentTypeFilter: Sendable {
    case any
    case only(String)
    case exclude(String)

    static let foldersOnly = ContentTypeFilter.only("public.folder")
    static let excludeFolders = ContentTypeFilter.exclude("public.folder")
}

protocol MDQuerySearching: Sendable {
    func search(name: String, scope: [String], maxResults: Int, includeHidden: Bool, contentType: ContentTypeFilter) async -> [MDQuerySearch.FileResult]
}

struct MDQuerySearch: MDQuerySearching {
    struct FileResult {
        let path: String
        let name: String
    }

    private static let searchQueue = DispatchQueue(label: "io.github.airead.lingxi.mdquery-search", attributes: .concurrent)

    static func buildQueryString(name: String, contentType: ContentTypeFilter) -> String {
        let escaped = escapeQuery(name)
        var queryString = "kMDItemFSName == \"*\(escaped)*\"cd"
        switch contentType {
        case .any:
            break
        case .only(let type):
            queryString += " && kMDItemContentType == \"\(type)\""
        case .exclude(let type):
            queryString += " && kMDItemContentType != \"\(type)\""
        }
        return queryString
    }

    func search(name: String, scope: [String], maxResults: Int, includeHidden: Bool, contentType: ContentTypeFilter) async -> [FileResult] {
        await withCheckedContinuation { continuation in
            Self.searchQueue.async {
                let queryString = Self.buildQueryString(name: name, contentType: contentType)

                guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, nil, nil) else {
                    continuation.resume(returning: [])
                    return
                }

                let scopeArray = scope as CFArray
                MDQuerySetSearchScope(query, scopeArray, 0)

                MDQuerySetMaxCount(query, CFIndex(maxResults))

                guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
                    continuation.resume(returning: [])
                    return
                }

                let count = MDQueryGetResultCount(query)
                var results: [FileResult] = []

                for i in 0..<count {
                    guard let rawPtr = MDQueryGetResultAtIndex(query, i) else { continue }
                    let item = Unmanaged<MDItem>.fromOpaque(rawPtr).takeUnretainedValue()

                    guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                          let name = MDItemCopyAttribute(item, kMDItemFSName) as? String else {
                        continue
                    }

                    if !includeHidden && Self.isHiddenPath(path) {
                        continue
                    }

                    results.append(FileResult(path: path, name: name))
                }

                continuation.resume(returning: results)
            }
        }
    }

    static func escapeQuery(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*")
    }

    static func isHiddenPath(_ path: String) -> Bool {
        path.contains("/.")
    }
}
