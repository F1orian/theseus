import DesignSystem
public import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The left navigation drawer (CHATS-01): the drawer sits still under the content, and opening
/// it slides the content aside as a card — its leading corners concentric with the display's,
/// a hairline edge, progressively dimmed. Drag right anywhere on the content
/// to open (iOS; `DrawerPanGesture` keeps horizontal scrollers, text fields and the back swipe
/// their gestures); tap or drag the dimmed content to close. Content can open it through
/// `\.drawer`.
///
/// Motion (ADR 0130): every change of `isOpen` slides — a tap on the header button, a row that
/// navigates, a keyboard shortcut — with `Motion.drawer`. A drag tracks the finger 1:1 and, on
/// release, settles with a spring that starts at the finger's speed (`Motion.drawerSettle`), to
/// whichever side the predicted end lands on. Reduce Motion moves it without animation.
public struct DrawerContainer<Drawer: View, Content: View>: View {
    @Binding private var isOpen: Bool
    private let drawer: Drawer
    private let content: Content

    /// What's on screen: follows `isOpen`, but animated, whoever changed it.
    @State private var shownOpen = false
    /// The finger's horizontal travel while a drag tracks the drawer.
    @State private var dragTranslation: CGFloat = 0
    /// Resets when the system cancels a drag (no `onEnded`), so the drawer can settle back.
    @GestureState private var isDragging = false
    /// Whether the drawer is on screen at all: while open, dragged or sliding closed. A closed
    /// drawer isn't rendered, so VoiceOver and Full Keyboard Access can't reach its rows behind
    /// the content (PLAT-06; `accessibilityHidden` doesn't reach into its scroll view).
    @State private var isPresent = false
    /// The drawer's content asked for the whole screen (its search, #172).
    @State private var isExpanded = false
    /// The bottom safe-area inset including the keyboard, while it's up.
    @State private var keyboardBottom: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Touches starting this close to the left edge can drag the drawer open.
    private static var edgeWidth: CGFloat { 24 }

    public init(isOpen: Binding<Bool>, @ViewBuilder drawer: () -> Drawer, @ViewBuilder content: () -> Content) {
        _isOpen = isOpen
        self.drawer = drawer()
        self.content = content()
    }

