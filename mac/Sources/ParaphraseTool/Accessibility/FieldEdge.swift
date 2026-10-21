import AppKit
import CoreGraphics

/// Finds where a text field's visible edge really is. The Accessibility API reports the focused element's frame,
/// which in browsers is the inner <input> and not the padded, bordered box around it. A few pixels of the screen
/// just past the element show where the box ends: the colour changes at its border.
///
/// Reading screen pixels needs the Screen Recording permission. Without it the capture would only show the desktop
/// picture, so nothing is measured and the caller falls back to a fixed offset.
enum FieldEdge {
    private static let inset = 3          // start this far inside the element, so the reference colour is the field's own
    private static let colorThreshold = 30 // summed per-channel difference that counts as an edge

    /// Screen row (AX coordinates, top-left origin) of the first pixel past the field's bottom (`below`) or top edge,
    /// or nil when no colour change is found within `maxExtra` points. Columns inside `avoid` (our own overlay)
    /// are skipped so it can't measure itself.
    static func find(_ element: CGRect, below: Bool, maxExtra: Int, avoid: CGRect) -> Int? {
        guard CGPreflightScreenCaptureAccess() else { return nil }

        let rows = inset + maxExtra + 1
        let start = below ? Int(element.maxY) - inset : Int(element.minY) + inset
        let top = below ? start : start - rows + 1

        var found = [Int]()
        for fraction in [0.15, 0.30, 0.45] {
            let x = Int(element.minX + element.width * fraction)
            if !avoid.isNull, x >= Int(avoid.minX), x < Int(avoid.maxX) { continue }

            let strip = CGRect(x: x, y: top, width: 1, height: rows)
            guard let image = CGWindowListCreateImage(strip, .optionOnScreenOnly, kCGNullWindowID, [.nominalResolution]),
                  image.height >= rows else { continue }
            let bitmap = NSBitmapImageRep(cgImage: image)

            // Walk away from the element: index 0 is the row at the starting inset.
            func pixel(_ i: Int) -> NSColor? {
                bitmap.colorAt(x: 0, y: below ? i : rows - 1 - i)?.usingColorSpace(.sRGB)
            }
            guard let reference = pixel(0) else { continue }
            for i in 1..<rows {
                guard let color = pixel(i) else { continue }
                if distance(color, reference) >= colorThreshold {
                    found.append(below ? start + i : start - i)
                    break
                }
            }
        }

        guard !found.isEmpty else { return nil }
        found.sort()
        let edge = found[found.count / 2] // median: one column hitting text or an icon doesn't decide it
        DebugLog.write("field edge (\(below ? "bottom" : "top")): element \(below ? element.maxY : element.minY) -> visible \(edge)")
        return edge
    }

    private static func distance(_ a: NSColor, _ b: NSColor) -> Int {
        func channel(_ x: CGFloat) -> Int { Int((x * 255).rounded()) }
        return abs(channel(a.redComponent) - channel(b.redComponent))
            + abs(channel(a.greenComponent) - channel(b.greenComponent))
            + abs(channel(a.blueComponent) - channel(b.blueComponent))
    }
}
