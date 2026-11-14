import SwiftUI

/// Feeds the live macOS reduce-motion preference into the animation model.
struct MotionPreferenceAdapter: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: GoobyAnimationModel

    static func mode(reduceMotion: Bool) -> GoobyMotionMode {
        reduceMotion ? .reduced : .normal
    }

    func body(content: Content) -> some View {
        content
            .onAppear { model.setMode(Self.mode(reduceMotion: reduceMotion)) }
            .onChange(of: reduceMotion) { _, newValue in
                model.setMode(Self.mode(reduceMotion: newValue))
            }
    }
}
