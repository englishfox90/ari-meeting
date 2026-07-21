///
///  LoadState.swift — the No-Fake-State spine for every read-UI view model
///  (docs/plans/arikit-native-read-ui.md §2.3).
///
///  `.empty` is a FIRST-CLASS state, deliberately distinct from `.loaded([])`: a screen renders
///  honest "nothing here yet" copy for a genuinely empty library, never a spinner that never ends
///  and never fabricated rows. `.failed` carries the real error text — never a fake "ready".
///
public enum LoadState<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case empty
    case failed(String)
}

public extension LoadState {
    /// The loaded value, if any — convenience for views that treat `.empty`/`.loading` uniformly.
    var value: Value? {
        if case let .loaded(value) = self {
            return value
        }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }
}
