//
//  ErrorGlow.swift
//  leanring-buddy
//
//  The error offer's halo (ErrorOffer.swift decides when it shows): a soft
//  red glow under the notch's black shape, in a click-through window just
//  below the notch's own. The notch itself carries the words ("An error on
//  screen." and "hover to explain"), so this file only draws.
//

import AppKit
import Combine
import SwiftUI

/// One small window at the top of the notch screen: a soft halo behind the
/// notch that takes no clicks. The notch's own window sits above it, so the
/// halo seems to come from under the black shape.
@MainActor
final class ErrorGlowWindows {
    private var haloPanel: NSPanel?
    private let appearance = ErrorGlowAppearance()
    private var shapeSize: () -> CGSize = { .zero }
    private var isNotchOpen: () -> Bool = { false }
    /// Runs only while the glow shows, so the halo follows the notch when
    /// it grows, and steps back while the notch is open on the card.
    private var followNotchTimer: Timer?

    private static let haloMargin: CGFloat = 40

    private static var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// The camera housing's size when the notch has not reported its shape.
    private static func housingSize(of screen: NSScreen) -> CGSize {
        let height = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return CGSize(width: 180, height: height)
        }
        return CGSize(width: max(120, right.minX - left.maxX), height: height)
    }

    func show(shapeSize: @escaping () -> CGSize, isNotchOpen: @escaping () -> Bool) {
        self.shapeSize = shapeSize
        self.isNotchOpen = isNotchOpen
        if haloPanel == nil { haloPanel = makePanel(content: AnyView(ErrorGlowHalo(appearance: appearance))) }
        place()
        haloPanel?.orderFrontRegardless()
        // Fades in over 0.4s; with Reduce Motion it is simply there.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { appearance.isVisible = true }
        followNotchTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.place() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followNotchTimer = timer
    }

    func hide() {
        followNotchTimer?.invalidate()
        followNotchTimer = nil
        withAnimation(.easeIn(duration: 0.6)) { appearance.isVisible = false }
        // Taken off screen once faded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self, !self.appearance.isVisible else { return }
            self.haloPanel?.orderOut(nil)
        }
    }

    private func place() {
        guard let screen = Self.notchScreen else { return }
        let reported = shapeSize()
        let shape = reported.width > 0 && reported.height > 0 ? reported : Self.housingSize(of: screen)
        appearance.shapeSize = shape
        let notchIsOpen = isNotchOpen()
        if appearance.isNotchOpen != notchIsOpen {
            withAnimation(.easeOut(duration: 0.2)) { appearance.isNotchOpen = notchIsOpen }
        }
        let haloSize = CGSize(width: shape.width + Self.haloMargin * 2, height: shape.height + Self.haloMargin)
        haloPanel?.setFrame(NSRect(x: screen.frame.midX - haloSize.width / 2, y: screen.frame.maxY - haloSize.height,
                                   width: haloSize.width, height: haloSize.height), display: true)
    }

    private func makePanel(content: AnyView) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: CGSize(width: 300, height: 80)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Just under the notch, which is one above .screenSaver, so the
        // black shape covers the centre of the halo.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        return panel
    }
}

@MainActor
final class ErrorGlowAppearance: ObservableObject {
    @Published var isVisible = false
    @Published var isNotchOpen = false
    @Published var shapeSize: CGSize = .zero
}

/// A soft red halo under the shape, at 45%, with a thin brighter edge that
/// shows just outside its bottom. Red so it reads as something gone wrong,
/// but a halo and never a dot, so it is not mistaken for listening. It does
/// not pulse: a still glow is enough to be noticed and does not nag.
struct ErrorGlowHalo: View {
    @ObservedObject var appearance: ErrorGlowAppearance

    /// The closed notch's concave shoulders, 7 points each side, are part of
    /// its laid-out width; the body the glow follows is inside them.
    private static let closedShoulderWidth: CGFloat = 7

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 13, bottomTrailingRadius: 13)
        let bodyWidth = max(0, appearance.shapeSize.width - 2 * Self.closedShoulderWidth)
        ZStack(alignment: .top) {
            shape
                .fill(DS.Notch.errorGlow.opacity(0.45))
                .frame(width: bodyWidth + 10, height: appearance.shapeSize.height + 6)
                .blur(radius: 14)
            // Centred on the body's own edge, so half of it peeks out from
            // under the black: a fine line along the bottom.
            shape
                .stroke(DS.Notch.errorGlowEdge, lineWidth: 1.5)
                .frame(width: bodyWidth + 0.75, height: appearance.shapeSize.height + 0.75)
                .blur(radius: 0.8)
                .opacity(0.9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(appearance.isVisible && !appearance.isNotchOpen ? 1 : 0)
        .allowsHitTesting(false)
    }
}
