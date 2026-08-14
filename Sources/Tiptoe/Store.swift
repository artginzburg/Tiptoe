import Foundation

/// The little that has to survive a relaunch.
///
/// The wait is persisted because the clock measures *continuous waiting*: a
/// logout that reset it would mean the later rungs of the ladder are never
/// reached on the machines that need them most.
struct Store {
    private let defaults: UserDefaults
    private let prefix = "Tiptoe."

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var waitingSince: Date? {
        get { defaults.object(forKey: prefix + "waitingSince") as? Date }
        nonmutating set { defaults.set(newValue, forKey: prefix + "waitingSince") }
    }

    var pendingVersion: String? {
        get { defaults.string(forKey: prefix + "pendingVersion") }
        nonmutating set { defaults.set(newValue, forKey: prefix + "pendingVersion") }
    }

    /// The version of the app that was running when the wait was recorded.
    ///
    /// This is what makes it possible to notice that the update landed some
    /// other way — Sparkle installing it on quit, Homebrew, a DMG dragged in
    /// by hand. Without it a wait started three months ago outlives the update
    /// it was waiting for, and the next one inherits a clock that puts the
    /// most permissive rung of the ladder in reach on its first evaluation.
    var appVersion: String? {
        get { defaults.string(forKey: prefix + "appVersion") }
        nonmutating set { defaults.set(newValue, forKey: prefix + "appVersion") }
    }

    /// The version installed while nobody was looking, for the host to show
    /// once and then acknowledge.
    var justUpdatedTo: String? {
        get { defaults.string(forKey: prefix + "justUpdatedTo") }
        nonmutating set { defaults.set(newValue, forKey: prefix + "justUpdatedTo") }
    }

    var hasEscalated: Bool {
        get { defaults.bool(forKey: prefix + "hasEscalated") }
        nonmutating set { defaults.set(newValue, forKey: prefix + "hasEscalated") }
    }

    func clearWait() {
        waitingSince = nil
        pendingVersion = nil
        appVersion = nil
        hasEscalated = false
    }
}
