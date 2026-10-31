// DictusCore/Sources/DictusCore/LiveTextChannel.swift
// Self-hosted fork: live text while dictating (app -> keyboard), and the mic-ready window.
import Foundation

/// The App Group channel that carries live dictation text from DictusApp to the keyboard.
///
/// ## How it works
///
/// DictusApp runs a streaming model while the user speaks. Each time the transcript grows,
/// the app writes the WHOLE transcript so far (not a delta) plus a session id, and posts
/// `notification`. The keyboard remembers how much of that transcript it has already
/// inserted, and inserts only the new tail.
///
/// ## Rules that keep text from being lost or doubled
///
/// 1. The streaming model only appends. The keyboard inserts a tail only when the new
///    transcript starts with what it already inserted. Anything else is ignored and logged.
/// 2. The keyboard never deletes or rewrites text it inserted. If the user deletes words
///    while recording, those words stay deleted: the keyboard's cursor into the transcript
///    keeps moving forward, so they are never re-sent.
/// 3. At stop, the app hands off the final text as usual, and also marks the hand-off as
///    live (`markFinal`). The keyboard then inserts only the part it has not inserted yet,
///    and skips polish and the normal full insert. This is what prevents a double insert.
public enum LiveTextChannel {

    // MARK: - Keys

    static let sessionKey = "dictus.live.session"
    static let textKey = "dictus.live.text"
    static let finalSessionKey = "dictus.live.finalSession"

    /// User setting: use live text when it is possible. Default on.
    public static let enabledKey = "dictus.live.enabled"

    /// User setting: minutes the microphone stays ready in the background after use.
    public static let micReadyMinutesKey = "dictus.audio.micReadyMinutes"

    /// Posted by DictusApp each time the live transcript grows.
    public static let notification = "io.aequari.dictus.liveTextUpdated" as CFString

    // MARK: - Settings

    public static var isEnabled: Bool {
        AppGroup.defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// EXPERIMENT: turn the mic off between dictations (no orange dot) and try to turn
    /// it back on from the background. Default off.
    public static let micSleepKey = "dictus.audio.micSleepExperiment"

    public static var isMicSleepEnabled: Bool {
        AppGroup.defaults.bool(forKey: micSleepKey)
    }

    public static let micReadyChoices: [Int] = [10, 30, 60, 120]
    public static let defaultMicReadyMinutes = 30

    public static var micReadyMinutes: Int {
        let stored = AppGroup.defaults.integer(forKey: micReadyMinutesKey)
        return micReadyChoices.contains(stored) ? stored : defaultMicReadyMinutes
    }

    // MARK: - App side

    /// Starts a new live session. Clears any text from an earlier session.
    public static func begin(session: String, in defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(session, forKey: sessionKey)
        defaults.set("", forKey: textKey)
        defaults.removeObject(forKey: finalSessionKey)
        defaults.synchronize()
    }

    /// Writes the full transcript so far and tells the keyboard.
    public static func publish(session: String, text: String, in defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(session, forKey: sessionKey)
        defaults.set(text, forKey: textKey)
        defaults.synchronize()
        DarwinNotificationCenter.post(notification)
    }

    /// Marks the hand-off that follows as the end of a live session.
    public static func markFinal(session: String, in defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(session, forKey: finalSessionKey)
        defaults.synchronize()
    }

    /// Removes all live state (cancel, or a session that never produced text).
    public static func clear(in defaults: UserDefaults = AppGroup.defaults) {
        defaults.removeObject(forKey: sessionKey)
        defaults.removeObject(forKey: textKey)
        defaults.removeObject(forKey: finalSessionKey)
        defaults.synchronize()
    }

    // MARK: - Keyboard side

    /// The current session id and full transcript so far, if a live session exists.
    public static func read(in defaults: UserDefaults = AppGroup.defaults) -> (session: String, text: String)? {
        guard let session = defaults.string(forKey: sessionKey), !session.isEmpty else { return nil }
        return (session, defaults.string(forKey: textKey) ?? "")
    }

    /// The session id of a live hand-off, removed as it is read. Nil for a normal hand-off.
    public static func takeFinal(in defaults: UserDefaults = AppGroup.defaults) -> String? {
        guard let session = defaults.string(forKey: finalSessionKey) else { return nil }
        defaults.removeObject(forKey: finalSessionKey)
        defaults.synchronize()
        return session
    }

    static let keyboardSessionKey = "dictus.live.keyboardSession"
    static let keyboardInsertedKey = "dictus.live.keyboardInserted"

    /// What the keyboard has inserted so far, kept in the App Group so that a keyboard
    /// process iOS restarts mid-dictation does not insert the whole transcript again.
    public static func keyboardProgress(in defaults: UserDefaults = AppGroup.defaults) -> (session: String, inserted: String)? {
        guard let session = defaults.string(forKey: keyboardSessionKey) else { return nil }
        return (session, defaults.string(forKey: keyboardInsertedKey) ?? "")
    }

    public static func saveKeyboardProgress(session: String, inserted: String, in defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(session, forKey: keyboardSessionKey)
        defaults.set(inserted, forKey: keyboardInsertedKey)
    }

    /// Removes the keyboard's copy of the live text once the session is over, so no
    /// dictated text stays in shared storage.
    public static func clearKeyboardProgress(in defaults: UserDefaults = AppGroup.defaults) {
        defaults.removeObject(forKey: keyboardSessionKey)
        defaults.removeObject(forKey: keyboardInsertedKey)
    }

    /// The part of `transcript` that has not been inserted yet.
    ///
    /// Returns nil when `transcript` does not start with `alreadyInserted`. That should not
    /// happen with an append-only model; when it does, inserting nothing is safer than
    /// inserting a second copy of words the user can already see.
    public static func unsentTail(of transcript: String, alreadyInserted: String) -> String? {
        guard transcript.hasPrefix(alreadyInserted) else { return nil }
        return String(transcript.dropFirst(alreadyInserted.count))
    }
}
