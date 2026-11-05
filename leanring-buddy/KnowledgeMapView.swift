//
//  KnowledgeMapView.swift
//  leanring-buddy
//
//  The map of what the student knows, as drawn in its window
//  (KnowledgeMapWindow.swift): every remembered idea a dot, related ideas
//  joined, clusters tinted by topic, and ideas being forgotten fading out
//  with "review soon" under their names. Hover shows how an idea was last
//  explained; a click opens it, with Re-teach this and Forget this idea.
//
//  Drawn in one Canvas rather than a view per idea, so 300 ideas pan and
//  zoom as smoothly as 5. Names are drawn at a fixed size on screen and
//  shown in order of importance until there is no room for the next, so the
//  map stays readable at any zoom instead of turning into overprinted text.
//

import AppKit
import Combine
import SwiftUI

// MARK: - The model

@MainActor
final class KnowledgeMapModel: ObservableObject {
    @Published private(set) var layout: KnowledgeMapLayout = .empty
    /// False until the first layout arrives, so the empty state is not
    /// flashed at a student whose map is still being laid out.
    @Published private(set) var hasLoaded = false
    @Published var isMemoryEnabled = true
    /// The one-time pass that links older ideas is running.
    @Published var isFindingRelations = false
    @Published var hoveredID: UUID?
    @Published var selectedID: UUID?
    @Published var searchText = ""
    /// Map points to screen points.
    @Published var zoom: CGFloat = 1
    /// Where the map's origin is drawn, relative to the middle of the view.
    @Published var panOffset: CGSize = .zero
    @Published private(set) var isAnimating = false

    var onReteach: (RememberedConcept) -> Void = { _ in }
    var onForget: (RememberedConcept) -> Void = { _ in }

    /// Set by the view as it is laid out, and by scripts that render it.
    var viewSize: CGSize = .zero
    private var needsFitWhenSized = true
    /// Until the student pans or zooms, resizing the window keeps the whole
    /// map in view; after, it leaves their view alone.
    private var hasStudentMovedCamera = false

    static let minimumZoom: CGFloat = 0.1
    static let maximumZoom: CGFloat = 2.5
    /// A map of five ideas fitted to the window would draw them huge.
    static let maximumFittedZoom: CGFloat = 1.15

    // Movement between layouts, and ideas arriving, animate.
    private var previousPositions: [UUID: CGPoint] = [:]
    private var appearingIDs: Set<UUID> = []
    private var transitionStartedAt: Date = .distantPast
    static let transitionSeconds: TimeInterval = 0.75

    // The camera glides to an idea picked from search or a link.
    private var cameraFrom: (pan: CGSize, zoom: CGFloat)?
    private var cameraTo: (pan: CGSize, zoom: CGFloat)?
    private var cameraStartedAt: Date = .distantPast
    static let cameraSeconds: TimeInterval = 0.45

    private var nodeIndexByID: [UUID: Int] = [:]

    func node(id: UUID?) -> KnowledgeMapNode? {
        guard let id, let index = nodeIndexByID[id] else { return nil }
        return layout.nodes[index]
    }

    var selectedNode: KnowledgeMapNode? { node(id: selectedID) }
    var hoveredNode: KnowledgeMapNode? { node(id: hoveredID) }

    var reviewSoonCount: Int { layout.nodes.filter { $0.strength.needsReview }.count }

    /// Shows a new layout. Ideas in `appearingIDs` grow in from the idea they
    /// are linked to; every other idea glides from where it was drawn.
    func apply(_ newLayout: KnowledgeMapLayout, appearingIDs newAppearingIDs: Set<UUID>, animated: Bool, now: Date = Date()) {
        let wasEmpty = layout.nodes.isEmpty
        var drawnPositions: [UUID: CGPoint] = [:]
        if animated {
            for node in layout.nodes { drawnPositions[node.id] = displayPosition(of: node, at: now) }
        }
        layout = newLayout
        nodeIndexByID = Dictionary(uniqueKeysWithValues: newLayout.nodes.enumerated().map { ($0.element.id, $0.offset) })
        hasLoaded = true
        if let selectedID, nodeIndexByID[selectedID] == nil { self.selectedID = nil }
        if let hoveredID, nodeIndexByID[hoveredID] == nil { self.hoveredID = nil }

        guard animated else {
            previousPositions = [:]
            appearingIDs = []
            transitionStartedAt = .distantPast
            if wasEmpty || needsFitWhenSized { fitToContent() }
            return
        }
        // A new idea starts at the idea it is linked to, so it visibly comes
        // out of what it builds on; with no link, it grows where it lands.
        for id in newAppearingIDs where drawnPositions[id] == nil {
            let linkedID = newLayout.edges.first { $0.fromID == id || $0.toID == id }
                .map { $0.fromID == id ? $0.toID : $0.fromID }
            if let linkedID, let linkedPosition = drawnPositions[linkedID] ?? node(id: linkedID)?.position {
                drawnPositions[id] = linkedPosition
            }
        }
        previousPositions = drawnPositions
        appearingIDs = newAppearingIDs
        transitionStartedAt = now
        if wasEmpty || needsFitWhenSized { fitToContent() }
        startAnimating(for: Self.transitionSeconds)
    }

    private func transitionProgress(at date: Date) -> CGFloat {
        let elapsed = date.timeIntervalSince(transitionStartedAt)
        guard elapsed < Self.transitionSeconds else { return 1 }
        let linear = CGFloat(max(0, elapsed / Self.transitionSeconds))
        return 1 - pow(1 - linear, 3)
    }

    func displayPosition(of node: KnowledgeMapNode, at date: Date) -> CGPoint {
        let progress = transitionProgress(at: date)
        guard progress < 1, let from = previousPositions[node.id] else { return node.position }
        return CGPoint(x: from.x + (node.position.x - from.x) * progress,
                       y: from.y + (node.position.y - from.y) * progress)
    }

