import Foundation

enum AppInfo {
    /// The version from the repo's VERSION file (stamped into Info.plist by build.sh); "dev" outside an app bundle.
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
