import Foundation

/// 队列分组(Phase 19 Advanced Queue)。
///
/// 设计决策(Final Spec §10.4 / §10.5):`QueueGroup` 不作为独立 SwiftData `@Model`
/// 表,而是与 `QueueItem` 一样作为 `Codable` 值类型,序列化进单行 `QueueState.groupsJSON`。
/// 理由:
/// 1. 与现有 `QueueItem`(itemsJSON)同构,保持队列子系统「单行原子持久化」的约定;
/// 2. §10.5 要求「queue + groups + locked state」在崩溃中一并存活,单行 upsert 给出
///    原子性,跨表则需多行一致性,更脆弱;
/// 3. 分组数量级很小(个位数),不需要 SwiftData 索引查询。
/// Spec 中「`QueueGroup` @Model」的字面表述与此冲突,以本文件实现为准(已记录于 Phase 19
/// commit 说明)。
///
/// `order` 为排序索引(升序);`collapsed` 控制折叠态(仅影响 UI 展示)。
struct QueueGroup: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var name: String
    var order: Int
    var collapsed: Bool

    init(id: UUID = UUID(), name: String, order: Int, collapsed: Bool = false) {
        self.id = id; self.name = name; self.order = order; self.collapsed = collapsed
    }
}