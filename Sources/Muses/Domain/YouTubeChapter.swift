import Foundation

struct YouTubeChapter: Identifiable, Equatable, Sendable {
    let title: String
    let start: Double
    let end: Double?
    var id: Double { start }

    static func decode(_ data: Data, expectedVideoID: String) throws -> [Self] {
        struct Chapter: Decodable {
            let title: String?
            let start_time: Double?
            let end_time: Double?
        }
        struct Metadata: Decodable {
            let id: String
            let duration: Double?
            let chapters: [Chapter]?
        }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard metadata.id == expectedVideoID else {
            throw YTDlpBridge.YTDlpError.parseFailed("Chapter video identity mismatch")
        }
        var seen = Set<Double>()
        return (metadata.chapters ?? []).compactMap { chapter -> Self? in
            guard let start = chapter.start_time, start.isFinite, start >= 0,
                  metadata.duration.map({ $0.isFinite && start < $0 }) ?? true,
                  let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, seen.insert(start).inserted else { return nil }
            let end = chapter.end_time.flatMap { value in
                value.isFinite && value > start ? value : nil
            }
            return Self(title: title, start: start, end: end)
        }.sorted { $0.start < $1.start }
    }
}
