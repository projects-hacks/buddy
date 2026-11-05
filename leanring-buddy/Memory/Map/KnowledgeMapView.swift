//
//  KnowledgeMapView.swift
//  leanring-buddy
//
//  The map of what the student knows, as drawn in its window
//  (KnowledgeMapWindow.swift): board paper with every remembered idea as its
//  hand-lettered name in a capsule, coloured by how well it is remembered
//  (Strong, Fading, Time to review), related ideas joined and clusters
//  named. Hover shows how an idea was last explained; a click opens it in
//  the inspector, with Quick recap, Teach it back and Forget this idea.
//
//  Drawn in one Canvas rather than a view per idea, so 300 ideas pan and
//  zoom as smoothly as 5. Names are drawn at a fixed size on screen, most
//  important first; an idea whose capsule has no room is a small dot in its
//  colour, so the map stays readable at any zoom instead of overprinting.
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

    /// Quick recap: a short spoken recap on screen, through the normal
    /// answer flow.
    var onReteach: (RememberedConcept) -> Void = { _ in }
    var onForget: (RememberedConcept) -> Void = { _ in }
    /// Teach it back, which for now puts the words in the notch's chat box.
    var onTeachBack: (RememberedConcept) -> Void = { _ in }
    /// Opens the Notebook on a lesson the idea came up in, by its title.
    var onOpenLesson: (String) -> Void = { _ in }
    /// The empty state's Turn on, when Remember what I learn is off.
    var onTurnOnMemory: () -> Void = {}
    /// Posted by the window on Delete, so the view asks before forgetting.
    static let forgetRequestedNotification = Notification.Name("KnowledgeMapForgetRequested")

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
        defer { focusOnPendingIdeaIfLaidOut() }
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
        focusOnPendingIdeaIfLaidOut()
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
        // A named idea is drawn as a capsule around its name: the whole
        // capsule is the target.
        if let capsule = drawnCapsuleRects.first(where: { $0.value.insetBy(dx: -2, dy: -2).contains(screenPoint) }) {
            return capsule.key
        }
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

    /// The ideas drawn at full strength: those the search finds and the
    /// filter keeps. Nil when neither narrows anything.
    var searchMatchIDs: Set<UUID>? {
        let searchIDs = searchText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Set(searchMatches.map(\.id))
        let filterIDs = filter == .all ? nil : Set(layout.nodes.filter { filter.includes($0) }.map(\.id))
        switch (searchIDs, filterIDs) {
        case (nil, nil): return nil
        case (let searchIDs?, nil): return searchIDs
        case (nil, let filterIDs?): return filterIDs
        case (let searchIDs?, let filterIDs?): return searchIDs.intersection(filterIDs)
        }
    }

    // MARK: Filter

    enum Filter: Hashable, CaseIterable {
        case all, fading, thisWeek

        var title: String {
            switch self {
            case .all: return "All"
            case .fading: return "Fading"
            case .thisWeek: return "This week"
            }
        }

        func includes(_ node: KnowledgeMapNode, now: Date = Date()) -> Bool {
            switch self {
            case .all: return true
            case .fading: return node.strength.needsReview
            case .thisWeek: return now.timeIntervalSince(node.concept.lastExplainedAt) < 7 * 86_400
            }
        }
    }

    @Published var filter: Filter = .all

    func count(of filter: Filter) -> Int { layout.nodes.filter { filter.includes($0) }.count }

    /// Where each named idea's capsule was drawn in the last frame, in view
    /// points, for hit testing. Written by the renderer; not published,
    /// since it changes with every frame.
    var drawnCapsuleRects: [UUID: CGRect] = [:]

    /// The arrow keys move the selection along the links, to the linked
    /// idea that lies most in the arrow's direction.
    func selectLinkedIdea(towards direction: CGVector) {
        guard let selected = selectedNode ?? layout.nodes.first else { return }
        guard selectedNode != nil else {
            focus(on: selected.id)
            return
        }
        let linkedIDs = layout.edges.compactMap { edge -> UUID? in
            if edge.fromID == selected.id { return edge.toID }
            if edge.toID == selected.id { return edge.fromID }
            return nil
        }
        let best = linkedIDs.compactMap { node(id: $0) }.compactMap { candidate -> (KnowledgeMapNode, CGFloat)? in
            let offset = CGVector(dx: candidate.position.x - selected.position.x, dy: candidate.position.y - selected.position.y)
            let length = max(1, hypot(offset.dx, offset.dy))
            let alignment = (offset.dx * direction.dx + offset.dy * direction.dy) / length
            return alignment > 0.2 ? (candidate, alignment) : nil
        }.max { $0.1 < $1.1 }
        if let best { focus(on: best.0.id) }
    }

    /// An idea to open once the map is laid out, from a lesson's Builds on
    /// chip or a Notebook page. Matched by name, as memory files it.
    private var ideaNameToFocusWhenLaidOut: String?

    func focusWhenLaidOut(onIdeaNamed ideaName: String) {
        ideaNameToFocusWhenLaidOut = ideaName.lowercased()
        focusOnPendingIdeaIfLaidOut()
    }

    func focusOnPendingIdeaIfLaidOut() {
        guard let ideaName = ideaNameToFocusWhenLaidOut, hasLoaded, viewSize != .zero else { return }
        ideaNameToFocusWhenLaidOut = nil
        let match = layout.nodes.first { $0.concept.name.lowercased() == ideaName }
            ?? layout.nodes.first { node in node.concept.aliases.contains { $0.lowercased() == ideaName } }
        if let match { focus(on: match.id) }
    }
}

