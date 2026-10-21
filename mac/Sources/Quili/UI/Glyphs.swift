import AppKit

/// The palette shared by the overlay and the Settings card (same values as the Windows XAML resources).
enum Brand {
    static func hex(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
    static let green = hex(0x3DBE4A)
    static let greenDeep = hex(0x27AE4B)
    static let greenInk = hex(0x1B7F3A)
    static let greenTint = hex(0xE4F4E9)
    static let ink = hex(0x0F1F16)
    static let muted = hex(0x6E7B73)
    static let line = hex(0xD3DAD6)
    static let robotInk = hex(0x1F2A24)
    static let red = hex(0xE5484D)
}

/// Parses SVG path data (the glyph strings the Windows XAML uses) into an `NSBezierPath` in SVG space (y down).
/// Supports M L H V C S Z and their relative forms, which is everything the glyphs need.
enum SVGPath {
    static func parse(_ data: String) -> NSBezierPath {
        let chars = Array(data.utf8)
        var i = 0
        let path = NSBezierPath()
        path.windingRule = .evenOdd // WPF's default fill rule for path geometry

        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        func skipSeparators() {
            while i < chars.count, chars[i] == 32 || chars[i] == 44 || chars[i] == 10 || chars[i] == 13 || chars[i] == 9 { i += 1 }
        }
        func number() -> CGFloat? {
            skipSeparators()
            let begin = i
            if i < chars.count, chars[i] == 43 || chars[i] == 45 { i += 1 }
            var digits = false
            while i < chars.count, isDigit(chars[i]) { i += 1; digits = true }
            if i < chars.count, chars[i] == 46 { // a second '.' starts the next number ("1.5.5" is 1.5 and .5)
                i += 1
                while i < chars.count, isDigit(chars[i]) { i += 1; digits = true }
            }
            guard digits else { i = begin; return nil }
            return Double(String(decoding: chars[begin..<i], as: UTF8.self)).map { CGFloat($0) }
        }
        func numbers(_ count: Int) -> [CGFloat]? {
            var out = [CGFloat]()
            for _ in 0..<count { guard let n = number() else { return nil }; out.append(n) }
            return out
        }

        var current = NSPoint.zero, start = NSPoint.zero
        var previousControl: NSPoint?
        var command: UInt8 = 0

        while true {
            skipSeparators()
            guard i < chars.count else { break }
            let c = chars[i]
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) { command = c; i += 1 } else if command == 0 { break }

            let relative = command >= 97
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                relative ? NSPoint(x: current.x + x, y: current.y + y) : NSPoint(x: x, y: y)
            }
            var control: NSPoint?

            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let a = numbers(2) else { return path }
                current = point(a[0], a[1]); start = current
                path.move(to: current)
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L") // further pairs are implicit line-tos
            case UInt8(ascii: "l"):
                guard let a = numbers(2) else { return path }
                current = point(a[0], a[1]); path.line(to: current)
            case UInt8(ascii: "h"):
                guard let a = numbers(1) else { return path }
                current = NSPoint(x: relative ? current.x + a[0] : a[0], y: current.y); path.line(to: current)
            case UInt8(ascii: "v"):
                guard let a = numbers(1) else { return path }
                current = NSPoint(x: current.x, y: relative ? current.y + a[0] : a[0]); path.line(to: current)
            case UInt8(ascii: "c"):
                guard let a = numbers(6) else { return path }
                let c1 = point(a[0], a[1]), c2 = point(a[2], a[3]), end = point(a[4], a[5])
                path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
                current = end; control = c2
            case UInt8(ascii: "s"):
                guard let a = numbers(4) else { return path }
                let c1 = previousControl.map { NSPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(a[0], a[1]), end = point(a[2], a[3])
                path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
                current = end; control = c2
            case UInt8(ascii: "z"):
                path.close(); current = start; command = 0
            default:
                return path
            }
            previousControl = control
        }
        return path
    }
}

