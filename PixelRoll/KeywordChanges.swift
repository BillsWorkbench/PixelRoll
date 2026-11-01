import Foundation

nonisolated struct KeywordChange: Sendable {
    let photo: URL
    let notes: PhotoNotes
    let expected: Data?
}

nonisolated enum KeywordEditing {
    static func normalized(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        return keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func replacing(_ keywords: [String], selected: Set<String>, with destination: String?) -> [String] {
        let selected = Set(selected.map { $0.lowercased() })
        var result: [String] = []
        for keyword in keywords {
            if selected.contains(keyword.lowercased()) {
                if let destination { result.append(destination) }
            } else { result.append(keyword) }
        }
        return normalized(result)
    }
}