    /// 0 to 1 while an idea arrives, with a small overshoot, then 1.
    func appearance(of node: KnowledgeMapNode, at date: Date) -> CGFloat {
        guard appearingIDs.contains(node.id) else { return 1 }
        let elapsed = date.timeIntervalSince(transitionStartedAt)
        guard elapsed < Self.transitionSeconds else { return 1 }
        let linear = CGFloat(max(0, elapsed / Self.transitionSeconds))
        // easeOutBack: grows a touch past full size and settles.
        let overshoot: CGFloat = 1.70158
        let shifted = linear - 1
        return 1 + (overshoot + 1) * pow(shifted, 3) + overshoot * pow(shifted, 2)
    }

    private func startAnimating(for seconds: TimeInterval) {
        isAnimating = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.05) * 1_000_000_000))
            guard let self else { return }
            let now = Date()
            let transitionDone = now.timeIntervalSince(self.transitionStartedAt) >= Self.transitionSeconds
            let cameraDone = now.timeIntervalSince(self.cameraStartedAt) >= Self.cameraSeconds
            if transitionDone && cameraDone { self.isAnimating = false }
        }
    }

    // MARK: Camera

    func camera(at date: Date) -> (pan: CGSize, zoom: CGFloat) {
        guard let cameraFrom, let cameraTo else { return (panOffset, zoom) }
        let elapsed = date.timeIntervalSince(cameraStartedAt)
        guard elapsed < Self.cameraSeconds else { return (panOffset, zoom) }
        let linear = CGFloat(max(0, elapsed / Self.cameraSeconds))
        let progress = linear < 0.5 ? 4 * pow(linear, 3) : 1 - pow(-2 * linear + 2, 3) / 2
        return (CGSize(width: cameraFrom.pan.width + (cameraTo.pan.width - cameraFrom.pan.width) * progress,
                       height: cameraFrom.pan.height + (cameraTo.pan.height - cameraFrom.pan.height) * progress),
                cameraFrom.zoom + (cameraTo.zoom - cameraFrom.zoom) * progress)
    }

    private func moveCamera(toPan targetPan: CGSize, zoom targetZoom: CGFloat, animated: Bool) {
        if animated {
            cameraFrom = camera(at: Date())
            cameraTo = (targetPan, targetZoom)
            cameraStartedAt = Date()
            startAnimating(for: Self.cameraSeconds)
        } else {
            cameraFrom = nil
            cameraTo = nil
        }
        panOffset = targetPan
        zoom = targetZoom
    }

    /// A drag or pinch takes over from a glide that is still going.
    func stopCameraGlide() {
        cameraFrom = nil
        cameraTo = nil
        hasStudentMovedCamera = true
    }

    func viewSizeChanged(to size: CGSize) {
        let wasUnsized = viewSize == .zero
        viewSize = size
        if wasUnsized || needsFitWhenSized || !hasStudentMovedCamera { fitToContent() }
    }

    /// The whole map in view, centred, no bigger than comfortable.
    func fitToContent(animated: Bool = false) {
        guard viewSize.width > 0, viewSize.height > 0 else {
            needsFitWhenSized = true
            return
        }
        needsFitWhenSized = false
        hasStudentMovedCamera = false
        let bounds = layout.bounds
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            moveCamera(toPan: .zero, zoom: 1, animated: animated)
            return
        }
        let padding: CGFloat = 60
        let fittedZoom = min((viewSize.width - 2 * padding) / bounds.width,
                             (viewSize.height - 2 * padding) / bounds.height)
        let targetZoom = min(Self.maximumFittedZoom, max(Self.minimumZoom, fittedZoom))
        moveCamera(toPan: CGSize(width: -bounds.midX * targetZoom, height: -bounds.midY * targetZoom),
                   zoom: targetZoom, animated: animated)
    }

    func zoom(by factor: CGFloat, around screenPoint: CGPoint? = nil) {
        stopCameraGlide()
        let anchor = screenPoint ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let newZoom = min(Self.maximumZoom, max(Self.minimumZoom, zoom * factor))
        // Keep the map point under the anchor where it is.
        let mapPoint = mapPoint(forScreenPoint: anchor)
        zoom = newZoom
        panOffset = CGSize(width: anchor.x - viewSize.width / 2 - mapPoint.x * newZoom,
                           height: anchor.y - viewSize.height / 2 - mapPoint.y * newZoom)
    }

    func pan(by translation: CGSize) {
        stopCameraGlide()
        panOffset = CGSize(width: panOffset.width + translation.width, height: panOffset.height + translation.height)
    }

    /// Brings an idea to the middle, close enough to read its neighbours.
    func focus(on id: UUID, select: Bool = true) {
        guard let node = node(id: id) else { return }
        if select { selectedID = id }
        hasStudentMovedCamera = true
        let targetZoom = max(zoom, 1.0)
        moveCamera(toPan: CGSize(width: -node.position.x * targetZoom, height: -node.position.y * targetZoom),
                   zoom: targetZoom, animated: true)
    }

    func screenPoint(forMapPoint mapPoint: CGPoint, camera: (pan: CGSize, zoom: CGFloat)? = nil) -> CGPoint {
        let current = camera ?? (panOffset, zoom)
        return CGPoint(x: viewSize.width / 2 + current.pan.width + mapPoint.x * current.zoom,
                       y: viewSize.height / 2 + current.pan.height + mapPoint.y * current.zoom)
    }

    func mapPoint(forScreenPoint screenPoint: CGPoint) -> CGPoint {
        CGPoint(x: (screenPoint.x - viewSize.width / 2 - panOffset.width) / zoom,
                y: (screenPoint.y - viewSize.height / 2 - panOffset.height) / zoom)
    }

    /// The idea under a point of the view, if any, with a little slack so
    /// small dots are easy to hit.
    func nodeID(atScreenPoint screenPoint: CGPoint) -> UUID? {
        var nearest: (id: UUID, distance: CGFloat)?
        for node in layout.nodes {
            let centre = self.screenPoint(forMapPoint: node.position)
            let distance = hypot(centre.x - screenPoint.x, centre.y - screenPoint.y)
            let reach = max(node.radius * zoom, 9) + 5
            if distance <= reach, distance < (nearest?.distance ?? .infinity) {
                nearest = (node.id, distance)
            }
        }
        return nearest?.id
    }

    // MARK: Search

    /// Ideas whose name or another name contains what is typed, best first:
    /// names that start with it, then the rest.
    var searchMatches: [KnowledgeMapNode] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        let matching = layout.nodes.filter { node in
            node.concept.name.lowercased().contains(query)
                || node.concept.aliases.contains { $0.lowercased().contains(query) }
        }
        return matching.sorted { first, second in
            let firstStarts = first.concept.name.lowercased().hasPrefix(query)
            let secondStarts = second.concept.name.lowercased().hasPrefix(query)
            if firstStarts != secondStarts { return firstStarts }
            return first.concept.name < second.concept.name
        }
    }

    var searchMatchIDs: Set<UUID>? {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Set(searchMatches.map(\.id))
    }
}

