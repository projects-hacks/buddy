//
//  TeacherAnnotationLayer.swift
//  leanring-buddy
//
//  Draws the tutor's marks over the screen: circles, boxes, underlines,
//  highlights, strikethroughs, arrows, numbered steps, callouts and spotlight.
//
//  Why marks are animated rather than simply placed: a mark that fades in whole
//  reads as an overlay, while a stroke that travels reads as someone drawing it.
//  The eye follows a moving line, which is exactly the attention transfer this
//  is for. The strokes also overshoot slightly, the way a hand does, because
//  geometrically perfect ink looks like a diagram rather than a teacher.
//

import SwiftUI

/// A resolved mark, already mapped to exact screen rectangles.
struct TeacherAnnotation: Identifiable {
    enum Style {
        case circle
        case box
        case underline
        case highlight
        case strikethrough
        case arrow(destinationRectInGlobalPoints: CGRect)
        case step(number: Int)
        case callout(text: String)
    }

    let id = UUID()
    let style: Style

    /// Target rectangle in global AppKit points, bottom-left origin.
    let rectInGlobalPoints: CGRect

    /// Frame of the display this mark belongs to, for filtering per overlay.
    let displayFrame: CGRect
}

/// Palette for the marks.
///
/// Deliberately not the cursor's blue: the cursor says "look here", a mark says
/// "this thing means something", and they should not be confused for each other.
private enum AnnotationPalette {
    static let primaryInk = Color(red: 1.0, green: 0.42, blue: 0.31)
    static let supportingInk = Color(red: 0.36, green: 0.78, blue: 0.99)
    static let highlightWash = Color(red: 1.0, green: 0.85, blue: 0.24)
    static let errorInk = Color(red: 1.0, green: 0.33, blue: 0.36)
}

/// Renders every mark belonging to one display.
struct TeacherAnnotationLayer: View {
    let annotations: [TeacherAnnotation]

    /// Targets to keep lit while everything else dims. Empty disables spotlight.
    let spotlightRectsInGlobalPoints: [CGRect]

    /// This overlay window's screen, in global AppKit points.
    let screenFrame: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !spotlightRectsInGlobalPoints.isEmpty {
                SpotlightScrim(
                    litRectsInViewSpace: spotlightRectsInGlobalPoints.map(convertToViewSpace),
                    screenSize: screenFrame.size
                )
                .transition(.opacity)
            }

            ForEach(annotationsOnThisScreen) { annotation in
                AnnotationMarkView(
                    annotation: annotation,
                    rectInViewSpace: convertToViewSpace(annotation.rectInGlobalPoints),
                    destinationRectInViewSpace: destinationRectInViewSpace(for: annotation)
                )
            }
            .onChange(of: annotations.count) { _, newCount in
                // onAppear fires once, so it reported the count at first render
                // and never again, which made a layer holding five marks look
                // like it held one.
                TutorDebugLog.write("🖍️ overlay \(Int(screenFrame.width))x\(Int(screenFrame.height)) now drawing \(annotationsOnThisScreen.count) of \(newCount) mark(s)")
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Marks belonging to this overlay's display.
    ///
    /// Decided by whether this screen geometrically contains the mark, not by
    /// comparing display frames for equality. The capture layer derives its
    /// frame from `NSScreen` but falls back to `SCDisplay.frame` when the
    /// lookup misses, and those use different origins, so an equality test can
    /// silently match nothing and draw an empty overlay. Containment is both
    /// robust to that and the thing actually being asked.
    private var annotationsOnThisScreen: [TeacherAnnotation] {
        annotations.filter { annotation in
            screenFrame.contains(centerPoint(of: annotation.rectInGlobalPoints))
                || screenFrame.intersects(annotation.rectInGlobalPoints)
        }
    }

    private func centerPoint(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private func destinationRectInViewSpace(for annotation: TeacherAnnotation) -> CGRect? {
        guard case let .arrow(destinationRect) = annotation.style else { return nil }
        return convertToViewSpace(destinationRect)
    }

    /// Converts a global AppKit rectangle, bottom-left origin, into this
    /// overlay's SwiftUI coordinates, which are top-left origin and
    /// relative to the window rather than the desktop.
    private func convertToViewSpace(_ globalRect: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - screenFrame.minX,
            y: screenFrame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
    }
}

// MARK: - Individual marks

private struct AnnotationMarkView: View {
    let annotation: TeacherAnnotation
    let rectInViewSpace: CGRect
    let destinationRectInViewSpace: CGRect?

    /// Drives the stroke travelling along its path.
    @State private var strokeProgress: CGFloat = 0
    @State private var markOpacity: Double = 0

    private var drawDuration: Double {
        switch annotation.style {
        case .arrow: return 0.55
        case .circle, .box: return 0.45
        case .underline, .strikethrough: return 0.3
        default: return 0.25
        }
    }

    var body: some View {
        markContent
            .opacity(markOpacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.18)) { markOpacity = 1 }
                withAnimation(.easeInOut(duration: drawDuration)) { strokeProgress = 1 }
            }
            .onDisappear {
                strokeProgress = 0
                markOpacity = 0
            }
    }

