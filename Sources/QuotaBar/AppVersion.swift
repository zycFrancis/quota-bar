import Foundation

/// Single source of truth for the version string that ends up in the settings
/// panel, the Codex client handshake and every outgoing User-Agent.
enum AppVersion {
    static let short: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? fallback
    }()

    static var userAgent: String { "QuotaBar/\(short) macOS" }

    /// Kept in sync with Resources/Info.plist so unbundled debug runs still
    /// report something sensible.
    private static let fallback = "1.5.0"
}
