//
//  MLXRegistration.swift — the app-launch registration seam for the MLX provider (plan §1.3,
//  docs/plans/arikit-engine-extras.md, Track E).
//
//  `ProviderFactory.make(config:mlxClientProvider:)` (`ProviderFactory.swift:34-38`) takes the
//  `MLXClientProvider` closure as a **per-call parameter**, not a mutable global slot — Core
//  `AriKit` deliberately has no static registry to mutate (it must stay MLX-free/headless). So
//  "installing" the closure means: the app holds one `ProviderFactory.MLXClientProvider?` (e.g. a
//  field on its own settings/DI object) and calls `AriKitEngineMLX.register(into: &that)` once at
//  launch, then threads it through to every `ProviderFactory.make(...)` call site — exactly the
//  shape `ProviderFactory.swift`'s header comment describes ("Injected by the app (or
//  `AriKitEngineMLX`) at launch").
//
import AriKit

public enum AriKitEngineMLX {
    /// The `MLXClientProvider` closure this module installs — constructs a real `MLXClient` for
    /// any resolved `.mlx` config. Exposed directly so callers that already own their own
    /// mutable slot (or that call `ProviderFactory.make` inline) can use it without going through
    /// `register(into:)`.
    public static let mlxClientProvider: ProviderFactory.MLXClientProvider = { config in
        MLXClient(config: config)
    }

    /// Installs `mlxClientProvider` into the caller-owned `hook`. Call once at app launch, before
    /// any `ProviderFactory.make(config:mlxClientProvider:)` call that might resolve `.mlx`.
    ///
    /// - Parameter hook: the app's own mutable `ProviderFactory.MLXClientProvider?` slot (there is
    ///   no such slot inside `ProviderFactory` itself — see file header).
    public static func register(into hook: inout ProviderFactory.MLXClientProvider?) {
        hook = mlxClientProvider
    }
}
