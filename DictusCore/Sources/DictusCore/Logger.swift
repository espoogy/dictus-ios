// DictusCore/Sources/DictusCore/Logger.swift
import os.log

/// Centralized loggers for Dictus subsystems.
/// Usage: DictusLogger.keyboard.debug("message")
@available(iOS 14.0, macOS 11.0, *)
public enum DictusLogger {
    public static let app = Logger(subsystem: "io.aequari.dictus", category: "app")
    public static let keyboard = Logger(subsystem: "io.aequari.dictus", category: "keyboard")
    public static let appGroup = Logger(subsystem: "io.aequari.dictus", category: "appGroup")
}
