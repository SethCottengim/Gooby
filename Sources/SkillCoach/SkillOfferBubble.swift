import AppKit
import SwiftUI

/// What the bubble is saying right now.
@MainActor
final class SkillBubbleState: ObservableObject {
    enum Content: Equatable {
        case offer(SkillOffer)
        case message(String)
    }
    @Published var content: Content?
    var onAnswer: (@MainActor (SkillOfferAnswer) -> Void)?
}

struct SkillBubbleView: View {
    static let width: CGFloat = 250
    @ObservedObject var state: SkillBubbleState

    var body: some View {
        Group {
            switch state.content {
            case let .offer(offer):
                VStack(alignment: .leading, spacing: 8) {
                    if let label = offer.chatLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.black.opacity(0.55))
                            .lineLimit(2) // "<folder> · <chat title>" often needs two lines
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("You've asked me to “\(offer.summary)” in \(offer.sessionCount) chats. Want a shortcut?")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("/\(offer.skillName)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    HStack {
                        Spacer()
                        Button("No thanks") { answer(.decline) }
                        Button("Make it") { answer(.accept) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            case let .message(text):
                Text(text).fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.black)
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        )
        .padding(4) // room for the shadow
    }

    private func answer(_ choice: SkillOfferAnswer) {
        let handler = state.onAnswer
        state.onAnswer = nil
        handler?(choice)
    }
}

/// Accepts the first click so the buttons work while Gooby's app stays inactive.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A speech bubble in its own non-activating panel, attached above Gooby's panel
/// as a child window so it moves with Gooby. Shown only while Gooby is on screen.
@MainActor
final class SkillOfferBubble: SkillOfferPresenting {
    static let messageDuration: TimeInterval = 6
    /// How long an unanswered offer stays up.
    static let offerTimeout: TimeInterval = 120
    nonisolated static let gap: CGFloat = 2

    private let anchor: @MainActor () -> NSPanel?
    private let state = SkillBubbleState()
    private var panel: NonActivatingGoobyPanel?
    private var visibilityTimer: Timer?
    private var messageDismissal: DispatchWorkItem?

    init(anchor: @escaping @MainActor () -> NSPanel?) {
        self.anchor = anchor
    }

    func showOffer(_ offer: SkillOffer, onAnswer: @escaping @MainActor (SkillOfferAnswer) -> Void) {
        messageDismissal?.cancel()
        state.onAnswer = onAnswer
        state.content = .offer(offer)
        activate()
        // Unanswered offers close after a while: the moment has passed. Not a No.
        let expiry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .offer = self.state.content, let handler = self.state.onAnswer else { return }
                self.state.onAnswer = nil
                self.dismiss()
                handler(.expired)
            }
        }
        messageDismissal = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.offerTimeout, execute: expiry)
    }

    func showMessage(_ text: String) {
        state.onAnswer = nil
        state.content = .message(text)
        activate()
        messageDismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        messageDismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.messageDuration, execute: work)
    }

    func dismiss() {
        state.content = nil
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    private func activate() {
        let panel = preparePanel()
        if let hosting = panel.contentView {
            let size = hosting.fittingSize
            panel.setContentSize(size)
            hosting.frame = NSRect(origin: .zero, size: size)
        }
        syncVisibility()
        if visibilityTimer == nil {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncVisibility() }
            }
            RunLoop.main.add(timer, forMode: .common)
            visibilityTimer = timer
        }
    }

    private func preparePanel() -> NonActivatingGoobyPanel {
        if let panel { return panel }
        let panel = NonActivatingGoobyPanel(contentRect: NSRect(x: 0, y: 0, width: SkillBubbleView.width, height: 80))
        panel.contentView = FirstClickHostingView(rootView: SkillBubbleView(state: state))
        self.panel = panel
        return panel
    }

    /// Follows Gooby: visible (and attached) while Gooby is, hidden otherwise.
    private func syncVisibility() {
        guard let panel, state.content != nil else { return }
        guard let gooby = anchor(), gooby.isVisible, gooby.alphaValue > 0.5 else {
            if panel.isVisible {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            return
        }
        panel.level = gooby.level
        panel.setFrameOrigin(Self.origin(bubble: panel.frame.size, gooby: gooby.frame, screen: gooby.screen?.visibleFrame))
        if panel.parent !== gooby {
            panel.parent?.removeChildWindow(panel)
            gooby.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Centered above Gooby, kept on screen; below Gooby if there's no room above.
    nonisolated static func origin(bubble: CGSize, gooby: CGRect, screen: CGRect?) -> CGPoint {
        var x = gooby.midX - bubble.width / 2
        var y = gooby.maxY + gap
        if let screen {
            if y + bubble.height > screen.maxY { y = gooby.minY - gap - bubble.height }
            x = min(max(x, screen.minX), screen.maxX - bubble.width)
        }
        return CGPoint(x: x, y: y)
    }
}
