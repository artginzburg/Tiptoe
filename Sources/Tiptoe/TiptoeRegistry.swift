import Foundation

/// Keeps started instances alive.
///
/// The point is the chained form — `TiptoeGitHub(owner:repo:).gate(…).start()`
/// — which assigns to nothing. Without this the object would be released on the
/// next line and the app would silently never update, which is the one failure
/// mode a silent updater cannot afford.
///
/// `package` rather than `public`: the adapters live in their own targets and
/// need it, but it is plumbing. A host reading this package's API should not
/// find a general "retain any object forever" facility in it.
@MainActor
package enum TiptoeRegistry {
    private static var held: [ObjectIdentifier: AnyObject] = [:]

    package static func retain(_ object: AnyObject) {
        held[ObjectIdentifier(object)] = object
    }

    package static func release(_ object: AnyObject) {
        held[ObjectIdentifier(object)] = nil
    }
}
