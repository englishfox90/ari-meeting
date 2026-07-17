//
//  AriKitTests.swift — smoke test.
//
//  Uses the Swift Testing framework (`import Testing`, bundled with Swift 6). This is the
//  first of the ported invariant suites the migration plan calls for (principle 6); for
//  now it just proves the package builds and the tooling's /swift-test path is green.
//
import Testing

@testable import AriKit

@Suite("AriKit scaffold")
struct AriKitTests {
    @Test("package exposes a version string")
    func versionIsPresent() {
        #expect(!AriKit.version.isEmpty)
    }
}
