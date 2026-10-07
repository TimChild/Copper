import Foundation
import Testing
@testable import Search

// FlowBookmarks.merge and FlowBookmarks.taking (Fork/Flow/FlowBookmarks.swift)
// in linear time: the same answers as the per-node searches they replace,
// checked against a copy of those on seeded random trees, and 10,000 loose
// bookmarks taken in well under a second.

/// The merge and take as they were (quadratic), kept here as the reference.
private enum Reference {
    static func merge(_ incoming: [Bookmark], into result: inout [Bookmark]) {
        for node in incoming {
            if node.isFolder {
                if let index = result.firstIndex(where: { $0.isFolder && $0.title == node.title }) {
                    var children = result[index].children ?? []
                    merge(node.children ?? [], into: &children)
                    result[index].children = children
                } else {
                    result.append(node)
                }
            } else if !result.contains(where: { !$0.isFolder && $0.url == node.url && $0.title == node.title }) {
                result.append(node)
            }
        }
    }

    static func take(_ read: FlowBookmarks.Read, from source: String, roots current: [Bookmark],
                     previous: [Bookmark]) -> FlowBookmarks.Taken {
        var roots = current.filter { root in
            !read.complete || !previous.contains { $0.id == root.id && $0 == root }
        }
        var imported = read.complete ? [] : previous.filter { old in roots.contains(old) }
        for var node in read.nodes {
            if !read.complete, let index = roots.firstIndex(where: { root in
                previous.contains(root) && root.isFolder && node.isFolder &&
                (root.title == node.title || root.title == "\(node.title) (\(source))" ||
                 root.title.hasPrefix("\(node.title) (\(source)) "))
            }) {
                var children = roots[index].children ?? []
                merge(node.children ?? [], into: &children)
                roots[index].children = children
                if let owned = imported.firstIndex(where: { $0.id == roots[index].id }) {
                    imported[owned] = roots[index]
                }
                continue
            }
            if node.isFolder {
                if roots.contains(where: { $0.isFolder && $0.title == node.title }) {
                    node.title += " (\(source))"
                }
                var name = node.title
                var number = 2
                while roots.contains(where: { $0.isFolder && $0.title == name }) {
                    name = "\(node.title) \(number)"
                    number += 1
                }
                node.title = name
            } else if roots.contains(where: { !$0.isFolder && $0.url == node.url && $0.title == node.title }) {
                continue
            }
            roots.append(node)
            imported.append(node)
        }
        return FlowBookmarks.Taken(roots: roots, imported: imported)
    }
}

/// SplitMix64: the same trees on every run.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func tree(_ rng: inout Seeded, depth: Int, width: Int) -> [Bookmark] {
    // A few titles and addresses only, so folders and sites collide often.
    let titles = ["Work", "Work (Chrome)", "Work (Chrome) 2", "Read", "Misc", "News"]
    return (0..<Int.random(in: 0...width, using: &rng)).map { _ in
        if depth > 0, Int.random(in: 0..<3, using: &rng) == 0 {
            let title = titles[Int.random(in: 0..<titles.count, using: &rng)]
            let children = tree(&rng, depth: depth - 1, width: width)
            // Now and then a folder with no list at all (nil, not empty).
            return Int.random(in: 0..<5, using: &rng) == 0 && children.isEmpty
                ? Bookmark(title: title, url: nil, children: nil)
                : .folder(title, children)
        }
        let n = Int.random(in: 0..<6, using: &rng)
        return .site(["A", "B", "C"][n % 3], URL(string: "https://site\(n).invalid/")!)
    }
}

private func loose(_ count: Int, prefix: String = "page") -> [Bookmark] {
    (0..<count).map { .site("\(prefix) \($0)", URL(string: "https://\(prefix)\($0).invalid/")!) }
}

private func elapsed(_ work: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
}

