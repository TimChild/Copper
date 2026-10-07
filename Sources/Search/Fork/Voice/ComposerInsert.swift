import AppKit

// Where dictated words land: the agent composer, at the caret it had when
// the dictation started, once, as one edit ⌘Z takes back. Never a web page,
// never another field — if the window's field editor can't be shown to be
// the composer's, the words are spliced into `Agent.draft` itself, which is
// what the composer shows.
//
// Offsets are UTF-16, the unit NSTextView's ranges count in, so a caret
// after an emoji or an accented letter means the same place in both.

@MainActor
enum ComposerInsert {
    /// The composer as it was when a dictation started: its text and the
    /// selection in it, and the field editor that had them, if it was the
    /// composer's.
    struct Anchor {
        let draft: String
        let range: NSRange
        weak var editor: NSTextView?
        weak var window: NSWindow?
    }

    /// Where a dictation starting now would put its words. In the composer's
    /// own editor when it has the keyboard; else at the end of the draft.
    static func capture(in window: NSWindow?, draft: String) -> Anchor {
        if let editor = composerEditor(in: window, draft: draft) {
            return Anchor(draft: draft, range: clamp(editor.selectedRange(), in: draft), editor: editor, window: window)
        }
        let end = (draft as NSString).length
        return Anchor(draft: draft, range: NSRange(location: end, length: 0), editor: nil, window: window)
    }

    /// The window's field editor, only when it is editing the agent
    /// composer: the pane says the composer has the keyboard in this window,
    /// the editor is a field editor working for a text field in it, and it
    /// holds exactly the draft.
    static func composerEditor(in window: NSWindow?, draft: String) -> NSTextView? {
        guard let window, Voice.shared.composerFocused(in: window),
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField, field.window === window,
              editor.string == draft
        else { return nil }
        return editor
    }

    /// What one insert did.
    struct Landed: Equatable {
        /// The words as they went in, with any space added around them.
        let piece: String
        let draft: String
        /// The caret after it, in UTF-16.
        let caret: Int
        /// "editor" (through the field editor, its own undo) or "draft".
        let via: String
    }

