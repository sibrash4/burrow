import Foundation
import BurrowCore

/// The one place that decides which job engine backs each sidebar entry.
enum AppWiring {
    /// TODO(agent/ai): the AI leftovers engine is built on branch agent/ai and is not merged yet.
    /// Until it lands, the sidebar entry is backed by a MockJob, so scanning it shows sample rows only.
    /// Replace `aiLeftoversPlaceholder()` with the real job when agent/ai is merged.
    static func aiLeftoversPlaceholder() -> MoleJob {
        MockJob(kind: .aiLeftovers)
    }
}