    public var body: some View {
        // The outer reader keeps the safe-area insets for the drawer; the inner one lays out edge
        // to edge so the slid-aside content shows its rounded corners. Neither sees the keyboard
        // (#170): the drawer and the card always lay out against the full screen. The screens
        // inside still keep their composer above the keyboard (`ChatsLibraryUITests` checks it).
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            drawerLayout(insets: insets)
                .ignoresSafeArea(.container)
        }
        .ignoresSafeArea(.keyboard)
        // Where the keyboard is, for the drawer's own search (#172): this reader does see it.
        .background {
            GeometryReader { keyboard in
                Color.clear.onChange(of: keyboard.safeAreaInsets.bottom, initial: true) { _, bottom in
                    keyboardBottom = bottom
                }
            }
        }
        .themedBackground()
    }

    private func drawerLayout(insets: EdgeInsets) -> some View {
        GeometryReader { geometry in
            let width = isExpanded ? geometry.size.width : Self.drawerWidth(for: geometry.size.width)
            let offset = Self.offset(open: shownOpen, translation: dragTranslation, width: width)
            let progress = width > 0 ? offset / width : 0

            ZStack(alignment: .topLeading) {
                if shownOpen || isPresent || dragTranslation != 0 {
                    // The drawer's surface spans the whole screen behind the card, so the card's
                    // rounded corners show the drawer, not the canvas, past the drawer's width.
                    Palette.recessedSurface.color
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                        .transition(.identity)
                }
                if shownOpen || isPresent || dragTranslation != 0 {
                    drawer
                        .padding(.top, insets.top)
                        .padding(.bottom, insets.bottom)
                        // Its search lists results above the keyboard it brings up; otherwise the
                        // drawer lays out against the full screen (#170).
                        .safeAreaPadding(.bottom, isExpanded ? max(0, keyboardBottom - insets.bottom) : 0)
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(Palette.recessedSurface.color.ignoresSafeArea())
                        .accessibilityHidden(!isOpen)
                        // While open, VoiceOver stays in the drawer (the dimmed content is inert).
                        .accessibilityAddTraits(isOpen ? .isModal : [])
                        // VoiceOver's escape (two-finger Z) closes it. On the drawer, not the whole
                        // container: an action there makes an unlabelled screen-sized element.
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Sidebar")
                        .accessibilityAction(.escape) { setOpen(false) }
                        .allowsHitTesting(isOpen)
                        .transition(.identity)
                }

                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .environment(\.drawer, DrawerAction { open in
                        setOpen(open ?? !isOpen)
                    })
                    // The card is opaque edge to edge: the screens inside don't all paint their
                    // own background (at rest the container's shows through).
                    .background(Palette.background.color)
                    .modifier(DrawerCard(
                        progress: progress, isPresent: shownOpen || isPresent || dragTranslation != 0,
                        isOpen: isOpen, edgeHighlight: edgeHighlight
                    ) { setOpen(false) })
                    .offset(x: offset)
                    .accessibilityHidden(isOpen)
            }
            #if os(iOS)
            // A UIKit recognizer (UIGestureRecognizerRepresentable) attaches with `gesture(_:)`;
            // its delegate does the arbitration with scroll views and taps.
            .gesture(DrawerPanGesture(
                isOpen: shownOpen,
                isEnabled: !isExpanded,
                onChanged: { translation in track(translation) },
                onEnded: { translation, velocity, predicted in
                    settle(translation: translation, velocity: velocity, predicted: predicted, width: width)
                },
                onCancelled: { cancelDrag() }
            ))
            // The recognizer turns the container into an (unlabelled, screen-sized)
            // accessibility element; it's only a container of the drawer and the screen (PLAT-06).
            .accessibilityElement(children: .contain)
            #else
            .simultaneousGesture(dragGesture(width: width))
            #endif
            // The drawer's search takes the whole screen: the card slides fully aside, then back
            // to its strip (or the drawer closes from there). A removed drawer resets it.
            .onPreferenceChange(DrawerExpandedPreferenceKey.self) { expanded in
                withMotion(Motion.drawer) { isExpanded = expanded }
            }
            .onChange(of: isOpen, initial: true) { _, open in
                if open { beginOpening() }
                guard shownOpen != open else { return }
                // Someone else changed it (the header button, a row navigating, ⌘\): slide.
                withAnimation(reduceMotion ? nil : Motion.drawer) { shownOpen = open }
                if !open { removeAfterSlide() }
            }
            .onChange(of: isDragging) { _, dragging in
                // The system cancelled the drag without an end: settle where it was.
                if !dragging, dragTranslation != 0 {
                    withAnimation(reduceMotion ? nil : Motion.drawer) { dragTranslation = 0 }
                    if !isOpen { removeAfterSlide() }
                }
            }
        }
    }

    /// A light hairline that separates the card from the drawer in dark mode; in
    /// light mode the dim and the shadow are enough, and a line reads as an artifact.
    private var edgeHighlight: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .clear
    }

    static func drawerWidth(for containerWidth: CGFloat) -> CGFloat {
        min(containerWidth * 0.8, 340)
    }

    /// The content's offset: the resting position plus the drag, kept between closed and open.
    static func offset(open: Bool, translation: CGFloat, width: CGFloat) -> CGFloat {
        min(max((open ? width : 0) + translation, 0), width)
    }

    /// The drawer starts to show (a button, a drag, a shortcut, a navigation): it's on screen from
    /// now on, and the keyboard goes away (#170): whatever had focus is behind the
    /// dimmed card now.
    private func beginOpening() {
        isPresent = true
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    /// Takes the closed drawer out once the slide-out has finished.
    private func removeAfterSlide() {
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !isOpen, !shownOpen, dragTranslation == 0 { isPresent = false }
        }
    }

    private func setOpen(_ open: Bool) {
        if open { beginOpening() }
        withAnimation(reduceMotion ? nil : Motion.drawer) {
            isOpen = open
            shownOpen = open
        }
        if !open { removeAfterSlide() }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .updating($isDragging) { value, state, _ in
                if isTracking(value) { state = true }
            }
            .onChanged { value in
                guard isTracking(value) else { return }
                isPresent = true
                // 1:1 with the finger, outside any animation.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { dragTranslation = value.translation.width }
            }
            .onEnded { value in
                guard isTracking(value) || dragTranslation != 0 else { return }
                settle(value, width: width)
            }
    }

    /// Moves the content with the finger, outside any animation.
    private func track(_ translation: CGFloat) {
        if !shownOpen, dragTranslation == 0 { beginOpening() }
        isPresent = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { dragTranslation = translation }
    }

    /// The system cancelled the drag: settle where it was.
    private func cancelDrag() {
        guard dragTranslation != 0 else { return }
        withAnimation(reduceMotion ? nil : Motion.drawer) { dragTranslation = 0 }
        if !isOpen { removeAfterSlide() }
    }

    private func settle(_ value: DragGesture.Value, width: CGFloat) {
        settle(translation: value.translation.width, velocity: value.velocity.width, predicted: value.predictedEndTranslation.width, width: width)
    }

    /// Settles to the side the predicted end lands on, starting at the finger's speed.
    private func settle(translation: CGFloat, velocity: CGFloat, predicted: CGFloat, width: CGFloat) {
        let current = Self.offset(open: shownOpen, translation: translation, width: width)
        let projected = (shownOpen ? width : 0) + predicted
        let open = projected > width / 2
        let target: CGFloat = open ? width : 0
        let towardsTarget = open ? velocity : -velocity
        let animation = reduceMotion ? nil : Motion.drawerSettle(velocity: towardsTarget, distance: abs(target - current))
        if open { isPresent = true }
        withAnimation(animation) {
            isOpen = open
            shownOpen = open
            dragTranslation = 0
        }
        if !open { removeAfterSlide() }
    }

    /// Horizontal drags only: from the left edge while closed, anywhere while open.
    private func isTracking(_ value: DragGesture.Value) -> Bool {
        guard abs(value.translation.width) > abs(value.translation.height) else { return false }
        return shownOpen || value.startLocation.x < Self.edgeWidth
    }
}

