import AppKit
import Foundation

extension Tiptoe {
    /// Everything the engine measures about the outside world, injected so the
    /// ladder can be tested in microseconds instead of days.
    public struct Environment: Sendable {
        public var now: @Sendable () -> Date
        public var secondsSinceInput: @Sendable () -> TimeInterval
        public var windows: @MainActor @Sendable () -> WindowSnapshot
        /// The running app's short version string. Injected like the rest,
        /// because `Bundle.main` inside a test process is the test runner.
        public var appVersion: @Sendable () -> String

        /// What `Bundle.main` says this app's version is — the reading
        /// ``live`` uses, and the default for anyone assembling an
        /// `Environment` by hand.
        ///
        /// It is the default because the alternative is a safety check that
        /// switches itself off: `appVersion` is what tells a wait recorded by
        /// a previous version of the app from one this version is still
        /// serving, and a host customising its sensors has no reason to want
        /// that lost. A test that cares passes its own closure regardless.
        public static let liveAppVersion: @Sendable () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        }

        public init(
            now: @escaping @Sendable () -> Date,
            secondsSinceInput: @escaping @Sendable () -> TimeInterval,
            windows: @escaping @MainActor @Sendable () -> WindowSnapshot,
            appVersion: @escaping @Sendable () -> String = Environment.liveAppVersion
        ) {
            self.now = now
            self.secondsSinceInput = secondsSinceInput
            self.windows = windows
            self.appVersion = appVersion
        }

        public static let live = Environment(
            now: { Date() },
            secondsSinceInput: {
                // kCGAnyInputEventType — the "any event" sentinel, which has no
                // Swift name; combinedSessionState counts input from every
                // source the way the screen saver's own idle timer does.
                guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
                return CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState, eventType: anyInput)
            },
            windows: {
                var visible = false
                var unsaved = false
                for window in NSApp?.windows ?? [] where window.isVisible {
                    if window.isDocumentEdited || window.attachedSheet != nil { unsaved = true }
                    if window.canBecomeMain { visible = true }
                }
                if NSApp?.modalWindow != nil { unsaved = true }
                return WindowSnapshot(hasVisibleMainCapableWindow: visible, hasUnsavedWork: unsaved)
            },
            appVersion: liveAppVersion
        )
    }
}
