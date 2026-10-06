import AppKit
import WebKit

// `./bench canvas checklist …` and `canvas check …`: the checklist shape
// (Canvas/src/canvas/checklist.ts) from the bench, on the board in front.
//
//   canvas checklist [SHAPE]        every checklist on the board (or one): title, columns,
//                                   rows with their picks and who made them, the tally
//   canvas check SHAPE COL ROW…     a real click on ROW's COL box — ROW a row id or label
//                                   (any case; the rest of the line), COL a column (any
//                                   case) — the way a person's click lands, through the
//                                   board's own pointer handling; answers the checklist
//                                   after it, and whether the box turned on or off
//
// The click is trusted mouse input (Input.click), so it proves the board
// takes one click on a box as a pick without selecting or editing the card.

@MainActor
enum CanvasChecklistBench {
    static func run(_ op: String, _ words: [String], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard let id = CanvasHost.active(in: browser), let host = CanvasHost.hosts(of: id).first(where: \.isReady),
              let web = host.tab?.built
        else { return answer(["error": "canvas \(op) — the tab in front is not a canvas that is up"]) }
        Task { @MainActor in
            do {
                if op == "checklist" {
                    let lists = try await checklists(host, only: words.first)
                    if let one = words.first, lists.isEmpty { return answer(["error": "no checklist \(one) on the board"]) }
                    return answer(["canvas": id, "checklists": lists])
                }
                guard words.count >= 3 else { return answer(["error": "canvas check SHAPE COL ROW…"]) }
                let shape = words[0], column = words[1], row = words[2...].joined(separator: " ")
                var cell = try await locate(host, shape: shape, row: row, column: column)
                if let error = cell["error"] { return answer(["error": error]) }
                if cell["visible"] as? Bool != true {
                    // Off screen: bring the card into view first, the way a person would scroll to it.
                    try await host.zoom(to: [shape])
                    try await Task.sleep(nanoseconds: 700_000_000)
                    cell = try await locate(host, shape: shape, row: row, column: column)
                    if let error = cell["error"] { return answer(["error": error]) }
                }
                guard Input.canPost(to: web), let x = cell["x"] as? Double, let y = cell["y"] as? Double else {
                    return answer(["error": "the board can't take a click now", "cell": cell])
                }
                let before = cell["checked"] as? Bool ?? false
                Input.click(web, at: CGPoint(x: x, y: y), button: "left", count: 1, modifiers: [])
                try await Task.sleep(nanoseconds: 250_000_000)
                let after = try await locate(host, shape: shape, row: row, column: column)
                let lists = try await checklists(host, only: shape)
                answer(["clicked": [x, y], "row": cell["row"] ?? row, "column": cell["column"] ?? column,
                        "was": before, "checked": after["checked"] as? Bool ?? false,
                        "checklist": lists.first ?? NSNull()])
            } catch {
                answer(["error": (error as? CanvasTools.Failure)?.text ?? error.localizedDescription])
            }
        }
    }

    /// The board's read (`copperCanvas.read`), checklists only.
    private static func checklists(_ host: CanvasHost, only: String?) async throws -> [[String: Any]] {
        let read = try await host.read(full: true)
        let shapes = read["shapes"] as? [[String: Any]] ?? []
        return shapes.filter { s in
            // A note in the checklist view (what this build writes) or a legacy checklist shape.
            (s["type"] as? String == "checklist" || s["view"] as? String == "checklist")
                && (only == nil || s["id"] as? String == only)
        }
    }

    /// Where ROW's COL box is on the page, in CSS px, and whether it is on.
    private static func locate(_ host: CanvasHost, shape: String, row: String, column: String) async throws -> [String: Any] {
        let raw = try await host.call("""
            const card = [...document.querySelectorAll('[data-kind="checklist"]')].find(el => el.dataset.id === shape);
            if (!card) return JSON.stringify({ error: 'no checklist ' + shape + ' on the board in front' });
            const fold = s => s.trim().toLowerCase();
            const cells = [...card.querySelectorAll('[data-cell]')];
            let rowId = cells.some(c => c.dataset.row === row) ? row : null;
            if (!rowId) {
              const named = [...card.querySelectorAll('[role="row"]')].filter(r => {
                const t = r.querySelector('.cl-label-text');
                return t && fold(t.textContent || '') === fold(row);
              });
              if (named.length > 1) return JSON.stringify({ error: 'more than one row is called ' + row + ' — use its id' });
              rowId = named[0]?.querySelector('[data-cell]')?.dataset.row ?? null;
            }
            if (!rowId) return JSON.stringify({ error: 'no row ' + row + ' in ' + shape });
            const cell = cells.find(c => c.dataset.row === rowId && fold(c.dataset.col || '') === fold(column));
            if (!cell) return JSON.stringify({ error: 'no column ' + column + ' in ' + shape });
            const r = cell.getBoundingClientRect();
            const x = r.left + r.width / 2, y = r.top + r.height / 2;
            const hit = document.elementFromPoint(x, y);
            return JSON.stringify({
              x, y, row: rowId, column: cell.dataset.col,
              checked: cell.getAttribute('aria-checked') === 'true',
              visible: x > 0 && y > 0 && x < innerWidth && y < innerHeight && !!hit && cell.contains(hit),
            });
            """, ["shape": shape, "row": row, "column": column])
        guard let text = raw as? String, let data = text.data(using: .utf8),
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return ["error": "the canvas page gave back nothing"] }
        return value
    }
}
