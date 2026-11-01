// DictusApp/Views/LearnedWordsView.swift
// Self-hosted fork: shows the words the keyboard has learned, and lets the user remove one.
import SwiftUI
import DictusCore

/// The keyboard's learned-words list (`UserDictionary`), read from the App Group.
///
/// Words get here two ways, both from typing (not from dictation): a word the dictionary
/// does not know, typed twice; or an autocorrection the user undid. Learned words are
/// never autocorrected, so removing a typo here makes autocorrect fix it again.
struct LearnedWordsView: View {
    @State private var words: [String] = []
    @State private var searchText = ""

    private var shownWords: [String] {
        guard !searchText.isEmpty else { return words }
        return words.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            if words.isEmpty {
                Section {
                    Text("No learned words yet.")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("The keyboard learns a word when you type a word it does not know two times, or when you undo an autocorrection. Dictated words are not learned.")
                }
            } else {
                Section {
                    ForEach(shownWords, id: \.self) { word in
                        Text(word)
                    }
                    .onDelete { offsets in
                        let removed = offsets.map { shownWords[$0] }
                        removed.forEach { UserDictionary.shared.forget($0) }
                        reload()
                    }
                } footer: {
                    Text("Swipe left on a word to remove it. Learned words are never autocorrected.")
                }
            }
        }
        .searchable(text: $searchText)
        .navigationTitle("Learned words (\(words.count))")
        .onAppear(perform: reload)
    }

    private func reload() {
        // The keyboard writes from its own process: re-read the App Group first.
        UserDictionary.shared.reload()
        words = UserDictionary.shared.allLearnedWords.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