enum Glyph {
    static let gear = SVGPath.parse("M19.14,12.94c0.04-0.3,0.06-0.61,0.06-0.94c0-0.32-0.02-0.64-0.07-0.94l2.03-1.58c0.18-0.14,0.23-0.41,0.12-0.61 l-1.92-3.32c-0.12-0.22-0.37-0.29-0.59-0.22l-2.39,0.96c-0.5-0.38-1.03-0.7-1.62-0.94L14.4,2.81c-0.04-0.24-0.24-0.41-0.48-0.41 h-3.84c-0.24,0-0.43,0.17-0.47,0.41L9.25,5.35C8.66,5.59,8.12,5.92,7.63,6.29L5.24,5.33c-0.22-0.08-0.47,0-0.59,0.22L2.74,8.87 C2.62,9.08,2.66,9.34,2.86,9.48l2.03,1.58C4.84,11.36,4.8,11.69,4.8,12s0.02,0.64,0.07,0.94l-2.03,1.58 c-0.18,0.14-0.23,0.41-0.12,0.61l1.92,3.32c0.12,0.22,0.37,0.29,0.59,0.22l2.39-0.96c0.5,0.38,1.03,0.7,1.62,0.94l0.36,2.54 c0.05,0.24,0.24,0.41,0.48,0.41h3.84c0.24,0,0.44-0.17,0.47-0.41l0.36-2.54c0.59-0.24,1.13-0.56,1.62-0.94l2.39,0.96 c0.22,0.08,0.47,0,0.59-0.22l1.92-3.32c0.12-0.22,0.07-0.47-0.12-0.61L19.14,12.94z M12,15.6c-1.98,0-3.6-1.62-3.6-3.6 s1.62-3.6,3.6-3.6s3.6,1.62,3.6,3.6S13.98,15.6,12,15.6z")
    static let sparkle = SVGPath.parse("M9,5 C9.7,9.4 10.6,11.3 15,13 C10.6,14.7 9.7,16.6 9,21 C8.3,16.6 7.4,14.7 3,13 C7.4,11.3 8.3,9.4 9,5 Z M18,2 C18.3,4.2 18.8,4.7 21,5 C18.8,5.3 18.3,5.8 18,8 C17.7,5.8 17.2,5.3 15,5 C17.2,4.7 17.7,4.2 18,2 Z")
    static let link = SVGPath.parse("M3.9,12c0-1.71,1.39-3.1,3.1-3.1h4V7H7c-2.76,0-5,2.24-5,5s2.24,5,5,5h4v-1.9H7C5.29,15.1,3.9,13.71,3.9,12z M8,13h8v-2H8V13z M17,7h-4v1.9h4c1.71,0,3.1,1.39,3.1,3.1s-1.39,3.1-3.1,3.1h-4V17h4c2.76,0,5-2.24,5-5S19.76,7,17,7z")
    static let key = SVGPath.parse("M12.65,10C11.83,7.67,9.61,6,7,6c-3.31,0-6,2.69-6,6s2.69,6,6,6c2.61,0,4.83-1.67,5.65-4H17v4h4v-4h2v-4H12.65z M7,14c-1.1,0-2-0.9-2-2s0.9-2,2-2s2,0.9,2,2S8.1,14,7,14z")
    static let doc = SVGPath.parse("M14,2H6C4.9,2,4,2.9,4,4v16c0,1.1,0.9,2,2,2h12c1.1,0,2-0.9,2-2V8L14,2z M16,18H8v-2h8V18z M16,14H8v-2h8V14z M13,9V3.5L18.5,9H13z")
    static let eye = SVGPath.parse("M12,4.5C7,4.5,2.73,7.61,1,12c1.73,4.39,6,7.5,11,7.5s9.27-3.11,11-7.5C21.27,7.61,17,4.5,12,4.5z M12,17c-2.76,0-5-2.24-5-5s2.24-5,5-5s5,2.24,5,5S14.76,17,12,17z M12,9c-1.66,0-3,1.34-3,3s1.34,3,3,3s3-1.34,3-3S13.66,9,12,9z")
    static let eyeOff = SVGPath.parse("M12,7c2.76,0,5,2.24,5,5c0,0.65-0.13,1.26-0.36,1.83l2.92,2.92c1.51-1.26,2.7-2.89,3.43-4.75c-1.73-4.39-6-7.5-11-7.5c-1.4,0-2.74,0.25-3.98,0.7l2.16,2.16C10.74,7.13,11.35,7,12,7z M2,4.27l2.28,2.28l0.46,0.46C3.08,8.3,1.78,10.02,1,12c1.73,4.39,6,7.5,11,7.5c1.55,0,3.03-0.3,4.38-0.84l0.42,0.42L19.73,22L21,20.73L3.27,3L2,4.27z M7.53,9.8l1.55,1.55C9.03,11.56,9,11.78,9,12c0,1.66,1.34,3,3,3c0.22,0,0.44-0.03,0.65-0.08l1.55,1.55c-0.67,0.33-1.41,0.53-2.2,0.53c-2.76,0-5-2.24-5-5C7,11.21,7.2,10.47,7.53,9.8z M11.84,9.02l3.15,3.15l0.02-0.16c0-1.66-1.34-3-3-3L11.84,9.02z")
    static let close = SVGPath.parse("M19,6.41L17.59,5L12,10.59L6.41,5L5,6.41L10.59,12L5,17.59L6.41,19L12,13.41L17.59,19L19,17.59L13.41,12z")
    static let save = SVGPath.parse("M17,3H5C3.89,3,3,3.9,3,5v14c0,1.1,0.89,2,2,2h14c1.1,0,2-0.9,2-2V7L17,3z M12,19c-1.66,0-3-1.34-3-3s1.34-3,3-3s3,1.34,3,3S13.66,19,12,19z M15,9H5V5h10V9z")
    static let openNew = SVGPath.parse("M19,19H5V5h7V3H5C3.89,3,3,3.9,3,5v14c0,1.1,0.89,2,2,2h14c1.1,0,2-0.9,2-2v-7h-2V19z M14,3v2h3.59l-9.83,9.83l1.41,1.41L19,6.41V10h2V3H14z")
    static let check = SVGPath.parse("M9,16.17L4.83,12l-1.42,1.41L9,19L21,7l-1.41-1.41z")
    static let github = SVGPath.parse("M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12")

