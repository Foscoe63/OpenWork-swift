import Foundation

/// Deep copies of JSON values (`[String: Any]`, arrays, `Any` from `JSONSerialization`).
///
/// Such values are not Sendable, so the compiler lets one cross into an actor only when nothing
/// else still refers to it. A copy made here shares nothing with the original, so it can be sent
/// while the original stays in use — one element of a response array, or tool arguments the
/// caller reads again afterwards.
public enum JSONCopy {
    public static func fresh(_ value: Any) -> sending Any {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let copy = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            return NSNull()
        }
        return copy
    }

    public static func fresh(_ object: [String: Any]) -> sending [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let copy = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return copy
    }
}
