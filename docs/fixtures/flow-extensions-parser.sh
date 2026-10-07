#!/bin/bash
# Compile the production Flow reader with small app-type stubs when a full
# SwiftUI build cannot run; check the same copied Chrome fixture as the bench.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -R "$root/docs/fixtures/flow-chrome" "$tmp/chrome"
cat >"$tmp/stubs.swift" <<'SWIFT'
import Foundation
enum Chromium { struct Source { let root: URL } }
enum Crx {
    static func id(in text: String) -> String? {
        text.count == 32 && text.allSatisfy { ("a"..."p").contains(String($0)) } ? text : nil
    }
}
enum FlowModel {
    struct Extension: Hashable {
        let id: String
        let name: String
        let version: String
        let enabled: Bool
        let fromStore: Bool
    }
}
struct Installed { let id: String }
@MainActor final class Extensions {
    static let shared = Extensions()
    var installed: [Installed] = []
    func installAgreed(id: String, enabled: Bool = true) async -> Bool { true }
}
SWIFT
cat >"$tmp/main.swift" <<'SWIFT'
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let found = FlowExtensions.read(Chromium.Source(root: root))
let expected: [(String, String, Bool)] = [
    ("chfcgbnkddlkfkhikikhpgobgkldlnge", "Legacy on", true),
    ("laidppjhcioemjfoccijjjljnoalaknk", "Legacy off", false),
    ("oapfgjboacmhnapnjcdkknehbgkncfjh", "Empty reasons on", true),
    ("pkofjabddebjjolininjfgpdpgcoploh", "Array reasons off", false),
    ("dlemieilhfnlckjhbekagekefgdiffnb", "Integer reasons off", false),
    ("pdjnbnaahaogmghbglpphffnebkiiihl", "Split reasons off", false),
    ("dnbmiicpapilleohackflmdamggchhle", "No flags on", true),
    ("oelmapckalofldpfdcfkiaabgeplebec", "Zero reasons on", true),
]
var failed = 0
for (id, name, enabled) in expected {
    if found.contains(where: { $0.id == id && $0.name == name && $0.enabled == enabled }) {
        print("ok \(name) (\(id)): enabled=\(enabled)")
    } else {
        print("FAIL \(name) (\(id)): expected enabled=\(enabled)")
        failed += 1
    }
}
if found.count != expected.count { print("FAIL expected \(expected.count) extensions, found \(found.count)"); failed += 1 }
if failed > 0 { exit(1) }
print("ok 8/8 Chrome extension states in compiled Flow reader")
SWIFT
swiftc "$root/Sources/Search/Fork/Flow/FlowExtensions.swift" \
  "$root/Sources/Search/Fork/Flow/FlowExtensionState.swift" \
  "$tmp/stubs.swift" "$tmp/main.swift" -o "$tmp/check"
"$tmp/check" "$tmp/chrome"
