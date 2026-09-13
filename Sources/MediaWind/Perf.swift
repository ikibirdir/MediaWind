import Foundation
import os

/// Timing logs. Watch them with:
///   log stream --predicate 'subsystem == "com.ikibirdir.MediaWind"'
enum Perf {
    static let log = Logger(subsystem: "com.ikibirdir.MediaWind", category: "perf")
    nonisolated(unsafe) static var launch: CFAbsoluteTime = 0

    static func ms(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
}
