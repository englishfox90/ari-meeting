//
//  LoadStateTests.swift — the No-Fake-State spine: `.empty` is distinct from `.loaded([])`.
//
import Testing
@testable import AriViewModels

@Suite("LoadState")
struct LoadStateTests {
    @Test("empty is not loaded — the honest-empty distinction holds")
    func emptyIsNotLoaded() {
        let empty = LoadState<[Int]>.empty
        #expect(empty.value == nil)
        #expect(empty.isLoading == false)
    }

    @Test("loaded exposes its value; loading reports loading")
    func loadedAndLoading() {
        let loaded = LoadState<[Int]>.loaded([1, 2, 3])
        #expect(loaded.value == [1, 2, 3])
        #expect(loaded.isLoading == false)
        #expect(LoadState<[Int]>.loading.isLoading == true)
    }
}
