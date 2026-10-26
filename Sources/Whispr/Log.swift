import os

/// Structured logging. `NSLog` produced nothing retrievable for this process
/// (`log show --predicate 'process == "OpenWispr"'` returned zero lines), which is why the
/// 11 Aug meeting failure left no trace. Always `privacy: .public` — this is a local
/// dev tool and redacted logs are useless.
///
/// `.info`/`.debug` are NOT persisted. Use `.notice` for milestones and `.error` for failures.
///
/// Read back with:
///   log show --predicate 'subsystem == "org.openwispr.app"' --last 30m
enum Log {
    static let app = Logger(subsystem: "org.openwispr.app", category: "app")
    static let audio = Logger(subsystem: "org.openwispr.app", category: "audio")
}
