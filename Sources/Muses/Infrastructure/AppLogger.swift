import Foundation
import os

enum AppLog {
    private static let subsystem = "com.muses.app"
    static func `for`(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}