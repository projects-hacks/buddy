//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
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

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// A second tap that is allowed to swallow keys, for Control + Option + T
    /// only. The talk keys stay on the listen-only tap above. Without this the
    /// T also reaches the app in front, and Control + T there is "transpose":
    /// it swaps two letters in whatever the student was writing.
    private var typeQuestionEventTap: CFMachPort?
    private var typeQuestionEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

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

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
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
        typeQuestionEventTap = tap
        typeQuestionEventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static func isTypeQuestionShortcut(_ event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        return keyCode == typeQuestionKeyCode
            && event.flags.contains(.maskControl) && event.flags.contains(.maskAlternate)
            && !event.flags.contains(.maskCommand) && !event.flags.contains(.maskShift)
    }

    /// Runs on every key press system-wide, so it does nothing but compare.
    private func handleTypeQuestionTap(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let typeQuestionEventTap { CGEvent.tapEnable(tap: typeQuestionEventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard Self.isTypeQuestionShortcut(event) else { return Unmanaged.passUnretained(event) }
        let isKeyRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if eventType == .keyDown, !isKeyRepeat {
            typeQuestionRequestPublisher.send(())
        }
        // Down, repeats and up are all kept from the app in front.
        return nil
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let typeQuestionEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), typeQuestionEventTapRunLoopSource, .commonModes)
            self.typeQuestionEventTapRunLoopSource = nil
        }
        if let typeQuestionEventTap {
            CFMachPortInvalidate(typeQuestionEventTap)
            self.typeQuestionEventTap = nil
        }

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        // Only when the swallowing tap could not be made; it handles T itself.
        if typeQuestionEventTap == nil, eventType == .keyDown, Self.isTypeQuestionShortcut(event),
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            typeQuestionRequestPublisher.send(())
            return Unmanaged.passUnretained(event)
        }
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }
}