    @ViewBuilder
    private var markContent: some View {
        switch annotation.style {
        case .circle:
            HandDrawnEllipse()
                .trim(from: 0, to: strokeProgress)
                .stroke(
                    AnnotationPalette.primaryInk,
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
                )
                .frame(width: paddedRect.width, height: paddedRect.height)
                .position(x: paddedRect.midX, y: paddedRect.midY)
                .shadow(color: AnnotationPalette.primaryInk.opacity(0.45), radius: 6)

        case .box:
            RoundedRectangle(cornerRadius: 6)
                .trim(from: 0, to: strokeProgress)
                .stroke(
                    AnnotationPalette.supportingInk,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
                .frame(width: paddedRect.width, height: paddedRect.height)
                .position(x: paddedRect.midX, y: paddedRect.midY)
                .shadow(color: AnnotationPalette.supportingInk.opacity(0.4), radius: 5)

        case .underline:
            // Sits just below the glyph baseline rather than on it, so the
            // stroke never obscures descenders in the text it marks.
            StraightStroke()
                .trim(from: 0, to: strokeProgress)
                .stroke(
                    AnnotationPalette.primaryInk,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: rectInViewSpace.width, height: 1)
                .position(x: rectInViewSpace.midX, y: rectInViewSpace.maxY + 4)
                .shadow(color: AnnotationPalette.primaryInk.opacity(0.4), radius: 4)

        case .highlight:
            // Multiply blending keeps the underlying text readable through the
            // wash, which a plain opaque fill would not.
            RoundedRectangle(cornerRadius: 3)
                .fill(AnnotationPalette.highlightWash.opacity(0.38))
                .frame(width: rectInViewSpace.width * strokeProgress, height: rectInViewSpace.height + 4)
                .position(
                    x: rectInViewSpace.minX + (rectInViewSpace.width * strokeProgress) / 2,
                    y: rectInViewSpace.midY
                )
                .blendMode(.multiply)

        case .strikethrough:
            StraightStroke()
                .trim(from: 0, to: strokeProgress)
                .stroke(
                    AnnotationPalette.errorInk,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .frame(width: rectInViewSpace.width, height: 1)
                .position(x: rectInViewSpace.midX, y: rectInViewSpace.midY)

        case .arrow:
            if let destinationRectInViewSpace {
                CurvedArrow(
                    startRect: rectInViewSpace,
                    endRect: destinationRectInViewSpace
                )
                .trim(from: 0, to: strokeProgress)
                .stroke(
                    AnnotationPalette.supportingInk,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: AnnotationPalette.supportingInk.opacity(0.45), radius: 5)
            }

        case .step(let number):
            StepBadge(number: number)
                .position(x: rectInViewSpace.minX - 16, y: rectInViewSpace.midY)
                .scaleEffect(strokeProgress)

        case .callout(let text):
            CalloutBubble(text: text)
                .position(x: rectInViewSpace.midX, y: rectInViewSpace.minY - 22)
                .scaleEffect(strokeProgress, anchor: .bottom)
        }
    }

    /// Breathing room so a circle encloses its target instead of cutting it.
    private var paddedRect: CGRect {
        rectInViewSpace.insetBy(dx: -10, dy: -8)
    }
}

// MARK: - Shapes

/// An ellipse that starts and ends past the same point, the way a hand does
/// when circling something without lifting the pen.
private struct HandDrawnEllipse: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centerPoint = CGPoint(x: rect.midX, y: rect.midY)
        let horizontalRadius = rect.width / 2
        let verticalRadius = rect.height / 2

        // Begin slightly before the top and continue slightly past a full turn
        // so the stroke overlaps itself, which is what makes it read as drawn.
        let startAngle = -Double.pi / 2 - 0.25
        let endAngle = startAngle + (2 * Double.pi) + 0.45
        let segmentCount = 72

        for segmentIndex in 0...segmentCount {
            let progress = Double(segmentIndex) / Double(segmentCount)
            let angle = startAngle + (endAngle - startAngle) * progress

            // A gentle wobble keeps the line from looking machine-made.
            let wobble = 1.0 + 0.02 * sin(progress * 7 * Double.pi)

            let point = CGPoint(
                x: centerPoint.x + CGFloat(cos(angle) * wobble) * horizontalRadius,
                y: centerPoint.y + CGFloat(sin(angle) * wobble) * verticalRadius
            )

            if segmentIndex == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        return path
    }
}

/// A single horizontal stroke, trimmed left to right.
private struct StraightStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// A curved arrow between two rectangles, with a head at the destination.
private struct CurvedArrow: Shape {
    let startRect: CGRect
    let endRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let startPoint = CGPoint(x: startRect.midX, y: startRect.midY)
        let endPoint = CGPoint(x: endRect.midX, y: endRect.midY)

