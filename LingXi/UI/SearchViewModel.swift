import Combine
import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""

    func clear() {
        query = ""
    }
}
