import Foundation

/// Shows a macOS notification banner via osascript (works without a notification entitlement).
enum Notifier {
    static func show(_ title: String, _ message: String) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(message))\" with title \"\(esc(title))\""]
        try? p.run()
    }
}
