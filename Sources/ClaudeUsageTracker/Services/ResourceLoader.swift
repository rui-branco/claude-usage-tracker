import Foundation

/// Helper to load resources from the correct bundle (app bundle or SPM module)
enum ResourceLoader {
    /// Get URL for a resource file
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        // Try loading from app bundle's Resources folder first (for .app distribution)
        if let resourceBundle = Bundle.main.url(forResource: "ClaudeUsageTracker_ClaudeUsageTracker", withExtension: "bundle"),
           let bundle = Bundle(url: resourceBundle),
           let url = bundle.url(forResource: name, withExtension: ext) {
            return url
        }

        // Fall back to Bundle.module (for development/SPM builds)
        return Bundle.module.url(forResource: name, withExtension: ext)
    }

    /// Load data from a resource file
    static func loadData(forResource name: String, withExtension ext: String) -> Data? {
        guard let url = url(forResource: name, withExtension: ext) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