// MARK: - Colours

/// The map's own colours, in a light and a dark set. The light set is the
/// cream squared paper of Buddy's lesson cards; the dark set keeps the same
/// hues, deeper, so a topic is the same colour in both.
struct KnowledgeMapColors {
    let colorScheme: ColorScheme
    private var isDark: Bool { colorScheme == .dark }

    var background: Color { isDark ? Color(hex: "#17181A") : Color(hex: "#F7F3E8") }
    var paperDots: Color { isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.075) }
    var ink: Color { isDark ? Color(hex: "#ECEAE4") : Color(hex: "#24211C") }
    var secondaryInk: Color { isDark ? Color(hex: "#A39E95") : Color(hex: "#6E685E") }
    var faintInk: Color { isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.16) }
    var reviewSoon: Color { isDark ? Color(hex: "#F2A35E") : Color(hex: "#B4541A") }
    var card: Color { isDark ? Color(hex: "#232427") : Color(hex: "#FFFDF7") }
    var cardBorder: Color { isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1) }
    var field: Color { isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05) }
    var accent: Color { DS.Colors.accent }
    var destructive: Color { DS.Colors.destructive }

    private static let lightStrokes = ["#2D6BD8", "#6E4BC7", "#138A80", "#D2691E", "#C23F7E", "#3E8E32", "#A87A00", "#C4383F"]
    private static let lightFills = ["#D8E6FB", "#E6DDF9", "#D2F0EC", "#FBE3CF", "#F8DCEA", "#DDF0D6", "#F7EBC4", "#F9D9D8"]
    private static let darkStrokes = ["#7FB0FF", "#B39BFF", "#5FD3C6", "#FFAE6B", "#FF8EC2", "#8FD67F", "#F2C94C", "#FF7F7A"]
    private static let darkFills = ["#2C4F86", "#4A3B80", "#1F5A54", "#6B4324", "#6A3150", "#335C2B", "#62511C", "#6E2A2A"]

    func stroke(_ colorIndex: Int?) -> Color {
        guard let colorIndex else { return isDark ? Color(hex: "#ABA69C") : Color(hex: "#6B665F") }
        return Color(hex: (isDark ? Self.darkStrokes : Self.lightStrokes)[colorIndex % Self.lightStrokes.count])
    }

    func fill(_ colorIndex: Int?) -> Color {
        guard let colorIndex else { return isDark ? Color(hex: "#2E2D2A") : Color(hex: "#ECE6D8") }
        return Color(hex: (isDark ? Self.darkFills : Self.lightFills)[colorIndex % Self.lightFills.count])
    }
}

// MARK: - The window's content

struct KnowledgeMapView: View {
    @ObservedObject var model: KnowledgeMapModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSearchFocused: Bool
    @State private var dragStartPan: CGSize?
    @State private var pinchStartZoom: CGFloat?
    @State private var isConfirmingForget = false

