import os

/// Log channels for the depth effect.
///
/// Keep trigger decisions and capture timings readable in Console.
enum DepthLog {
    private static let subsystem = "com.notchday.preview"

    static let lid = Logger(subsystem: subsystem, category: "depth.lid")
    static let render = Logger(subsystem: subsystem, category: "depth.render")
    static let capture = Logger(subsystem: subsystem, category: "depth.capture")
}
