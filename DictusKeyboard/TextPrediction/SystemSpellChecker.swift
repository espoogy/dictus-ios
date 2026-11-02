// DictusKeyboard/TextPrediction/SystemSpellChecker.swift
// Self-hosted fork: Apple's spell checker, for words too misspelled for the trie.
import UIKit

/// Asks iOS's own spell checker (`UITextChecker`) for corrections.
///
/// The trie corrects words within about 2 edits. Apple's keyboard also fixes words that
/// are typed much more wrongly ("becuz" -> "because"). `UITextChecker` is the public API
/// of the iOS spell checker. It runs on the device and does not use the network.
///
/// WHY only as a fallback (see `TextPredictionEngine.systemSpellCheck`): the trie knows
/// the key layout (near-miss keys) and the n-gram context, so it is the better judge of
/// small typos. This runs only when the trie found nothing.
enum SystemSpellChecker {

    /// Apple's guesses for `word`, best first. Empty when iOS thinks the word is spelled
    /// right, has no guess, or has no spell checker for `language`.
    ///
    /// Safe to call from any thread. `UITextChecker` is main-actor only, so a call from
    /// the suggestion queue hops to the main thread. That cannot deadlock: nothing on the
    /// main thread waits for the suggestion queue (it is only ever used with `async`).
    static func guesses(for word: String, language: String) -> [String] {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { lookUp(word, language: language) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { lookUp(word, language: language) }
        }
    }

    @MainActor private static let checker = UITextChecker()

    /// Keyboard language ("en") -> spell checker language ("en_US"). Nil value: none.
    @MainActor private static var languageCache: [String: String?] = [:]

    @MainActor
    private static func lookUp(_ word: String, language: String) -> [String] {
        guard let code = checkerLanguage(for: language) else { return [] }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let misspelled = checker.rangeOfMisspelledWord(
            in: word, range: range, startingAt: 0, wrap: false, language: code
        )
        guard misspelled.location != NSNotFound else { return [] }
        return checker.guesses(forWordRange: range, in: word, language: code) ?? []
    }

    /// The first spell checker language that matches the keyboard language.
    /// `availableLanguages` is in the user's preference order.
    @MainActor
    private static func checkerLanguage(for language: String) -> String? {
        if let cached = languageCache[language] { return cached }
        let wanted = language.lowercased()
        let available = UITextChecker.availableLanguages
        let match = available.first { $0.lowercased() == wanted }
            ?? available.first {
                let code = $0.lowercased()
                return code.hasPrefix(wanted + "_") || code.hasPrefix(wanted + "-")
            }
        languageCache[language] = match
        return match
    }
}