    /// Fills `path` into `rect` (Cocoa, y up). With `viewBox` the path's 24-unit canvas maps onto the rect, like a
    /// WPF Viewbox around a Canvas; without it the path's own bounds are scaled uniformly to fit (Stretch="Uniform").
    static func fill(_ path: NSBezierPath, in rect: NSRect, color: NSColor, viewBox: CGFloat? = nil) {
        let source = viewBox.map { NSRect(x: 0, y: 0, width: $0, height: $0) } ?? path.bounds
        guard source.width > 0, source.height > 0 else { return }
        let scale = min(rect.width / source.width, rect.height / source.height)
        let transform = AffineTransform(m11: scale, m12: 0, m21: 0, m22: -scale,
                                        tX: rect.midX - source.midX * scale, tY: rect.midY + source.midY * scale)
        guard let placed = path.copy() as? NSBezierPath else { return }
        placed.transform(using: transform)
        color.setFill()
        placed.fill()
    }

    /// The little robot head on a 24×24 canvas mapped onto `rect` (Cocoa, y up); the overlay button and the Settings badge.
    static func drawRobot(in rect: NSRect) {
        let k = rect.width / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * k, y: rect.maxY - y * k) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: rect.minX + x * k, y: rect.maxY - (y + h) * k, width: w * k, height: h * k)
        }
        func line(_ from: NSPoint, _ to: NSPoint, width: CGFloat, color: NSColor) {
            let p = NSBezierPath()
            p.move(to: from); p.line(to: to)
            p.lineWidth = width * k
            p.lineCapStyle = .round
            color.setStroke()
            p.stroke()
        }

        Brand.robotInk.setFill()
        line(point(12, 3.5), point(12, 7), width: 1.6, color: Brand.robotInk)
        NSBezierPath(ovalIn: box(10.4, 1.6, 3.2, 3.2)).fill()
        NSBezierPath(roundedRect: box(2, 11, 3, 5), xRadius: 1.2 * k, yRadius: 1.2 * k).fill()
        NSBezierPath(roundedRect: box(19, 11, 3, 5), xRadius: 1.2 * k, yRadius: 1.2 * k).fill()
        NSBezierPath(roundedRect: box(4.5, 7, 15, 13), xRadius: 3.5 * k, yRadius: 3.5 * k).fill()
        Brand.green.setFill()
        NSBezierPath(ovalIn: box(8, 10.8, 3.2, 3.2)).fill()
        NSBezierPath(ovalIn: box(12.8, 10.8, 3.2, 3.2)).fill()
        line(point(9.5, 16.8), point(14.5, 16.8), width: 1.4, color: Brand.green)
    }
}
