//
//  LoopbackPolicy.swift — the loopback-only Ollama gate (plan §7, ← shell.rs:21).
//
//  Load-bearing invariant: the local recall path may only talk to an Ollama server on THIS
//  device. `nil`/empty endpoint → allowed (the default local server). An unparseable endpoint →
//  denied. Otherwise the host must be one of the loopback aliases.
//
import Foundation

extension Recall {
    /// Whether `endpoint` names a loopback Ollama server (← `is_loopback_ollama_endpoint`).
    ///
    /// Parity notes vs. Rust (`reqwest::Url` = the `url` crate):
    /// - `nil` or whitespace-only → `true` (no endpoint means the default local server).
    /// - Unparseable → `false` (Rust: `Url::parse` errors, e.g. `"not a url"`).
    /// - Otherwise the host must be `localhost` / `127.0.0.1` / `::1` / `[::1]`. Rust's
    ///   `url.host_str()` returns the bracketed `[::1]` for a bracketed IPv6 literal; the allow-set
    ///   carries BOTH forms, so this stays correct whether Swift's `URLComponents.host` keeps or
    ///   strips the brackets.
    public static func isLoopbackOllamaEndpoint(_ endpoint: String?) -> Bool {
        guard let trimmed = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return true
        }
        guard let components = URLComponents(string: trimmed), let host = components.host else {
            return false
        }
        switch host {
        case "localhost", "127.0.0.1", "::1", "[::1]":
            return true
        default:
            return false
        }
    }
}
