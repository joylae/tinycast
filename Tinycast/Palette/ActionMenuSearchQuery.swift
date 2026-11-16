import Foundation

/// A folded menu query reused for every row title in one menu rebuild.
struct ActionMenuSearchQuery {
    private let needle: FuzzyMatch.Query?

    var isEmpty: Bool { needle == nil }

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        needle = trimmed.isEmpty ? nil : FuzzyMatch.Query(trimmed)
    }

    func score(_ candidate: String, englishTitle: String? = nil) -> Int? {
        guard let needle else { return 0 }
        let titles = [candidate] + (englishTitle.map { [$0] } ?? []) + Pinyin.aliases(for: candidate)
        return titles.compactMap {
            FuzzyMatch.score(needle, candidate: $0)
        }.max()
    }
}
