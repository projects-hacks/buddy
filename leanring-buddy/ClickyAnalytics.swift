//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Analytics surface, deliberately inert.
//
//  The upstream build reports usage to a PostHog instance belonging to the
//  original author. This fork runs entirely on-device, and screen contents
//  during a study session are about as private as telemetry gets, so nothing
//  is collected or transmitted.
//
//  The call sites are left intact rather than deleted. Keeping the same
//  static surface means this file is the single place that decides whether
//  anything is recorded, instead of that decision being scattered across
//  the pipeline, and it keeps the diff against upstream readable.
//

import Foundation

enum ClickyAnalytics {

    // MARK: - Setup

    static func configure() {
        print("📊 Analytics disabled: this build reports nothing off-device.")
    }

    // MARK: - App Lifecycle

    static func trackAppOpened() {}

    // MARK: - Onboarding

    static func trackOnboardingStarted() {}
    static func trackOnboardingReplayed() {}
    static func trackOnboardingDemoTriggered() {}
    static func trackOnboardingVideoCompleted() {}

    // MARK: - Permissions

    static func trackPermissionGranted(permission: String) {}
    static func trackAllPermissionsGranted() {}

    // MARK: - Interaction

    static func trackPushToTalkStarted() {}
    static func trackPushToTalkReleased() {}
    static func trackUserMessageSent(transcript: String) {}
    static func trackAIResponseReceived(response: String) {}
    static func trackElementPointed(elementLabel: String?) {}

    // MARK: - Errors

    static func trackTTSError(error: String) {}
    static func trackResponseError(error: String) {}
}
