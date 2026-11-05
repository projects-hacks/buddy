//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//
//  Both taps run on a thread of their own, not the main one. The Control +
//  Option + T tap may swallow keys, so every key press on the Mac waits for
//  its answer: on the main thread, any work there (an accessibility read of
//  a busy app, a long layout) delayed typing everywhere and made macOS
//  switch the tap off for being slow. Only the transitions hop to main.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Control + Option + T: type a question instead of saying it. T is
    /// pressed while the talk keys are already down, so the voice that
    /// started on Control + Option is cancelled by whoever listens here.
    let typeQuestionRequestPublisher = PassthroughSubject<Void, Never>()
    private static let typeQuestionKeyCode: UInt16 = 17 // T

    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var typeQuestionEventTapRunLoopSource: CFRunLoopSource?
    /// Published on the main thread, so the overlay can hide immediately on
    /// key release without waiting for the async dictation state pipeline.
    @Published private(set) var isShortcutCurrentlyPressed = false

    /// What the tap thread reads and writes, behind a lock because start
    /// and stop run on the main thread.
    private struct TapState {
        var globalEventTap: CFMachPort?
        /// A second tap that is allowed to swallow keys, for Control + Option
        /// + T only. The talk keys stay on the listen-only tap above. Without
        /// this the T also reaches the app in front, and Control + T there is
        /// "transpose": it swaps two letters in whatever the student was writing.
        var typeQuestionEventTap: CFMachPort?
        var isShortcutPressed = false
    }
    private let tapStateLock = NSLock()
    nonisolated(unsafe) private var tapState = TapState()

    deinit {
        stop()
    }

    nonisolated private func withTapState<Result>(_ body: (inout TapState) -> Result) -> Result {
        tapStateLock.lock()
        defer { tapStateLock.unlock() }
        return body(&tapState)
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard withTapState({ $0.globalEventTap == nil }) else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        withTapState { $0.globalEventTap = globalEventTap }
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(EventTapThread.shared.runLoop, globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
        CFRunLoopWakeUp(EventTapThread.shared.runLoop)
        startTypeQuestionTap()
    }

    private func startTypeQuestionTap() {
        let keyEventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GlobalPushToTalkShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handleTypeQuestionTap(eventType: eventType, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: keyEventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            print("⚠️ Control + Option + T: couldn't create the key tap, listening only")
            return
        }
        withTapState { $0.typeQuestionEventTap = tap }
        typeQuestionEventTapRunLoopSource = source
        CFRunLoopAddSource(EventTapThread.shared.runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopWakeUp(EventTapThread.shared.runLoop)
    }

    nonisolated private static func isTypeQuestionShortcut(_ event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        return keyCode == typeQuestionKeyCode
            && event.flags.contains(.maskControl) && event.flags.contains(.maskAlternate)
            && !event.flags.contains(.maskCommand) && !event.flags.contains(.maskShift)
    }

    /// Runs on every key press system-wide, on the tap thread, so it does
    /// nothing but compare.
    nonisolated private func handleTypeQuestionTap(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let typeQuestionEventTap = withTapState({ $0.typeQuestionEventTap }) {
                CGEvent.tapEnable(tap: typeQuestionEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard Self.isTypeQuestionShortcut(event) else { return Unmanaged.passUnretained(event) }
        let isKeyRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if eventType == .keyDown, !isKeyRepeat {
            publishTypeQuestionRequest()
        }
        // Down, repeats and up are all kept from the app in front.
        return nil
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        let (globalEventTap, typeQuestionEventTap) = withTapState { state -> (CFMachPort?, CFMachPort?) in
            let taps = (state.globalEventTap, state.typeQuestionEventTap)
            state = TapState()
            return taps
        }

        if let typeQuestionEventTapRunLoopSource {
            CFRunLoopRemoveSource(EventTapThread.shared.runLoop, typeQuestionEventTapRunLoopSource, .commonModes)
            self.typeQuestionEventTapRunLoopSource = nil
        }
        if let typeQuestionEventTap {
            CFMachPortInvalidate(typeQuestionEventTap)
        }

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(EventTapThread.shared.runLoop, globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
        }
    }

    nonisolated private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap = withTapState({ $0.globalEventTap }) {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        // Only when the swallowing tap could not be made; it handles T itself.
        let hasTypeQuestionTap = withTapState { $0.typeQuestionEventTap != nil }
        if !hasTypeQuestionTap, eventType == .keyDown, Self.isTypeQuestionShortcut(event),
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            publishTypeQuestionRequest()
            return Unmanaged.passUnretained(event)
        }
        let shortcutTransition = withTapState { state -> BuddyPushToTalkShortcut.ShortcutTransition in
            let transition = BuddyPushToTalkShortcut.shortcutTransition(
                for: eventType,
                keyCode: eventKeyCode,
                modifierFlagsRawValue: event.flags.rawValue,
                wasShortcutPreviouslyPressed: state.isShortcutPressed
            )
            switch transition {
            case .none: break
            case .pressed: state.isShortcutPressed = true
            case .released: state.isShortcutPressed = false
            }
            return transition
        }
        publish(shortcutTransition)

        return Unmanaged.passUnretained(event)
    }

    /// Hands a transition to the main thread, where everything that reacts
    /// to it lives.
    nonisolated private func publish(_ shortcutTransition: BuddyPushToTalkShortcut.ShortcutTransition) {
        guard shortcutTransition != .none else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch shortcutTransition {
            case .none:
                break
            case .pressed:
                self.isShortcutCurrentlyPressed = true
                self.shortcutTransitionPublisher.send(.pressed)
            case .released:
                self.isShortcutCurrentlyPressed = false
                self.shortcutTransitionPublisher.send(.released)
            }
        }
    }

    nonisolated private func publishTypeQuestionRequest() {
        DispatchQueue.main.async { [weak self] in
            self?.typeQuestionRequestPublisher.send(())
        }
    }
}

/// The thread the event taps run on: its own run loop, alive for as long as
/// the app is, doing nothing but deliver key events.
nonisolated final class EventTapThread: @unchecked Sendable {
    static let shared = EventTapThread()

    private(set) var runLoop: CFRunLoop!

    private init() {
        let runLoopIsReady = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            // A run loop with no sources returns at once; this port keeps it
            // waiting for the taps' sources, which are added later.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            runLoopIsReady.signal()
            while true {
                CFRunLoopRun()
            }
        }
        thread.name = "Buddy event taps"
        thread.qualityOfService = .userInteractive
        thread.start()
        runLoopIsReady.wait()
    }
}
