import Foundation
import SwiftData

@Model
final class ScanRoot {
    @Attribute(.unique) var id: UUID
    var path: String
    var lastScannedAt: Date?
    var watch: Bool

    init(id: UUID = UUID(), path: String, lastScannedAt: Date? = nil, watch: Bool = true) {
        self.id = id; self.path = path; self.lastScannedAt = lastScannedAt; self.watch = watch
    }
}