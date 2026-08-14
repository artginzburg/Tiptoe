import Foundation
import Testing

@testable import Tiptoe

private func freshDefaults() -> UserDefaults {
    let suite = "TiptoeTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@Test func theWaitSurvivesANewStore() {
    let defaults = freshDefaults()
    let started = Date(timeIntervalSince1970: 1_000_000)
    let store = Store(defaults: defaults)
    store.waitingSince = started
    store.pendingVersion = "1.4.0"

    let reopened = Store(defaults: defaults)
    #expect(reopened.waitingSince == started)
    #expect(reopened.pendingVersion == "1.4.0")
}

@Test func clearingTheWaitForgetsEverythingAboutIt() {
    let defaults = freshDefaults()
    let store = Store(defaults: defaults)
    store.waitingSince = Date()
    store.pendingVersion = "1.4.0"
    store.appVersion = "1.3.0"
    store.hasEscalated = true

    store.clearWait()

    let reopened = Store(defaults: defaults)
    #expect(reopened.waitingSince == nil)
    #expect(reopened.pendingVersion == nil)
    // Left behind, this would make the next wait look like it belonged to an
    // older version of the app and be discarded on the following launch.
    #expect(reopened.appVersion == nil)
    #expect(reopened.hasEscalated == false)
}

@Test func theNoticeOfASilentUpdateIsKeptUntilTheHostReadsIt() {
    let defaults = freshDefaults()
    let store = Store(defaults: defaults)
    store.justUpdatedTo = "1.4.0"

    #expect(Store(defaults: defaults).justUpdatedTo == "1.4.0")

    store.justUpdatedTo = nil
    #expect(Store(defaults: defaults).justUpdatedTo == nil)
}