@Suite("Flow bookmarks: linear merge and take")
struct FlowBookmarksMergeTests {
    @Test("merge gives the same tree as the per-node search, on 400 random trees")
    func mergeMatchesReference() {
        var rng = Seeded(state: 0xC0FFEE)
        for _ in 0..<400 {
            let base = tree(&rng, depth: 3, width: 6)
            let incoming = tree(&rng, depth: 3, width: 6)
            var fast = base
            var slow = base
            FlowBookmarks.merge(incoming, into: &fast)
            Reference.merge(incoming, into: &slow)
            #expect(fast == slow)
        }
    }

    @Test("take gives the same roots and record as before, complete and incomplete reads, on 600 random cases")
    func takeMatchesReference() {
        var rng = Seeded(state: 0xBEEF)
        let failed = [URL(fileURLWithPath: "/tmp/unreadable/Bookmarks")]
        for round in 0..<600 {
            // What this source brought last time, some of it since edited by
            // the person; their own roots around it.
            let previous = tree(&rng, depth: 2, width: 5)
            var current = tree(&rng, depth: 2, width: 3)
            for old in previous {
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: continue                               // deleted by the person
                case 1:                                         // edited
                    var edited = old
                    edited.title += " mine"
                    current.insert(edited, at: Int.random(in: 0...current.count, using: &rng))
                default:
                    current.insert(old, at: Int.random(in: 0...current.count, using: &rng))
                }
            }
            let read = FlowBookmarks.Read(nodes: tree(&rng, depth: 2, width: 6),
                                          failedFiles: round.isMultiple(of: 2) ? [] : failed)
            let source = round.isMultiple(of: 3) ? "Chrome" : "Arc"
            let fast = FlowBookmarks.taking(read, from: source, roots: current, previous: previous)
            let slow = Reference.take(read, from: source, roots: current, previous: previous)
            #expect(fast == slow, "round \(round)")
        }
    }

    @Test("10,000 loose bookmarks: merged and taken in linear time, and taking them again adds nothing")
    func tenThousand() {
        let many = loose(10_000)
        var merged: [Bookmark] = []
        let mergeTime = elapsed {
            FlowBookmarks.merge(many, into: &merged)
            FlowBookmarks.merge(many, into: &merged)   // every one already there
        }
        #expect(merged.count == 10_000)
        #expect(mergeTime < 1.0, "merge took \(mergeTime) s")

        // A person's own 10,000 beside them, and the read taken twice: the
        // second take replaces the first rather than doubling it.
        let own = loose(10_000, prefix: "mine")
        let read = FlowBookmarks.Read(nodes: many, failedFiles: [])
        var first = FlowBookmarks.Taken(roots: [], imported: [])
        var second = first
        let takeTime = elapsed {
            first = FlowBookmarks.taking(read, from: "Chrome", roots: own, previous: [])
            second = FlowBookmarks.taking(read, from: "Chrome", roots: first.roots, previous: first.imported)
        }
        #expect(first.roots.count == 20_000)
        #expect(first.imported.count == 10_000)
        #expect(second.roots.count == 20_000)
        #expect(Array(second.roots.prefix(10_000)) == own)
        #expect(takeTime < 1.0, "take took \(takeTime) s")

        // An unreadable file beside the read: nothing of the last take is
        // removed, and the 10,000 aren't added twice.
        let partial = FlowBookmarks.Read(nodes: many, failedFiles: [URL(fileURLWithPath: "/tmp/unreadable/Bookmarks")])
        var kept = first
        let partialTime = elapsed {
            kept = FlowBookmarks.taking(partial, from: "Chrome", roots: first.roots, previous: first.imported)
        }
        #expect(kept.roots.count == 20_000)
        #expect(partialTime < 1.0, "incomplete take took \(partialTime) s")
    }

    @Test("10,000 bookmarks in 1,000 same-named folders fold into one folder in linear time")
    func manyFolders() {
        let folders = (0..<1_000).map { n in Bookmark.folder("New folder", loose(10, prefix: "f\(n)-")) }
        var merged: [Bookmark] = []
        let time = elapsed { FlowBookmarks.merge(folders, into: &merged) }
        #expect(merged.count == 1)
        #expect(FlowBookmarks.count(merged) == 10_000)
        #expect(time < 1.0, "fold took \(time) s")
    }
}