#Preview("Drawer") {
    @Previewable @State var isOpen = false
    DrawerContainer(isOpen: $isOpen) {
        List(["Chats", "Projects", "Artifacts"], id: \.self) { Text($0) }
    } content: {
        Button("Toggle") { withAnimation(Motion.drawer) { isOpen.toggle() } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedBackground()
    }
}

/// The content as a card while the drawer shows (CHATS-01): dimmed, rounded, a hairline edge in
/// dark mode, a shadow, and a tap to close. The layers exist while the drawer is present, i.e.
/// from before the slide starts (at zero progress, invisible) until after it ends: a layer
/// inserted mid-slide lands at the card's final position instead of moving with it. At rest
/// they're gone, since even clear, hidden layers are unlabelled screen-sized accessibility
/// elements (PLAT-06).
private struct DrawerCard: ViewModifier {
    let progress: CGFloat
    let isPresent: Bool
    let isOpen: Bool
    let edgeHighlight: Color
    let close: () -> Void

    /// About the iPhone display's corner radius, so the card's corners stay concentric with it.
    static var cornerRadius: CGFloat { 55 }
    /// How dark the content gets with the drawer fully open.
    static var maximumDim: Double { 0.35 }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresent {
                    Color.black
                        .opacity(DrawerCard.maximumDim * progress)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.identity)
                }
            }
            .overlay {
                // Tap the strip to close. Only while open: a tappable layer is an
                // (unlabelled, screen-sized) accessibility element even when it's clear
                // (PLAT-06). It draws nothing, so inserting it late can't leave an artifact.
                if isOpen {
                    Color.clear
                        .contentShape(.rect)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .accessibilityHidden(true)
                }
            }
            // While it's displaced the content is a card whose corners match the display's
            // (at rest they coincide with the screen's, so there's no clip then).
            .clipShape(.rect(cornerRadius: progress > 0 ? DrawerCard.cornerRadius : 0, style: .continuous))
            .overlay {
                if isPresent {
                    RoundedRectangle(cornerRadius: DrawerCard.cornerRadius, style: .continuous)
                        .strokeBorder(edgeHighlight.opacity(min(progress * 3, 1)), lineWidth: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.identity)
                }
            }
            // The shadow belongs to a plain shape behind the content: shadowing the
            // content itself re-renders the whole screen offscreen on every frame. It has
            // the drawer's colour, so its antialiased edge blends with the drawer.
            .background {
                if isPresent {
                    RoundedRectangle(cornerRadius: DrawerCard.cornerRadius, style: .continuous)
                        .fill(Palette.recessedSurface.color)
                        .shadow(color: .black.opacity(0.12 * progress), radius: 18)
                        .accessibilityHidden(true)
                        .transition(.identity)
                }
            }
    }
}

/// Set by the drawer's content to take the whole screen (the drawer search, #172): the card
/// slides fully aside and the drag stays off until it's done.
struct DrawerExpandedPreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
