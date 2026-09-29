import SwiftUI

/// The window's Agents · Pull Requests · Review switch: even padding, each tab's shortcut beside
/// it, and a selection capsule that slides to the tab you pick.
@MainActor
@Observable
final class ModePickerModel {
    var selected: StationMode = .review
    @ObservationIgnored var onSelect: ((StationMode) -> Void)?
}

struct ModePicker: View {
    let model: ModePickerModel
    @Namespace private var capsule
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StationMode.allCases, id: \.self) { mode in
                let on = model.selected == mode
                Button { model.onSelect?(mode) } label: {
                    HStack(spacing: 6) {
                        Text(mode.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(on ? .primary : .secondary)
                        Text("⌘\(mode.rawValue + 1)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background {
                        if on {
                            Capsule().fill(.primary.opacity(0.1))
                                .matchedGeometryEffect(id: "selection", in: capsule)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(mode.title) (⌘\(mode.rawValue + 1))")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: model.selected)
        .fixedSize()
    }
}
