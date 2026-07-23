//
//  UserFacingError.swift — one place that turns a thrown `Error` into something a person can
//  read.
//
//  View models used to write `String(describing: error)` straight into a `.failed(String)` phase,
//  which renders a Swift enum literally — e.g. `notConfigured("This meeting has no transcript to
//  summarize.")` sitting under "Recording saved" like a leaked crash log. The sentence was already
//  there; only the enum wrapper made it look like a fault.
//
//  No-Fake-State: this never invents a friendlier story than the error tells. It prefers the
//  error's own `errorDescription` (our engine errors conform to `LocalizedError`), then a
//  Foundation-bridged `localizedDescription`, and only falls back to the raw description when
//  neither exists — an honest last resort, never a fabricated "Something went wrong."
//
import Foundation

public enum UserFacingError {
    /// The message to show a person for `error`.
    public static func message(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        // Foundation-bridged errors (URLError, CocoaError, POSIX…) carry real localized text.
        // A plain Swift enum does not — its bridged description is the useless "The operation
        // couldn't be completed. (Module.Error error 0.)", so prefer the raw case there.
        let nsError = error as NSError
        if !nsError.domain.isEmpty, nsError.localizedDescription.contains("couldn’t be completed") == false,
           nsError.localizedDescription.contains("couldn't be completed") == false
        {
            return nsError.localizedDescription
        }
        return String(describing: error)
    }

    /// The message prefixed with what the app was doing — `"Could not save the meeting: …"`.
    public static func message(_ error: Error, whileTrying context: String) -> String {
        "\(context): \(message(error))"
    }
}
