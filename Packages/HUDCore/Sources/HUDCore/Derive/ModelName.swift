import Foundation

public enum ModelName {
    /// "claude-fable-5-1" → "fable-5.1", "claude-haiku-4-5-20251001" → "haiku-4.5".
    public static func short(_ model: String) -> String {
        var parts = model.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
        parts.removeAll { $0.count == 8 && Int($0) != nil }
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family : "\(family)-\(version)"
    }
}
