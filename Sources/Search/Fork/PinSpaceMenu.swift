import SwiftUI

// Fork (per-space pins): the pin menu's choice between this space and every
// space. Only there while Settings › Tabs › "Each space has its own pins" is
// on; with it off every pin is in every space, so there is nothing to choose.

struct PinSpaceButton: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var spaces = Spaces.shared

    var body: some View {
        if browser.prefs.perSpacePins, tab.pin != nil {
            let here = spaces.current(in: browser)
            if spaces.pinSpace(tab) == nil {
                Button("Keep to \(spaces.space(in: browser).title)") { spaces.setPinSpace(tab, only: here) }
            } else {
                Button("Show in Every Space") { spaces.setPinSpace(tab, only: nil) }
            }
        }
    }
}
