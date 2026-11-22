import os

/// `os.Logger` categories used across DiskSift.
public enum Log {
    public static let subsystem = "dev.disksift.DiskSift"

    public static let scan = Logger(subsystem: subsystem, category: "scan")
    public static let size = Logger(subsystem: subsystem, category: "size")
    public static let removal = Logger(subsystem: subsystem, category: "removal")
    public static let command = Logger(subsystem: subsystem, category: "command")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
