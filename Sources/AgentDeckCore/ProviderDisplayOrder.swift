import Foundation

/// Shared provider display groups. This does not change collector support,
/// account selection, or the provider that receives a request.
public enum ProviderDisplayOrder {
    public static let trailingProviderIDs: Set<String> = ["deepseek", "kimi", "minimax", "qwen", "zai"]

    public static func isTrailingProvider(_ id: String) -> Bool {
        trailingProviderIDs.contains(id)
    }

    /// Keep the group boundary ahead of usage, readiness, alphabetical, or other local sorting.
    public static func precedes(_ lhs: String, _ rhs: String, otherwise: () -> Bool) -> Bool {
        let left = isTrailingProvider(lhs), right = isTrailingProvider(rhs)
        return left == right ? otherwise() : !left
    }

    public static func isTrailingModel(_ name: String) -> Bool {
        let families = ["deepseek", "kimi", "moonshot", "minimax", "qwen", "glm", "zai", "z-ai", "zhipu"]
        return name.lowercased().split(whereSeparator: { "/:".contains($0) }).contains { component in
            families.contains { component.hasPrefix($0) }
        }
    }
}
