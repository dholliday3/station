import AppKit
import SwiftUI
import StoplightCore

/// The circular buttons in an expanded row (US-031). Users pick which appear and in what order.
enum RowAction: String, CaseIterable, Identifiable, Codable {
    case open, run, checks, queue, copyURL, share, copyBranch, copyHash, pin, fix, review, reviewInStation
    var id: String { rawValue }

    static let defaultOrder: [RowAction] = [.open, .reviewInStation, .run, .queue, .copyURL, .share, .copyHash, .pin, .fix, .review]

    var title: String {
        switch self {
        case .open: "Open on GitHub"
        case .run: "Actions run summary"
        case .checks: "Checks tab"
        case .queue: "Merge queue"
        case .copyURL: "Copy URL"
        case .share: "Share (title as a link)"
        case .copyBranch: "Copy branch name"
        case .copyHash: "Copy commit hash"
        case .pin: "Pin"
        case .fix: "Fix with your agent"
        case .review: "Adversarial review with your agent"
        case .reviewInStation: "Review in Station"
        }
    }

    var symbol: String {
        switch self {
        case .open: "arrow.up.right"
        case .run: "list.bullet.rectangle"
        case .checks: "checklist"
        case .queue: "line.3.horizontal"
        case .copyURL: "doc.on.doc"
        case .share: "square.and.arrow.up"
        case .copyBranch: "arrow.triangle.branch"
        case .copyHash: "number"
        case .pin: "pin"
        case .fix: "wrench.and.screwdriver"
        case .review: "eye.trianglebadge.exclamationmark"
        case .reviewInStation: Self.stationSymbol
        }
    }

    /// Whether this button makes sense for the row right now.
    @MainActor
    func isAvailable(for pr: PullRequest, model: AppModel) -> Bool {
        switch self {
        case .open, .copyURL, .share, .pin: true
        case .run: pr.actionsRunURL != nil
        case .checks: !pr.checks.isEmpty
        case .queue: pr.queueURL != nil
        case .copyBranch: !pr.headRefName.isEmpty
        case .copyHash: !pr.headSha.isEmpty
        case .fix: pr.state == .failure && model.canRunAgent(pr)
        case .review: model.canRunAgent(pr) && !pr.isBranch && pr.status == .open
        case .reviewInStation: !pr.isBranch && PRActions.stationInstalled
        }
    }
}

extension RowAction {
    /// Not an SF Symbol: Station's icon in outline (see `symbolImage`).
    static let stationSymbol = "station.review"

    /// The image for a row button's symbol: an SF Symbol, or the Station glyph.
    static func symbolImage(_ symbol: String) -> Image {
        symbol == stationSymbol ? Image(nsImage: stationGlyph).renderingMode(.template) : Image(systemName: symbol)
    }

    /// Station's icon in outline: three lines at 45° in a rounded square, to sit with the SF Symbols.
    private static let stationGlyph: NSImage = {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            let box = NSRect(x: 0.5, y: 0.5, width: 13, height: 13)
            let square = NSBezierPath(roundedRect: box, xRadius: 3.4, yRadius: 3.4)
            NSColor.black.set()
            NSGraphicsContext.saveGraphicsState()
            square.addClip()
            let q = CGFloat(0.5).squareRoot(), c = NSPoint(x: box.midX, y: box.midY)
            for k in [-1.0, 0, 1] {
                let o = NSPoint(x: c.x + k * 3.6 * q, y: c.y - k * 3.6 * q)
                let line = NSBezierPath()
                line.move(to: NSPoint(x: o.x - 12, y: o.y - 12)); line.line(to: NSPoint(x: o.x + 12, y: o.y + 12))
                line.lineWidth = 1.3; line.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.65, dy: 0.65), xRadius: 2.8, yRadius: 2.8)
            outline.lineWidth = 1.3; outline.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
