import Foundation

struct SmartShuffleState: Codable, Sendable {
    var enabled = false
    var collectionID = UUID()
    var collectionPlayed = 0
    var countedOccurrences = Set<UUID>()
    var playedVideoIDs = Set<String>()
    var pending: QueueItem?
}