        // Bow the line perpendicular to its own direction, so the arc bends
        // away from whatever sits between the two targets rather than through it.
        let deltaX = endPoint.x - startPoint.x
        let deltaY = endPoint.y - startPoint.y
        let distance = max(1, sqrt(deltaX * deltaX + deltaY * deltaY))
        let bowAmount = min(distance * 0.22, 90)

        let midPoint = CGPoint(
            x: (startPoint.x + endPoint.x) / 2,
            y: (startPoint.y + endPoint.y) / 2
        )
        let controlPoint = CGPoint(
            x: midPoint.x + (-deltaY / distance) * bowAmount,
            y: midPoint.y + (deltaX / distance) * bowAmount
        )

        path.move(to: startPoint)
        path.addQuadCurve(to: endPoint, control: controlPoint)

        // Head is aligned to the tangent at the destination, which for a
        // quadratic curve points from the control point to the end point.
        let tangentX = endPoint.x - controlPoint.x
        let tangentY = endPoint.y - controlPoint.y
        let tangentLength = max(1, sqrt(tangentX * tangentX + tangentY * tangentY))
        let headAngle = atan2(tangentY / tangentLength, tangentX / tangentLength)

        let headLength: CGFloat = 14
        let headSpread = Double.pi / 7

        path.move(to: endPoint)
        path.addLine(to: CGPoint(
            x: endPoint.x - headLength * CGFloat(cos(headAngle - headSpread)),
            y: endPoint.y - headLength * CGFloat(sin(headAngle - headSpread))
        ))
        path.move(to: endPoint)
        path.addLine(to: CGPoint(
            x: endPoint.x - headLength * CGFloat(cos(headAngle + headSpread)),
            y: endPoint.y - headLength * CGFloat(sin(headAngle + headSpread))
        ))

        return path
    }
}

// MARK: - Badges and callouts

private struct StepBadge: View {
    let number: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(AnnotationPalette.primaryInk)
                .frame(width: 24, height: 24)
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
    }
}

private struct CalloutBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.82))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AnnotationPalette.primaryInk.opacity(0.7), lineWidth: 1)
                    )
            )
            .fixedSize()
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
    }
}

// MARK: - Spotlight

/// Dims the whole screen except the lit rectangles.
///
/// The most effective mark available on a dense screen, because it works by
/// removing competing detail instead of adding more ink on top of it.
private struct SpotlightScrim: View {
    let litRectsInViewSpace: [CGRect]
    let screenSize: CGSize

    @State private var scrimOpacity: Double = 0

    var body: some View {
        Canvas { context, size in
            var scrimPath = Path(CGRect(origin: .zero, size: size))

            // Punching the lit areas out of the same path and filling with the
            // even-odd rule leaves real holes, rather than painting lighter
            // rectangles on top of a dark layer.
            for litRect in litRectsInViewSpace {
                scrimPath.addPath(
                    Path(roundedRect: litRect.insetBy(dx: -8, dy: -6), cornerRadius: 8)
                )
            }

            context.fill(scrimPath, with: .color(.black.opacity(0.58)), style: FillStyle(eoFill: true))

            for litRect in litRectsInViewSpace {
                context.stroke(
                    Path(roundedRect: litRect.insetBy(dx: -8, dy: -6), cornerRadius: 8),
                    with: .color(AnnotationPalette.highlightWash.opacity(0.65)),
                    lineWidth: 1.5
                )
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .opacity(scrimOpacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { scrimOpacity = 1 }
        }
    }
}
