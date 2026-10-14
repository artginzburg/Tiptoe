/// Whether two strings name one version, read the way a release tag and a
/// bundle can disagree about it.
///
/// The adapter learns a version from the release — `v1.5.0` on the tag,
/// `1.5.0` once parsed — and the engine learns it from the bundle, where the
/// same release may be carried as `1.5`. Both reconciliations in `init` ask
/// whether those two are the same version, and a plain string comparison
/// would say no, turning every update into "landed some other way" for one
/// host and dropping every notice for another. So: a leading `v` is ignored,
/// trailing `.0` components are ignored, and a pre-release suffix is part of
/// the version — `1.5-beta.1` is a different version from `1.5`.
func sameVersion(_ lhs: String, _ rhs: String) -> Bool {
    func parts(_ version: String) -> (release: [Substring], suffix: Substring) {
        var remainder = Substring(version)
        if remainder.first == "v" || remainder.first == "V" { remainder = remainder.dropFirst() }
        let suffixStart = remainder.firstIndex(of: "-") ?? remainder.endIndex
        var release = remainder[..<suffixStart].split(separator: ".", omittingEmptySubsequences: false)
        while release.count > 1, release.last == "0" { release.removeLast() }
        return (release, remainder[suffixStart...])
    }
    let left = parts(lhs)
    let right = parts(rhs)
    return left.release == right.release && left.suffix == right.suffix
}
