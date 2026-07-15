import Foundation
import os

enum JotlyLog {
    static let subsystem = "com.xingchen.Jotly"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let deepSeek = Logger(subsystem: subsystem, category: "deepseek")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let tool = Logger(subsystem: subsystem, category: "tool")
}