// MARK: - Colours

/// The map's own colours: board paper for the canvas, with each idea drawn
/// in the colour of how well it is remembered. The window around it is the
/// app's dark chrome; the canvas stays paper, as lessons are.
struct KnowledgeMapColors {
    var background: Color { DS.Paper.board }
    var paperDots: Color { Color.black.opacity(0.075) }
    var ink: Color { DS.Paper.ink }
    var secondaryInk: Color { DS.Paper.inkMuted }
    /// Cluster names, in a muted hand.
    var clusterInk: Color { Color.black.opacity(0.45) }
    var link: Color { Color(hex: "#B9B6AC") }
    var card: Color { Color(hex: "#FFFDF7") }
    var cardBorder: Color { Color.black.opacity(0.1) }
    var field: Color { Color.black.opacity(0.05) }
    var accent: Color { DS.Colors.accent }
    var selectionRing: Color { Color(hex: "#2F6BE0") }
    var destructive: Color { DS.Colors.destructive }

    // Strong, fading and time to review: fill, edge, and the inspector's text.
    func fill(for strength: KnowledgeMapStrength) -> Color {
        switch strength {
        case .solid: return Color(hex: "#CDEBD6")
        case .fading: return Color(hex: "#FBE7B5")
        case .faded: return Color.white
        }
    }

    func edge(for strength: KnowledgeMapStrength) -> Color {
        switch strength {
        case .solid: return Color(hex: "#2E9D5B")
        case .fading: return Color(hex: "#F59A3C")
        case .faded: return DS.Ink.gap
        }
    }

    /// The same colours, readable as text on the dark inspector.
    func label(for strength: KnowledgeMapStrength) -> Color {
        switch strength {
        case .solid: return Color(hex: "#5BD08A")
        case .fading: return Color(hex: "#F7B955")
        case .faded: return Color(hex: "#FF7A7F")
        }
    }
}

extension KnowledgeMapStrength {
    /// Words for the state, so colour is never the only signal.
    var displayName: String {
        switch self {
        case .solid: return "Strong"
        case .fading: return "Fading"
        case .faded: return "Time to review"
        }
    }
}

/// The hand the map writes names in: Noteworthy, then the other hands
/// macOS ships, the way the drawing engine chooses.
private func knowledgeMapHandFont(size: CGFloat) -> Font {
    for name in ["Noteworthy", "Bradley Hand", "Chalkboard SE"] where NSFont(name: name, size: size) != nil {
        return .custom(name, size: size)
    }
    return .system(size: size, design: .rounded)
}