    /// Puts `text` into the composer at `anchor`. The draft may have moved
    /// on since the anchor was taken (typed into while talking in toggle
    /// mode): then the editor's caret now, or the end.
    @discardableResult
    static func insert(_ text: String, at anchor: Anchor, agent: Agent) -> Landed? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        let current = agent.draft
        let editor = composerEditor(in: anchor.window, draft: current)
        var range = anchor.range
        if current != anchor.draft {
            range = editor.map { $0.selectedRange() } ?? NSRange(location: (current as NSString).length, length: 0)
        }
        let planned = splice(current, range: range, text: words)
        if let editor {
            // The editor's own insert: one undoable edit, the caret after it,
            // and the text field tells SwiftUI, which sets the draft.
            editor.breakUndoCoalescing()
            editor.insertText(planned.piece, replacementRange: planned.replaced)
            editor.breakUndoCoalescing()
            editor.undoManager?.setActionName("Dictation")
            if agent.draft != editor.string { agent.draft = editor.string }
            return Landed(piece: planned.piece, draft: agent.draft, caret: editor.selectedRange().location, via: "editor")
        }
        agent.draft = planned.draft
        if let undo = anchor.window?.undoManager {
            undo.registerUndo(withTarget: agent) { agent in
                MainActor.assumeIsolated { if agent.draft == planned.draft { agent.draft = current } }
            }
            undo.setActionName("Dictation")
        }
        return Landed(piece: planned.piece, draft: planned.draft, caret: planned.caret, via: "draft")
    }

    /// The selection the dictation started with, back where it was — after
    /// a cancel, when the composer still holds the same text.
    static func restore(_ anchor: Anchor, agent: Agent) {
        guard let editor = composerEditor(in: anchor.window, draft: agent.draft), agent.draft == anchor.draft else { return }
        editor.setSelectedRange(anchor.range)
    }

    // MARK: - the arithmetic (pure)

    /// `text` into `draft` over `range` (UTF-16), with one space before it
    /// unless it starts the draft or follows whitespace, and one after it
    /// when it would otherwise run into a letter or a digit. A range that
    /// splits a character or runs past the end is widened or cut to fit.
    nonisolated static func splice(_ draft: String, range: NSRange, text: String) -> (draft: String, piece: String, caret: Int, replaced: NSRange) {
        let ns = draft as NSString
        let r = clamp(range, in: draft)
        var piece = text
        if r.location > 0 {
            let before = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: r.location - 1))
            if !(before.unicodeScalars.last.map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? true) { piece = " " + piece }
        }
        let end = r.location + r.length
        if end < ns.length {
            let after = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: end))
            if let first = after.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) { piece += " " }
        }
        let out = ns.replacingCharacters(in: r, with: piece)
        return (out, piece, r.location + (piece as NSString).length, r)
    }

    /// A range inside the draft that starts and ends on character boundaries.
    nonisolated static func clamp(_ range: NSRange, in draft: String) -> NSRange {
        let ns = draft as NSString
        let length = ns.length
        guard range.location != NSNotFound else { return NSRange(location: length, length: 0) }
        let start = min(max(range.location, 0), length)
        let end = min(start + max(range.length, 0), length)
        // The start moves back to its character's beginning; a selection's
        // end moves on to its character's end. A caret stays a caret.
        let snappedStart = start < length ? ns.rangeOfComposedCharacterSequence(at: start).location : length
        guard end > start else { return NSRange(location: snappedStart, length: 0) }
        var snappedEnd = end
        if end < length {
            let around = ns.rangeOfComposedCharacterSequence(at: end)
            if around.location < end { snappedEnd = around.location + around.length }
        }
        return NSRange(location: snappedStart, length: snappedEnd - snappedStart)
    }

    /// `voice selftest`'s checks of the arithmetic: failures, as sentences.
    nonisolated static func checks() -> [String] {
        var failures: [String] = []
        func expect(_ name: String, _ draft: String, _ range: NSRange, _ text: String, _ wanted: String, caret: Int? = nil) {
            let got = splice(draft, range: range, text: text)
            if got.draft != wanted { failures.append("\(name): got “\(got.draft)”, wanted “\(wanted)”") }
            if let caret, got.caret != caret { failures.append("\(name): caret \(got.caret), wanted \(caret)") }
        }
        // An empty draft: just the words.
        expect("empty draft", "", NSRange(location: 0, length: 0), "Open the logs", "Open the logs", caret: 13)
        // At the end of a sentence: one space before.
        expect("after text", "Check the build.", NSRange(location: 16, length: 0), "Then file a bug", "Check the build. Then file a bug", caret: 32)
        // After a space or a newline: no second one.
        expect("after a space", "Check ", NSRange(location: 6, length: 0), "this", "Check this", caret: 10)
        expect("after a newline", "Line one\n", NSRange(location: 9, length: 0), "line two", "Line one\nline two", caret: 17)
        // Mid-text, caret between two words' spaces: space before only.
        expect("caret mid-text", "Check  the build", NSRange(location: 6, length: 0), "quickly", "Check quickly the build", caret: 13)
        // Mid-word on the right: a space after, so it doesn't run in.
        expect("caret before a word", "Check build", NSRange(location: 6, length: 0), "the", "Check the build", caret: 10)
        // A selection ending inside an emoji takes the whole emoji.
        expect("selection into an emoji", "a👋b", NSRange(location: 0, length: 2), "x", "x b", caret: 2)
        // A selection replaced, spacing kept.
        expect("selection replaced", "Check the old build", NSRange(location: 10, length: 3), "new", "Check the new build", caret: 13)
        expect("whole draft selected", "draft", NSRange(location: 0, length: 5), "Spoken words", "Spoken words", caret: 12)
        // UTF-16: an emoji is two code units (a skin tone four); the caret after it.
        let wave = "Hi 👋🏽"
        expect("after an emoji", wave, NSRange(location: (wave as NSString).length, length: 0), "there", "Hi 👋🏽 there", caret: (wave as NSString).length + 6)
        // A caret inside a surrogate pair moves to the character's start.
        expect("inside a surrogate pair", "a👋b", NSRange(location: 2, length: 0), "x", "a x👋b")
        // Past the end: clamped to it.
        expect("past the end", "abc", NSRange(location: 99, length: 4), "d", "abc d", caret: 5)
        expect("not found", "abc", NSRange(location: NSNotFound, length: 0), "d", "abc d")
        // Accented text before the caret counts in UTF-16, not bytes.
        expect("accents", "Café", NSRange(location: 4, length: 0), "au lait", "Café au lait", caret: 12)
        // Punctuation after the caret: no space added before it.
        expect("before punctuation", "Hello.", NSRange(location: 5, length: 0), "world", "Hello world.", caret: 11)
        return failures
    }
}
