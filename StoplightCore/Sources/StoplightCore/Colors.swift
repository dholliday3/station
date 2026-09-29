import SwiftUI

public extension Color {
    /// GitHub's merged purple: #8250df in light mode, #a371f7 in dark. Same values GitHub uses for the merged badge.
    static let githubMerged = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(red: 0xa3/255, green: 0x71/255, blue: 0xf7/255, alpha: 1)
                    : NSColor(red: 0x82/255, green: 0x50/255, blue: 0xdf/255, alpha: 1)
    })
}
