import SwiftUI

extension Color {
    init(_ rgb: GoobyRGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

/// One glossy black dot eye with a tiny highlight; squashes vertically to blink.
struct GoobyEyeView: View {
    let openness: CGFloat

    var body: some View {
        let m = GoobyVisualMetrics.self
        let open = max(0, min(1, openness))
        ZStack {
            Ellipse()
                .fill(Color(m.feature))
            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 1.1, height: 1.1)
                .offset(x: -0.7, y: -0.8)
                .opacity(open > 0.6 ? 1 : 0)
        }
        .frame(width: m.eyeSize.width, height: m.eyeSize.height)
        // Keep a hairline when closed so the blink reads as a closed eye, not a vanish.
        .scaleEffect(x: 1, y: max(open, 0.14), anchor: .center)
    }
}
