import Foundation
import SwiftData

/// 单行 SwiftData 模型,持久化队列状态。使用固定 UUID 做 upsert,
/// 使 `QueueService.restore()` 始终命中同一行。
@Model
final class QueueState {
    @Attribute(.unique) var id: UUID
    var itemsJSON: String
    var currentIndex: Int
    var upNextJSON: String
    var historyJSON: String
    var repeatModeRaw: String
    var shuffle: Bool
    var savedAt: Date

    /// 单例持久化行使用的固定 UUID。
    static let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    init(id: UUID = QueueState.sharedID,
         itemsJSON: String,
         currentIndex: Int,
         upNextJSON: String,
         historyJSON: String,
         repeatModeRaw: String,
         shuffle: Bool,
         savedAt: Date = .init()) {
        self.id = id
        self.itemsJSON = itemsJSON
        self.currentIndex = currentIndex
        self.upNextJSON = upNextJSON
        self.historyJSON = historyJSON
        self.repeatModeRaw = repeatModeRaw
        self.shuffle = shuffle
        self.savedAt = savedAt
    }
}