    private var colors: KnowledgeMapColors { KnowledgeMapColors(colorScheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if !model.isMemoryEnabled {
                    emptyState(title: "Learning memory is off",
                               message: "Turn on Learning memory in Buddy's settings, and the ideas from each lesson will start to appear here as a map.")
                } else if model.hasLoaded && model.layout.nodes.isEmpty {
                    emptyState(title: "Nothing on your map yet",
                               message: "Every time Buddy explains something, the ideas it taught land here as dots, joined to the ideas they build on. Ideas you have not come back to in a while fade, so you can see what to review.\n\nHold Control + Option and ask about anything on your screen to add the first one.")
                } else {
                    mapCanvas
                    overlays
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(colors.background)
        .alert(forgetAlertTitle, isPresented: $isConfirmingForget) {
            Button("Forget", role: .destructive) {
                if let concept = model.selectedNode?.concept { model.onForget(concept) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Buddy will stop building on it and stop reminding you of it. This cannot be undone.")
        }
    }

    private var forgetAlertTitle: String {
        "Forget \u{201C}\(model.selectedNode?.concept.name ?? "this idea")\u{201D}?"
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("What you know")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(colors.ink)
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.secondaryInk)
            }
            Spacer(minLength: 12)
            if !model.layout.nodes.isEmpty { searchField }
        }
        // Clear of the window's close button, which sits over the content.
        .padding(.leading, 84)
        .padding(.trailing, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(colors.background)
        .overlay(alignment: .bottom) { Rectangle().fill(colors.cardBorder).frame(height: 1) }
    }

    private var headerSubtitle: String {
        let count = model.layout.nodes.count
        guard count > 0 else { return "Ideas Buddy has taught you, on this Mac only" }
        let ideas = count == 1 ? "1 idea" : "\(count) ideas"
        let review = model.reviewSoonCount
        let reviewPart = review == 0 ? "all fresh" : "\(review) to review soon"
        let findingPart = model.isFindingRelations ? " \u{00B7} linking older ideas\u{2026}" : ""
        return "\(ideas) \u{00B7} \(reviewPart)\(findingPart)"
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colors.secondaryInk)
            TextField("Search ideas", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(colors.ink)
                .focused($isSearchFocused)
                .onSubmit {
                    if let first = model.searchMatches.first { model.focus(on: first.id) }
                }
                .onExitCommand { model.searchText = "" }
            if !model.searchText.isEmpty {
                Text(model.searchMatches.count == 1 ? "1 idea" : "\(model.searchMatches.count) ideas")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(colors.secondaryInk)
                Button(action: { model.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.secondaryInk)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(colors.field))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(isSearchFocused ? colors.accent.opacity(0.6) : Color.clear, lineWidth: 1.5))
        .background {
            // Command F reaches the search however the window was opened.
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    // MARK: The map

    private var mapCanvas: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: nil, paused: !model.isAnimating)) { timeline in
                Canvas { context, size in
                    KnowledgeMapRenderer(model: model, colors: colors, date: timeline.date)
                        .draw(in: &context, size: size)
                }
            }
            .contentShape(Rectangle())
            .onAppear { model.viewSizeChanged(to: geometry.size) }
            .onChange(of: geometry.size) { _, newSize in model.viewSizeChanged(to: newSize) }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let hovered = model.nodeID(atScreenPoint: location)
                    if hovered != model.hoveredID { model.hoveredID = hovered }
                    // Ideas are drawn, not views, so the pointer is set here.
                    if hovered != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                case .ended:
                    model.hoveredID = nil
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if dragStartPan == nil {
                            model.stopCameraGlide()
                            dragStartPan = model.panOffset
                        }
                        if let dragStartPan {
                            model.panOffset = CGSize(width: dragStartPan.width + value.translation.width,
                                                     height: dragStartPan.height + value.translation.height)
                        }
                    }
                    .onEnded { _ in dragStartPan = nil }
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { value in
                            if pinchStartZoom == nil { pinchStartZoom = model.zoom }
                            if let pinchStartZoom {
                                model.zoom(by: pinchStartZoom * value.magnification / model.zoom, around: value.startLocation)
                            }
                        }
                        .onEnded { _ in pinchStartZoom = nil })
            )
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    isSearchFocused = false
                    model.selectedID = model.nodeID(atScreenPoint: value.location)
                }
            )
        }
    }

    // MARK: Overlays

    private var overlays: some View {
        ZStack {
            if let hovered = model.hoveredNode, hovered.id != model.selectedID {
                hoverCard(for: hovered)
            }
            VStack {
                if !model.searchMatches.isEmpty && isSearchFocused {
                    searchResults
                }
                Spacer()
                HStack(alignment: .bottom) {
                    legend
                    Spacer()
                    zoomControls
                }
            }
            .padding(16)
            if let selected = model.selectedNode {
                HStack {
                    Spacer()
                    detailCard(for: selected)
                        .frame(width: 300)
                        .padding(16)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.smooth(duration: 0.22), value: model.selectedID)
    }

    private var searchResults: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.searchMatches.prefix(8)) { node in
                    KnowledgeMapRowButton(colors: colors, action: {
                        isSearchFocused = false
                        model.focus(on: node.id)
                    }) {
                        HStack(spacing: 8) {
                            Circle().fill(colors.stroke(node.colorIndex)).frame(width: 8, height: 8)
                            Text(node.concept.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(colors.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if node.strength.needsReview {
                                Text("review soon")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(colors.reviewSoon)
                            }
                        }
                    }
                }
            }
            .padding(6)
            .frame(width: 260)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(colors.cardBorder))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
        .padding(.top, -8)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(opacity: 1, dashed: false, text: "Remembered")
            legendItem(opacity: 0.62, dashed: false, text: "Review soon")
            legendItem(opacity: 0.3, dashed: true, text: "Fading out")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(colors.card.opacity(0.92)))
        .overlay(Capsule().stroke(colors.cardBorder))
    }

    private func legendItem(opacity: Double, dashed: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(colors.fill(0).opacity(opacity))
                .overlay(Circle().stroke(colors.stroke(0).opacity(opacity),
                                         style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2.5] : [])))
                .frame(width: 11, height: 11)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(colors.secondaryInk)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            KnowledgeMapIconButton(systemImage: "minus", help: "Zoom out", colors: colors) {
                model.zoom(by: 1 / 1.25)
            }
            .keyboardShortcut("-", modifiers: .command)
            KnowledgeMapIconButton(systemImage: "arrow.up.left.and.down.right.magnifyingglass", help: "Show the whole map", colors: colors) {
                model.fitToContent(animated: true)
            }
            .keyboardShortcut("0", modifiers: .command)
            KnowledgeMapIconButton(systemImage: "plus", help: "Zoom in", colors: colors) {
                model.zoom(by: 1.25)
            }
            .keyboardShortcut("=", modifiers: .command)
        }
        .padding(3)
        .background(Capsule().fill(colors.card.opacity(0.92)))
        .overlay(Capsule().stroke(colors.cardBorder))
    }

    private func hoverCard(for node: KnowledgeMapNode) -> some View {
        let centre = model.screenPoint(forMapPoint: node.position)
        let cardWidth: CGFloat = 250
        // Beside the dot, on whichever side has room, and never under the
        // open idea's card on the right.
        let rightEdge = model.viewSize.width - (model.selectedID != nil ? 332 : 0)
        let placeOnRight = centre.x + cardWidth + 40 < rightEdge
        let x = placeOnRight ? centre.x + node.radius * model.zoom + 14 + cardWidth / 2
            : centre.x - node.radius * model.zoom - 14 - cardWidth / 2
        let y = min(max(centre.y, 70), max(70, model.viewSize.height - 70))
        return VStack(alignment: .leading, spacing: 5) {
            Text(node.concept.name)
                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                .foregroundStyle(colors.ink)
            if !node.concept.summary.isEmpty {
                Text(node.concept.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.ink.opacity(0.8))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("Learned \(KnowledgeMapDates.day(node.concept.firstExplainedAt))")
                if node.strength.needsReview {
                    Text("review soon").foregroundStyle(colors.reviewSoon).fontWeight(.semibold)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(colors.secondaryInk)
        }
        .padding(11)
        .frame(width: cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(colors.cardBorder))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        .position(x: x, y: y)
        .allowsHitTesting(false)
    }

    private func detailCard(for node: KnowledgeMapNode) -> some View {
        let concept = node.concept
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(colors.stroke(node.colorIndex)).frame(width: 10, height: 10).padding(.top, 6)
                Text(concept.name)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                KnowledgeMapIconButton(systemImage: "xmark", help: "Close", colors: colors) {
                    model.selectedID = nil
                }
            }
            strengthRow(for: node)
            if !concept.summary.isEmpty {
                Text(concept.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(colors.ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let angle = concept.lastAngle, !angle.isEmpty {
                Text("Last example: \(angle)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Learned \(KnowledgeMapDates.day(concept.firstExplainedAt)), last explained \(KnowledgeMapDates.relative(concept.lastExplainedAt))")
                Text(concept.timesExplained == 1 ? "Explained once" : "Explained \(concept.timesExplained) times")
                    + Text(concept.timesLost > 0 ? ", lost the thread \(concept.timesLost == 1 ? "once" : "\(concept.timesLost) times")" : "")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(colors.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)

            let links = linkedIdeas(of: node)
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LINKED IDEAS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(colors.secondaryInk)
                        .padding(.bottom, 2)
                    ForEach(links, id: \.node.id) { link in
                        KnowledgeMapRowButton(colors: colors, action: { model.focus(on: link.node.id) }) {
                            HStack(spacing: 6) {
                                Text(link.phrase)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(colors.secondaryInk)
                                Text(link.node.concept.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(colors.stroke(link.node.colorIndex))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }

            VStack(spacing: 8) {
                Button(action: { model.onReteach(concept) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .bold))
                        Text("Re-teach this")
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(KnowledgeMapPrimaryButtonStyle(colors: colors))
                .pointerCursor()
                .help("Buddy explains it again, out loud and drawn, with a different example from last time")

                Button(action: { isConfirmingForget = true }) {
                    Text("Forget this idea")
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KnowledgeMapQuietButtonStyle(colors: colors, tint: colors.destructive))
                .pointerCursor()
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(colors.card)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(colors.cardBorder))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 5)
    }

    private func strengthRow(for node: KnowledgeMapNode) -> some View {
        let percent = Int((node.retrievability * 100).rounded())
        let label: String
        let tint: Color
        switch node.strength {
        case .solid:
            label = "Remembered"
            tint = colors.stroke(5)
        case .fading:
            label = "Review soon"
            tint = colors.reviewSoon
        case .faded:
            label = "Review soon, fading out"
            tint = colors.reviewSoon
        }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
                Spacer()
                Text("about \(percent)% likely to recall")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(colors.secondaryInk)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(colors.field)
                    Capsule().fill(tint).frame(width: geometry.size.width * CGFloat(node.retrievability))
                }
            }
            .frame(height: 5)
        }
    }

    private struct LinkedIdea {
        let node: KnowledgeMapNode
        let phrase: String
    }

    /// Each link read from this idea's side: "uses event loop", or, for a
    /// link stored on the other idea, "used by" and the like.
    private func linkedIdeas(of node: KnowledgeMapNode) -> [LinkedIdea] {
        model.layout.edges.compactMap { edge -> LinkedIdea? in
            if edge.fromID == node.id, let other = model.node(id: edge.toID) {
                return LinkedIdea(node: other, phrase: edge.kind)
            }
            if edge.toID == node.id, let other = model.node(id: edge.fromID) {
                return LinkedIdea(node: other, phrase: Self.reversedPhrase(for: edge.kind))
            }
            return nil
        }
    }

    static func reversedPhrase(for kind: String) -> String {
        switch kind {
        case "uses": return "used by"
        case "part of": return "has part"
        case "prerequisite of": return "builds on"
        default: return kind
        }
    }

    // MARK: Empty state

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 16) {
            KnowledgeMapEmptyIllustration(colors: colors)
                .frame(width: 180, height: 110)
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(colors.ink)
            Text(message)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(colors.secondaryInk)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KnowledgeMapPaperDots(colors: colors))
    }
}

// MARK: - Drawing

/// Draws one frame of the map. A struct made per frame, so the drawing code
/// reads top to bottom: paper, topic tints, links, dots, names.
@MainActor
struct KnowledgeMapRenderer {
    let model: KnowledgeMapModel
    let colors: KnowledgeMapColors
    let date: Date

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let camera = model.camera(at: date)
        let zoom = camera.zoom
        func screen(_ mapPoint: CGPoint) -> CGPoint { model.screenPoint(forMapPoint: mapPoint, camera: camera) }

        drawPaper(in: &context, size: size, camera: camera)

        let searchMatchIDs = model.searchMatchIDs
        let focusedID = model.hoveredID ?? model.selectedID
        var focusedNeighbourIDs: Set<UUID> = []
        if let focusedID {
            for edge in model.layout.edges where edge.fromID == focusedID || edge.toID == focusedID {
                focusedNeighbourIDs.insert(edge.fromID == focusedID ? edge.toID : edge.fromID)
            }
        }
        let positions = Dictionary(uniqueKeysWithValues: model.layout.nodes.map {
            ($0.id, screen(model.displayPosition(of: $0, at: date)))
        })
        let visibleRect = CGRect(origin: .zero, size: size).insetBy(dx: -60, dy: -60)

        // Topic tints, behind everything, so a cluster reads as one thing.
        for topic in model.layout.topics {
            let topLeft = screen(CGPoint(x: topic.frame.minX, y: topic.frame.minY))
            let rectangle = CGRect(x: topLeft.x, y: topLeft.y,
                                   width: topic.frame.width * zoom, height: topic.frame.height * zoom)
            guard rectangle.intersects(visibleRect) else { continue }
            let shape = Path(roundedRect: rectangle, cornerRadius: min(28, 28 * zoom), style: .continuous)
            let dimmed = searchMatchIDs != nil
            context.fill(shape, with: .color(colors.fill(topic.colorIndex).opacity(dimmed ? 0.18 : (colors.colorScheme == .dark ? 0.42 : 0.55))))
        }

        // Links.
        for edge in model.layout.edges {
            guard let from = positions[edge.fromID], let to = positions[edge.toID],
                  let fromNode = model.node(id: edge.fromID), let toNode = model.node(id: edge.toID) else { continue }
            let isFocused = focusedID != nil && (edge.fromID == focusedID || edge.toID == focusedID)
            let isDimmed = (focusedID != nil && !isFocused)
                || (searchMatchIDs.map { !$0.contains(edge.fromID) && !$0.contains(edge.toID) } ?? false)
            let appearance = min(model.appearance(of: fromNode, at: date), model.appearance(of: toNode, at: date))
            let fade = min(fromNode.opacity, toNode.opacity)
            let path = bowedLine(from: from, to: to, salt: edge.id)
            let color = isFocused ? colors.stroke(fromNode.colorIndex ?? toNode.colorIndex) : colors.ink
            let opacity = (isFocused ? 0.85 : (isDimmed ? 0.06 : 0.2 * (0.5 + 0.5 * fade))) * Double(max(0, min(1, appearance)))
            context.stroke(path, with: .color(color.opacity(opacity)),
                           style: StrokeStyle(lineWidth: isFocused ? 2 : 1.3, lineCap: .round))
        }

        // Dots.
        for node in model.layout.nodes {
            guard let centre = positions[node.id], visibleRect.contains(centre) else { continue }
            let appearance = model.appearance(of: node, at: date)
            guard appearance > 0.01 else { continue }
            let radius = max(4, node.radius * zoom) * max(0, appearance)
            let isMatch = searchMatchIDs?.contains(node.id) ?? true
            let isFocused = node.id == focusedID
            let isNeighbour = focusedNeighbourIDs.contains(node.id)
            var opacity = node.opacity * Double(min(1, appearance))
            if !isMatch { opacity *= 0.18 }
            if focusedID != nil && !isFocused && !isNeighbour { opacity *= 0.55 }
            let outline = wobblyCircle(centre: centre, radius: radius, id: node.id)
            if isFocused || node.id == model.selectedID {
                let ring = Path(ellipseIn: CGRect(x: centre.x - radius - 5, y: centre.y - radius - 5,
                                                  width: 2 * radius + 10, height: 2 * radius + 10))
                context.stroke(ring, with: .color(colors.stroke(node.colorIndex).opacity(0.45)), lineWidth: 3)
            }
            context.fill(outline, with: .color(colors.fill(node.colorIndex).opacity(opacity)))
            context.stroke(outline, with: .color(colors.stroke(node.colorIndex).opacity(opacity)),
                           style: StrokeStyle(lineWidth: node.strength == .faded ? 1.4 : 2,
                                              dash: node.strength == .faded ? [4, 3] : []))
            // A small inner dot marks an idea that has been explained more
            // than once: the ones the student has come back to.
            if node.concept.timesExplained > 1 && radius > 7 {
                let core = radius * 0.32
                context.fill(Path(ellipseIn: CGRect(x: centre.x - core, y: centre.y - core, width: 2 * core, height: 2 * core)),
                             with: .color(colors.stroke(node.colorIndex).opacity(opacity * 0.8)))
            }
        }

        drawLabels(in: &context, size: size, positions: positions, zoom: zoom,
                   searchMatchIDs: searchMatchIDs, focusedID: focusedID, focusedNeighbourIDs: focusedNeighbourIDs)
    }

    private func drawPaper(in context: inout GraphicsContext, size: CGSize, camera: (pan: CGSize, zoom: CGFloat)) {
        // Squared paper that moves with the map, thinned out when zoomed far
        // out so it stays a texture and never becomes a grey wash.
        var spacing = 24 * camera.zoom
        while spacing < 14 { spacing *= 2 }
        let origin = model.screenPoint(forMapPoint: .zero, camera: camera)
        let startX = origin.x.truncatingRemainder(dividingBy: spacing) - spacing
        let startY = origin.y.truncatingRemainder(dividingBy: spacing) - spacing
        var dots = Path()
        var x = startX
        while x < size.width + spacing {
            var y = startY
            while y < size.height + spacing {
                dots.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
                y += spacing
            }
            x += spacing
        }
        context.fill(dots, with: .color(colors.paperDots))
    }

    /// Names, most important first, each only if it has room. The focused
    /// idea and its neighbours always get theirs; then search matches; then
    /// topic names; then ideas by how linked and how often explained.
    private func drawLabels(in context: inout GraphicsContext, size: CGSize, positions: [UUID: CGPoint], zoom: CGFloat,
                            searchMatchIDs: Set<UUID>?, focusedID: UUID?, focusedNeighbourIDs: Set<UUID>) {
        var occupied: [CGRect] = []
        // A name may not cover another idea's dot either.
        // During a search the dimmed dots and topic names step back, so
        // the matches' names have the room.
        let dotRects: [(id: UUID, rect: CGRect)] = model.layout.nodes.compactMap { node in
            guard let centre = positions[node.id], searchMatchIDs?.contains(node.id) ?? true else { return nil }
            let radius = max(4, node.radius * zoom) + 2
            return (node.id, CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
        }
        let visibleRect = CGRect(origin: .zero, size: size)

        func priority(_ node: KnowledgeMapNode) -> Double {
            var score = Double(node.linkCount) * 2 + log2(Double(max(1, node.concept.timesExplained))) * 3 + node.retrievability
            if searchMatchIDs?.contains(node.id) == true { score += 1_000 }
            if focusedNeighbourIDs.contains(node.id) { score += 2_000 }
            if node.id == focusedID || node.id == model.selectedID { score += 3_000 }
            return score
        }

        // Topic names sit above their tints, in their colour.
        var topicLabels: [(text: GraphicsContext.ResolvedText, rect: CGRect)] = []
        for topic in model.layout.topics {
            let topLeft = model.screenPoint(forMapPoint: CGPoint(x: topic.frame.minX, y: topic.frame.minY),
                                            camera: (model.camera(at: date).pan, zoom))
            let text = context.resolve(Text(topic.title.uppercased())
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(0.8)
                .foregroundColor(colors.stroke(topic.colorIndex).opacity(searchMatchIDs == nil ? 0.95 : 0.35)))
            let measured = text.measure(in: CGSize(width: 400, height: 40))
            let rect = CGRect(x: topLeft.x + 14, y: topLeft.y - measured.height - 5, width: measured.width, height: measured.height)
            // Two topics side by side can put their names in one spot; the
            // larger topic, laid out first, keeps its name.
            guard rect.intersects(visibleRect), !topicLabels.contains(where: { $0.rect.insetBy(dx: -6, dy: -2).intersects(rect) }) else { continue }
            topicLabels.append((text, rect))
        }

        let ordered = model.layout.nodes.sorted { priority($0) > priority($1) }
        var labelsToDraw: [(text: GraphicsContext.ResolvedText, review: GraphicsContext.ResolvedText?, point: CGPoint, opacity: Double)] = []
        for node in ordered {
            guard let centre = positions[node.id], visibleRect.insetBy(dx: -40, dy: -40).contains(centre) else { continue }
            let appearance = model.appearance(of: node, at: date)
            guard appearance > 0.5 else { continue }
            let isMatch = searchMatchIDs?.contains(node.id) ?? true
            let isFocusedOrNeighbour = node.id == focusedID || node.id == model.selectedID || focusedNeighbourIDs.contains(node.id)
            // A search with a handful of matches names every one of them.
            let isFewSearchMatches = isMatch && (searchMatchIDs.map { $0.count <= 8 } ?? false)
            let isForced = isFocusedOrNeighbour || isFewSearchMatches
            // During a search only matches are named.
            if searchMatchIDs != nil && !isMatch && !isForced { continue }
            var labelOpacity = 0.35 + 0.65 * node.opacity
            if focusedID != nil && !isFocusedOrNeighbour { labelOpacity *= 0.6 }
            let text = context.resolve(Text(node.displayName)
                .font(.system(size: 12, weight: isForced ? .bold : .semibold, design: .rounded))
                .foregroundColor(colors.ink.opacity(labelOpacity)))
            let measured = text.measure(in: CGSize(width: 300, height: 40))
            let radius = max(4, node.radius * zoom)
            let top = centre.y + radius + 4
            var review: GraphicsContext.ResolvedText?
            var height = measured.height
            var width = measured.width
            if node.strength.needsReview {
                let reviewText = context.resolve(Text("review soon")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(colors.reviewSoon.opacity(0.4 + 0.6 * labelOpacity)))
                let reviewSize = reviewText.measure(in: CGSize(width: 200, height: 30))
                review = reviewText
                height += reviewSize.height
                width = max(width, reviewSize.width)
            }
            // Under the dot first; when a neighbour's name is there, slid to
            // one side, then above, then beside it, before giving up.
            let candidateTopCentres = [
                CGPoint(x: centre.x, y: top),
                CGPoint(x: centre.x + width / 2 - radius, y: top),
                CGPoint(x: centre.x - width / 2 + radius, y: top),
                CGPoint(x: centre.x, y: centre.y - radius - 3 - height),
                CGPoint(x: centre.x + radius + 6 + width / 2, y: centre.y - height / 2),
                CGPoint(x: centre.x - radius - 6 - width / 2, y: centre.y - height / 2)
            ]
            func labelRect(topCentre: CGPoint) -> CGRect {
                CGRect(x: topCentre.x - width / 2 - 3, y: topCentre.y - 1, width: width + 6, height: height + 2)
            }
            func isFree(_ rect: CGRect) -> Bool {
                !occupied.contains { $0.intersects(rect) }
                    && (searchMatchIDs != nil || !topicLabels.contains { $0.rect.intersects(rect) })
                    && !dotRects.contains { $0.id != node.id && $0.rect.intersects(rect) }
            }
            let chosenTopCentre = candidateTopCentres.first { isFree(labelRect(topCentre: $0)) }
                ?? (isForced ? candidateTopCentres[0] : nil)
            guard let chosenTopCentre else { continue }
            occupied.append(labelRect(topCentre: chosenTopCentre))
            labelsToDraw.append((text, review, chosenTopCentre, labelOpacity))
        }

        // Topic names first, so where an idea's name had to overlap one
        // (the idea in focus, a search match), the idea's name is on top.
        for topicLabel in topicLabels {
            context.draw(topicLabel.text, in: topicLabel.rect)
        }
        for label in labelsToDraw {
            // A wash of paper behind each name, so a link passing under it
            // never strikes it through.
            let measured = label.text.measure(in: CGSize(width: 300, height: 40))
            let reviewSize = label.review?.measure(in: CGSize(width: 200, height: 30)) ?? .zero
            let backingWidth = max(measured.width, reviewSize.width)
            let backing = CGRect(x: label.point.x - backingWidth / 2 - 3, y: label.point.y - 1,
                                 width: backingWidth + 6, height: measured.height + max(0, reviewSize.height - 1) + 2)
            context.fill(Path(roundedRect: backing, cornerRadius: 4), with: .color(colors.background.opacity(0.82)))
            context.draw(label.text, at: label.point, anchor: .top)
            if let review = label.review {
                context.draw(review, at: CGPoint(x: label.point.x, y: label.point.y + measured.height - 1), anchor: .top)
            }
        }
    }

    /// A pencil-like link: a gentle curve whose bend is fixed per link, so it
    /// looks drawn by hand and is the same curve every time.
    private func bowedLine(from start: CGPoint, to end: CGPoint, salt: String) -> Path {
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let deltaX = end.x - start.x, deltaY = end.y - start.y
        let length = max(1, hypot(deltaX, deltaY))
        var hash: UInt32 = 2_166_136_261
        for byte in salt.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let bend = (CGFloat(hash % 1000) / 1000 - 0.5) * 0.18 * length
        let control = CGPoint(x: middle.x - deltaY / length * bend, y: middle.y + deltaX / length * bend)
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }

    /// A circle with a slight hand-drawn wobble, fixed per idea. Subtle on
    /// purpose: it should read as drawn, never as broken.
    private func wobblyCircle(centre: CGPoint, radius: CGFloat, id: UUID) -> Path {
        guard radius > 6 else {
            return Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
        }
        let pointCount = 14
        let phase = KnowledgeMapLayout.stableFraction(of: id, salt: 11) * 2 * Double.pi
        let wobble = min(1.0, Double(radius) * 0.045)
        var points: [CGPoint] = []
        for step in 0..<pointCount {
            let angle = Double(step) / Double(pointCount) * 2 * Double.pi
            let offset = wobble * sin(3 * angle + phase) + wobble * 0.5 * cos(5 * angle + phase * 1.7)
            let distance = Double(radius) + offset
            points.append(CGPoint(x: centre.x + CGFloat(cos(angle) * distance), y: centre.y + CGFloat(sin(angle) * distance)))
        }
        var path = Path()
        // Through the midpoints, with the points as controls: a smooth closed curve.
        func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
            CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
        }
        path.move(to: midpoint(points[pointCount - 1], points[0]))
        for step in 0..<pointCount {
            let next = points[(step + 1) % pointCount]
            path.addQuadCurve(to: midpoint(points[step], next), control: points[step])
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Small pieces

enum KnowledgeMapDates {
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMM" : "d MMM yyyy")
        return formatter.string(from: date)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        let days = max(2, Int(now.timeIntervalSince(date) / 86_400))
        return "\(days) days ago"
    }
}

/// Faint squared paper behind the empty state, matching the map's.
private struct KnowledgeMapPaperDots: View {
    let colors: KnowledgeMapColors

    var body: some View {
        Canvas { context, size in
            var dots = Path()
            let spacing: CGFloat = 24
            var x: CGFloat = spacing / 2
            while x < size.width {
                var y: CGFloat = spacing / 2
                while y < size.height {
                    dots.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
                    y += spacing
                }
                x += spacing
            }
            context.fill(dots, with: .color(colors.paperDots))
        }
    }
}

/// Three ideas and the links between them, one still to come, for the
/// empty map: a picture of what will appear here.
private struct KnowledgeMapEmptyIllustration: View {
    let colors: KnowledgeMapColors

    var body: some View {
        Canvas { context, size in
            let points = [CGPoint(x: size.width * 0.18, y: size.height * 0.62),
                          CGPoint(x: size.width * 0.5, y: size.height * 0.28),
                          CGPoint(x: size.width * 0.82, y: size.height * 0.6)]
            var links = Path()
            links.move(to: points[0])
            links.addQuadCurve(to: points[1], control: CGPoint(x: size.width * 0.3, y: size.height * 0.3))
            context.stroke(links, with: .color(colors.ink.opacity(0.25)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            var pending = Path()
            pending.move(to: points[1])
            pending.addQuadCurve(to: points[2], control: CGPoint(x: size.width * 0.72, y: size.height * 0.3))
            context.stroke(pending, with: .color(colors.ink.opacity(0.2)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [4, 4]))
            for (index, point) in points.enumerated() {
                let radius: CGFloat = index == 1 ? 17 : 13
                let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius))
                let colorIndex = [0, 2, 3][index]
                let opacity = index == 2 ? 0.4 : 1
                context.fill(circle, with: .color(colors.fill(colorIndex).opacity(opacity)))
                context.stroke(circle, with: .color(colors.stroke(colorIndex).opacity(opacity)),
                               style: StrokeStyle(lineWidth: 2, dash: index == 2 ? [4, 3] : []))
            }
        }
    }
}

private struct KnowledgeMapIconButton: View {
    let systemImage: String
    let help: String
    let colors: KnowledgeMapColors
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colors.ink.opacity(isHovering ? 0.95 : 0.65))
                .frame(width: 28, height: 26)
                .background(Capsule().fill(isHovering ? colors.field : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
        }
    }
}

/// A whole row that can be clicked: a search result or a linked idea.
private struct KnowledgeMapRowButton<Label: View>: View {
    let colors: KnowledgeMapColors
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? colors.field : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
        }
    }
}

private struct KnowledgeMapPrimaryButtonStyle: ButtonStyle {
    let colors: KnowledgeMapColors
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DS.Colors.textOnAccent)
            .padding(.vertical, 9)
            .background(Capsule().fill(isHovering ? DS.Colors.accentHover : colors.accent))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
            }
    }
}

private struct KnowledgeMapQuietButtonStyle: ButtonStyle {
    let colors: KnowledgeMapColors
    let tint: Color
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .padding(.vertical, 7)
            .background(Capsule().fill(isHovering ? tint.opacity(0.1) : Color.clear))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { hovering in
                withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
            }
    }
}
