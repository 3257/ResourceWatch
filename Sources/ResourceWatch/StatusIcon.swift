import AppKit
import SwiftUI

struct StatusIconView: View {
    let hasWarning: Bool
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Image(nsImage: StatusIcon.make(hasWarning: hasWarning, dark: colorScheme == .dark))
            .renderingMode(.original)
    }
}

enum StatusIcon {
    @MainActor static func make(hasWarning: Bool, dark: Bool) -> NSImage {
        // Preserve the pulse and reserve the dot's space so nearby items never shift.
        // Original rendering keeps the red badge from becoming a monochrome template.
        let image = NSImage(size: NSSize(width: 26, height: 18), flipped: false) { _ in
            let color: NSColor = dark ? .white : .black
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(.init(paletteColors: [color]))
            if let pulse = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                pulse.draw(in: NSRect(x: 0, y: 1, width: 18, height: 16))
            }
            if hasWarning {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 21, y: 6, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