// MARK: - The window's content

struct KnowledgeMapView: View {
    @ObservedObject var model: KnowledgeMapModel
    @FocusState private var isSearchFocused: Bool
    @State private var dragStartPan: CGSize?
    @State private var pinchStartZoom: CGFloat?
    @State private var isConfirmingForget = false

    private let colors = KnowledgeMapColors()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1)
            HStack(spacing: 0) {
                ZStack {
                    if !model.isMemoryEnabled {
                        emptyState(title: "Remember what I learn is off.",
                                   message: "Turn it on and the ideas from each lesson start to appear here.",
                                   showsTurnOn: true)
                    } else if model.hasLoaded && model.layout.nodes.isEmpty {
                        emptyState(title: "Nothing here yet.",
                                   message: "Ideas appear as Buddy explains them. Hold Control + Option and ask about anything on your screen to add the first one.",
                                   showsTurnOn: false)
                    } else {
                        mapCanvas
                        overlays
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colors.background)
                .clipped()
                Rectangle().fill(Color.black.opacity(0.4)).frame(width: 1)
                KnowledgeMapInspector(model: model, colors: colors, onForget: { isConfirmingForget = true })
                    .frame(width: 300)
            }
        }
        .background(DS.Colors.background)
        .environment(\.colorScheme, .dark)
        .alert(forgetAlertTitle, isPresented: $isConfirmingForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                if let concept = model.selectedNode?.concept { model.onForget(concept) }
            }
        } message: {
            Text("Buddy will stop building on it and stop reminding you of it. This can't be undone.")
        }
        .onReceive(NotificationCenter.default.publisher(for: KnowledgeMapModel.forgetRequestedNotification, object: model)) { _ in
            if model.selectedNode != nil { isConfirmingForget = true }
        }
    }

    private var forgetAlertTitle: String {
        "Forget \u{201C}\(model.selectedNode?.concept.name ?? "this idea")\u{201D}?"
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("Map of what you know")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if model.isFindingRelations {
                Text("Linking older ideas\u{2026}")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            Spacer(minLength: 12)
            if !model.layout.nodes.isEmpty {
                filterControl
                NotebookSearchField(text: $model.searchText, placeholder: "Find an idea", isFocused: $isSearchFocused)
                    .frame(width: 260)
                    .onSubmit {
                        if let first = model.searchMatches.first { model.focus(on: first.id) }
                    }
                    .background {
                        // Command F reaches the search however the window was opened.
                        Button("") { isSearchFocused = true }
                            .keyboardShortcut("f", modifiers: .command)
                            .opacity(0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
            }
        }
        // Clear of the window's close, minimise and zoom buttons.
        .padding(.leading, 84)
        .padding(.trailing, 14)
        .frame(height: 52)
        .background(DS.Colors.surface1)
    }

    /// All, Fading and This week, with how many ideas each holds.
    private var filterControl: some View {
        HStack(spacing: 0) {
            ForEach(KnowledgeMapModel.Filter.allCases, id: \.self) { filter in
                KnowledgeMapFilterButton(title: filter.title, count: model.count(of: filter),
                                         isSelected: model.filter == filter) {
                    withAnimation(.easeOut(duration: 0.15)) { model.filter = filter }
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    // MARK: The map

    /// Ideas in the order VoiceOver reads them: by state, then by name, so
    /// the graph is never the only way in.
    private var ideasForVoiceOver: [KnowledgeMapNode] {
        let order: [KnowledgeMapStrength] = [.faded, .fading, .solid]
        return model.layout.nodes.sorted { first, second in
            let firstRank = order.firstIndex(of: first.strength) ?? 0
            let secondRank = order.firstIndex(of: second.strength) ?? 0
            if firstRank != secondRank { return firstRank < secondRank }
            return first.concept.name < second.concept.name
        }
    }

    private func voiceOverDescription(of node: KnowledgeMapNode) -> String {
        let linkedNames = model.layout.edges.compactMap { edge -> String? in
            if edge.fromID == node.id { return model.node(id: edge.toID)?.concept.name }
            if edge.toID == node.id { return model.node(id: edge.fromID)?.concept.name }
            return nil
        }
        var text = "\(node.concept.name), \(node.strength.displayName.lowercased())"
        if !linkedNames.isEmpty { text += ", links to " + linkedNames.joined(separator: ", ") }
        return text
    }

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
            // A double click opens the newest lesson the idea came up in.
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    guard let id = model.nodeID(atScreenPoint: value.location),
                          let newestLesson = model.node(id: id)?.concept.lessonTitles.last else { return }
                    model.onOpenLesson(newestLesson)
                }
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Map of what you know")
            .accessibilityChildren {
                ForEach(ideasForVoiceOver) { node in
                    Button(voiceOverDescription(of: node)) { model.focus(on: node.id) }
                }
            }
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
        }
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
                            Circle().fill(colors.edge(for: node.strength)).frame(width: 8, height: 8)
                            Text(node.concept.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(colors.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if node.strength.needsReview {
                                Text(node.strength.displayName.lowercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(colors.edge(for: node.strength))
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

    /// The three states in words, so colour is never the only signal.
    private var legend: some View {
        HStack(spacing: 16) {
            ForEach([KnowledgeMapStrength.solid, .fading, .faded], id: \.displayName) { strength in
                HStack(spacing: 6) {
                    Circle()
                        .fill(colors.fill(for: strength))
                        .overlay(Circle().stroke(colors.edge(for: strength),
                                                 style: StrokeStyle(lineWidth: 2, dash: strength == .faded ? [3, 2.5] : [])))
                        .frame(width: 12, height: 12)
                    Text(strength.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colors.ink.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(colors.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(colors.cardBorder))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
        .accessibilityElement(children: .combine)
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            KnowledgeMapIconButton(systemImage: "minus", tooltip: "Zoom out", colors: colors) {
                model.zoom(by: 1 / 1.25)
            }
            .keyboardShortcut("-", modifiers: .command)
            KnowledgeMapIconButton(systemImage: "plus", tooltip: "Zoom in", colors: colors) {
                model.zoom(by: 1.25)
            }
            .keyboardShortcut("=", modifiers: .command)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(colors.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(colors.cardBorder))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
        .background {
            // Command 0 still shows the whole map, without a third button.
            Button("") { model.fitToContent(animated: true) }
                .keyboardShortcut("0", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func hoverCard(for node: KnowledgeMapNode) -> some View {
        let centre = model.screenPoint(forMapPoint: node.position)
        let cardWidth: CGFloat = 250
        let capsule = model.drawnCapsuleRects[node.id]
        let halfWidth = (capsule?.width ?? node.radius * 2 * model.zoom) / 2
        // Beside the idea, on whichever side has room.
        let placeOnRight = centre.x + halfWidth + cardWidth + 30 < model.viewSize.width
        let x = placeOnRight ? centre.x + halfWidth + 14 + cardWidth / 2
            : centre.x - halfWidth - 14 - cardWidth / 2
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
                Text(node.strength.displayName.lowercased())
                    .foregroundStyle(colors.edge(for: node.strength))
                    .fontWeight(.semibold)
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

    // MARK: Empty state

    private func emptyState(title: String, message: String, showsTurnOn: Bool) -> some View {
        VStack(spacing: 14) {
            KnowledgeMapEmptyIllustration(colors: colors)
                .frame(width: 180, height: 110)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(colors.ink)
            Text(message)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(colors.secondaryInk)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            if showsTurnOn {
                Button("Turn on") { model.onTurnOnMemory() }
                    .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KnowledgeMapPaperDots(colors: colors))
    }
}

// MARK: - Inspector

/// The chosen idea, on the window's dark side panel: its name and state in
/// words, the plain-words cue memory wrote, when it was learned and is due
/// again, what it links to, the lessons it came from, and what to do next.
private struct KnowledgeMapInspector: View {
    @ObservedObject var model: KnowledgeMapModel
    let colors: KnowledgeMapColors
    let onForget: () -> Void

    var body: some View {
        Group {
            if let node = model.selectedNode {
                ideaDetails(node)
            } else {
                overview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Colors.surface1)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.layout.nodes.count == 1 ? "1 idea" : "\(model.layout.nodes.count) ideas")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
            Text("Click an idea to see how it was explained, when to look at it again, and the lessons it came from.")
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            let needingReview = model.layout.nodes.filter { $0.strength.needsReview }
                .sorted { $0.retrievability < $1.retrievability }
            if !needingReview.isEmpty {
                Text("Worth a look")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .padding(.top, 8)
                VStack(spacing: 0) {
                    ForEach(needingReview.prefix(8)) { node in
                        InspectorRowButton(action: { model.focus(on: node.id) }) {
                            HStack(spacing: 8) {
                                Circle().fill(colors.label(for: node.strength)).frame(width: 7, height: 7)
                                Text(node.concept.name)
                                    .font(.system(size: 13))
                                    .foregroundStyle(DS.Colors.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(node.strength.displayName)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(DS.Colors.textTertiary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
    }

    private func ideaDetails(_ node: KnowledgeMapNode) -> some View {
        let concept = node.concept
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.sentenceCased(concept.name))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(node.strength.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(colors.label(for: node.strength))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(colors.label(for: node.strength).opacity(0.16)))
                    }
                    if !concept.summary.isEmpty {
                        Text(concept.summary)
                            .font(.system(size: 13.5))
                            .lineSpacing(2)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    facts(for: node)
                    if !concept.lessonTitles.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lessons")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DS.Colors.textTertiary)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(Array(concept.lessonTitles.reversed().enumerated()), id: \.offset) { _, lessonTitle in
                                InspectorRowButton(action: { model.onOpenLesson(lessonTitle) }) {
                                    HStack(spacing: 9) {
                                        Image(systemName: "book.closed")
                                            .font(.system(size: 11))
                                            .foregroundStyle(DS.Colors.textTertiary)
                                        Text(LessonTitle.displayed(lessonTitle))
                                            .font(.system(size: 13))
                                            .foregroundStyle(DS.Colors.textPrimary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                }
                                .accessibilityLabel("\(LessonTitle.displayed(lessonTitle)), opens the Notebook")
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Button(action: { model.onReteach(concept) }) {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                                Text("Quick recap").font(.system(size: 13, weight: .semibold))
                            }
                            .padding(.horizontal, 14)
                        }
                        .buttonStyle(KnowledgeMapPrimaryButtonStyle(colors: colors))
                        .pointerCursor()
                        .nativeTooltip("A short spoken recap, drawn on your screen")
                        Button(action: { model.onTeachBack(concept) }) {
                            HStack(spacing: 6) {
                                Image(systemName: "person.wave.2").font(.system(size: 11, weight: .semibold))
                                Text("Teach it back").font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .padding(.horizontal, 14)
                        }
                        .buttonStyle(KnowledgeMapQuietButtonStyle())
                        .pointerCursor()
                        .nativeTooltip("Explain it in your own words")
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 16)
            }
            Spacer(minLength: 0)
            InspectorTextButton(title: "Forget this idea\u{2026}", action: onForget)
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
                .accessibilityLabel("Forget this idea")
        }
    }

    private func facts(for node: KnowledgeMapNode) -> some View {
        let concept = node.concept
        let times = concept.timesExplained == 1 ? "Once" : "\(concept.timesExplained) times"
        let linked = model.layout.edges.compactMap { edge -> KnowledgeMapNode? in
            if edge.fromID == node.id { return model.node(id: edge.toID) }
            if edge.toID == node.id { return model.node(id: edge.fromID) }
            return nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            factRow("Learned") {
                Text("\(times), last on \(concept.lastExplainedAt.formatted(.dateTime.day().month(.wide)))")
            }
            factRow("Next review") { Text(Self.nextReviewText(for: concept)) }
            if !linked.isEmpty {
                factRow("Links to") {
                    // Each one opens on the map.
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(linked) { linkedNode in
                            InspectorLinkButton(title: linkedNode.concept.name) { model.focus(on: linkedNode.id) }
                        }
                    }
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(DS.Colors.textPrimary)
    }

    private func factRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(DS.Colors.textTertiary)
                .frame(width: 92, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// When recall is expected to drop under 85%, where the map starts to
    /// call an idea fading: "In about 2 days", "Today", or "Now".
    static func nextReviewText(for concept: RememberedConcept, now: Date = Date()) -> String {
        // Solving the FSRS curve for 85% recall.
        let daysUntilFading = concept.stabilityDays / ForgettingCurve.factor
            * (pow(0.85, 1 / ForgettingCurve.decay) - 1)
        let due = concept.lastExplainedAt.addingTimeInterval(daysUntilFading * 86_400)
        let daysLeft = due.timeIntervalSince(now) / 86_400
        if daysLeft <= 0 { return "Now" }
        if daysLeft < 1 { return "Today" }
        let rounded = Int(daysLeft.rounded())
        if rounded < 14 { return rounded == 1 ? "In about a day" : "In about \(rounded) days" }
        return "In about \(Int((daysLeft / 7).rounded())) weeks"
    }

    static func sentenceCased(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }
}

private struct InspectorRowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? DS.Notch.rowHover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .padding(.horizontal, -8)
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
        }
    }
}

private struct InspectorLinkButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(isHovering ? DS.Colors.accentText : DS.Colors.textPrimary)
                .underline(isHovering)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
        }
        .accessibilityLabel("\(title), show on the map")
    }
}

private struct InspectorTextButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovering ? DS.Colors.textPrimary : DS.Colors.textTertiary)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
        }
    }
}

private struct KnowledgeMapFilterButton: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(isSelected ? DS.Colors.textPrimary : (isHovering ? DS.Colors.textPrimary : DS.Colors.textSecondary))
                Text("\(count)")
                    .foregroundStyle(DS.Colors.textTertiary)
                    .monospacedDigit()
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.14) : (isHovering ? Color.white.opacity(0.06) : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
        }
        .accessibilityLabel("\(title), \(count) ideas")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Drawing

/// Draws one frame of the map. A struct made per frame, so the drawing code
/// reads top to bottom: paper, links, then each idea as a capsule around its
/// hand-lettered name where there is room, and as a small dot where there
/// is not, so 300 ideas stay readable at any zoom.
@MainActor
struct KnowledgeMapRenderer {
    let model: KnowledgeMapModel
    let colors: KnowledgeMapColors
    let date: Date

    private static let nameSize: CGFloat = 15
    private static let capsuleHeight: CGFloat = 32
    private static let dotRadius: CGFloat = 5.5

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let camera = model.camera(at: date)
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
        let visibleRect = CGRect(origin: .zero, size: size).insetBy(dx: -80, dy: -80)

        // Cluster names first, in a muted hand, where they have room.
        var occupied: [CGRect] = []
        for topic in model.layout.topics {
            let topLeft = screen(CGPoint(x: topic.frame.minX, y: topic.frame.minY))
            let text = context.resolve(Text(topic.title.lowercased())
                .font(knowledgeMapHandFont(size: 17))
                .foregroundColor(colors.clusterInk.opacity(searchMatchIDs == nil ? 1 : 0.4)))
            let measured = text.measure(in: CGSize(width: 400, height: 40))
            let rect = CGRect(x: topLeft.x + 10, y: topLeft.y - measured.height - 2, width: measured.width, height: measured.height)
            guard rect.intersects(visibleRect), !occupied.contains(where: { $0.insetBy(dx: -6, dy: -2).intersects(rect) }) else { continue }
            occupied.append(rect)
            context.draw(text, in: rect)
        }

        // Links: grey pencil lines, darker for the idea in focus.
        for edge in model.layout.edges {
            guard let from = positions[edge.fromID], let to = positions[edge.toID],
                  let fromNode = model.node(id: edge.fromID), let toNode = model.node(id: edge.toID) else { continue }
            let isFocused = focusedID != nil && (edge.fromID == focusedID || edge.toID == focusedID)
            let isDimmed = searchMatchIDs.map { !$0.contains(edge.fromID) && !$0.contains(edge.toID) } ?? false
            let appearance = min(model.appearance(of: fromNode, at: date), model.appearance(of: toNode, at: date))
            let opacity = (isDimmed ? 0.25 : 1) * Double(max(0, min(1, appearance)))
            context.stroke(bowedLine(from: from, to: to, salt: edge.id),
                           with: .color((isFocused ? colors.ink.opacity(0.55) : colors.link).opacity(opacity)),
                           style: StrokeStyle(lineWidth: isFocused ? 2.2 : 1.8, lineCap: .round))
        }

        // Ideas, most important first, so they win the room for a capsule.
        func priority(_ node: KnowledgeMapNode) -> Double {
            var score = Double(node.linkCount) * 2 + log2(Double(max(1, node.concept.timesExplained))) * 3 + node.retrievability
            if searchMatchIDs?.contains(node.id) == true { score += 1_000 }
            if focusedNeighbourIDs.contains(node.id) { score += 2_000 }
            if node.id == focusedID || node.id == model.selectedID { score += 3_000 }
            return score
        }
        var capsules: [(node: KnowledgeMapNode, rect: CGRect, text: GraphicsContext.ResolvedText, opacity: Double)] = []
        var dots: [(node: KnowledgeMapNode, centre: CGPoint, opacity: Double)] = []
        for node in model.layout.nodes.sorted(by: { priority($0) > priority($1) }) {
            guard let centre = positions[node.id], visibleRect.contains(centre) else { continue }
            let appearance = Double(model.appearance(of: node, at: date))
            guard appearance > 0.01 else { continue }
            let isMatch = searchMatchIDs?.contains(node.id) ?? true
            let opacity = (isMatch ? 1 : 0.25) * min(1, appearance)
            let isForced = node.id == focusedID || node.id == model.selectedID || focusedNeighbourIDs.contains(node.id)
                || (isMatch && (searchMatchIDs.map { $0.count <= 8 } ?? false))
            let text = context.resolve(Text(node.displayName)
                .font(knowledgeMapHandFont(size: Self.nameSize))
                .foregroundColor(colors.ink))
            let measured = text.measure(in: CGSize(width: 320, height: 40))
            let width = max(measured.width + 34, 64)
            let rect = CGRect(x: centre.x - width / 2, y: centre.y - Self.capsuleHeight / 2,
                              width: width, height: Self.capsuleHeight)
            let isFree = !occupied.contains { $0.intersects(rect.insetBy(dx: -4, dy: -3)) }
            if appearance > 0.5, isFree || isForced {
                occupied.append(rect)
                capsules.append((node, rect, text, opacity))
            } else {
                dots.append((node, centre, opacity))
            }
        }

        for dot in dots {
            let radius = Self.dotRadius * CGFloat(max(0.3, min(1, model.appearance(of: dot.node, at: date))))
            let circle = Path(ellipseIn: CGRect(x: dot.centre.x - radius, y: dot.centre.y - radius,
                                                width: 2 * radius, height: 2 * radius))
            context.fill(circle, with: .color(colors.fill(for: dot.node.strength).opacity(dot.opacity)))
            context.stroke(circle, with: .color(colors.edge(for: dot.node.strength).opacity(dot.opacity)),
                           style: StrokeStyle(lineWidth: 1.6, dash: dot.node.strength == .faded ? [2.5, 2] : []))
        }

        var drawnCapsuleRects: [UUID: CGRect] = [:]
        // Drawn lowest priority first, so the focused idea sits on top.
        for capsule in capsules.reversed() {
            let node = capsule.node
            let shape = Path(roundedRect: capsule.rect, cornerRadius: Self.capsuleHeight / 2, style: .continuous)
            var layer = context
            layer.opacity = capsule.opacity
            if node.id == model.hoveredID {
                // Raised a point on hover, so it reads as something to press.
                var shadowed = layer
                shadowed.addFilter(.shadow(color: .black.opacity(0.18), radius: 3, y: 1))
                shadowed.fill(shape, with: .color(colors.fill(for: node.strength)))
            }
            if node.id == model.selectedID {
                let ring = Path(roundedRect: capsule.rect.insetBy(dx: -5, dy: -5),
                                cornerRadius: Self.capsuleHeight / 2 + 5, style: .continuous)
                layer.stroke(ring, with: .color(colors.selectionRing), lineWidth: 2.5)
            }
            layer.fill(shape, with: .color(colors.fill(for: node.strength)))
            layer.stroke(shape, with: .color(colors.edge(for: node.strength)),
                         style: StrokeStyle(lineWidth: 2.2, dash: node.strength == .faded ? [6, 5] : []))
            layer.draw(capsule.text, at: CGPoint(x: capsule.rect.midX, y: capsule.rect.midY), anchor: .center)
            drawnCapsuleRects[node.id] = capsule.rect
        }
        model.drawnCapsuleRects = drawnCapsuleRects
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

    /// A pencil-like link: a gentle curve whose bend is fixed per link, so it
    /// looks drawn by hand and is the same curve every time.
    private func bowedLine(from start: CGPoint, to end: CGPoint, salt: String) -> Path {
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let deltaX = end.x - start.x, deltaY = end.y - start.y
        let length = max(1, hypot(deltaX, deltaY))
        var hash: UInt32 = 2_166_136_261
        for byte in salt.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let bend = (CGFloat(hash % 1000) / 1000 - 0.5) * 0.12 * length
        let control = CGPoint(x: middle.x - deltaY / length * bend, y: middle.y + deltaX / length * bend)
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
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
            context.stroke(links, with: .color(colors.link), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            var pending = Path()
            pending.move(to: points[1])
            pending.addQuadCurve(to: points[2], control: CGPoint(x: size.width * 0.72, y: size.height * 0.3))
            context.stroke(pending, with: .color(colors.link),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [4, 4]))
            let strengths: [KnowledgeMapStrength] = [.solid, .fading, .faded]
            for (index, point) in points.enumerated() {
                let capsule = Path(roundedRect: CGRect(x: point.x - 24, y: point.y - 11, width: 48, height: 22),
                                   cornerRadius: 11, style: .continuous)
                context.fill(capsule, with: .color(colors.fill(for: strengths[index])))
                context.stroke(capsule, with: .color(colors.edge(for: strengths[index])),
                               style: StrokeStyle(lineWidth: 2, dash: index == 2 ? [5, 4] : []))
            }
        }
    }
}

private struct KnowledgeMapIconButton: View {
    let systemImage: String
    let tooltip: String
    let colors: KnowledgeMapColors
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(colors.ink.opacity(isHovering ? 0.95 : 0.7))
                .frame(width: 34, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isHovering ? colors.field : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .nativeTooltip(tooltip)
        .accessibilityLabel(tooltip)
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
        }
    }
}

/// A whole row that can be clicked: a search result.
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
            .frame(height: 34)
            .background(Capsule().fill(isHovering ? DS.Colors.accentHover : colors.accent))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
            }
    }
}

/// The second action on the dark inspector: white 10%, 18% on hover.
private struct KnowledgeMapQuietButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DS.Colors.textPrimary)
            .frame(height: 34)
            .background(Capsule().fill(Color.white.opacity(isHovering ? 0.18 : 0.1)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { hovering in
                withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
            }
    }
}
