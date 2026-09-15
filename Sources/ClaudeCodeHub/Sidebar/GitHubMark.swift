import SwiftUI

/// The GitHub octocat mark, drawn from its official single-path SVG (24×24 viewBox) so it needs
/// no image asset and tints like an SF Symbol.
struct GitHubMark: View {
    var size: CGFloat = 12
    var color: Color = Theme.text2

    var body: some View {
        GitHubMarkShape()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityLabel("Tracked on GitHub")
    }
}

struct GitHubMarkShape: Shape {
    // The GitHub mark path (viewBox 0 0 24 24), even-odd fill.
    static let pathData =
        "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"

    func path(in rect: CGRect) -> Path {
        let raw = SVGPath.parse(Self.pathData)
        let scale = min(rect.width, rect.height) / 24.0
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        return Path(raw.cgPath.copy(using: &transform) ?? raw.cgPath)
    }
}

/// Minimal SVG path parser: supports M/m, L/l, H/h, V/v, C/c, S/s, Z/z — enough for icon marks.
enum SVGPath {
    static func parse(_ data: String) -> Path {
        var path = Path()
        var index = data.startIndex
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var command: Character = " "

        func nextNumber() -> CGFloat? {
            skipSeparators()
            var s = ""
            if index < data.endIndex, data[index] == "-" || data[index] == "+" {
                s.append(data[index]); index = data.index(after: index)
            }
            var sawDot = false
            while index < data.endIndex {
                let c = data[index]
                if c.isNumber {
                    s.append(c)
                } else if c == "." && !sawDot {
                    sawDot = true; s.append(c)
                } else {
                    break
                }
                index = data.index(after: index)
            }
            return s.isEmpty ? nil : CGFloat(Double(s) ?? 0)
        }
        func skipSeparators() {
            while index < data.endIndex, data[index] == " " || data[index] == "," || data[index] == "\n" || data[index] == "\t" {
                index = data.index(after: index)
            }
        }
        func point(relative: Bool, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
            relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while index < data.endIndex {
            skipSeparators()
            guard index < data.endIndex else { break }
            let c = data[index]
            if c.isLetter {
                command = c
                index = data.index(after: index)
            }
            let rel = command.isLowercase
            switch command.uppercased().first! {
            case "M":
                guard let x = nextNumber(), let y = nextNumber() else { return path }
                current = point(relative: rel, x, y)
                path.move(to: current); start = current; lastControl = nil
                command = rel ? "l" : "L"   // subsequent pairs are implicit lineto
            case "L":
                guard let x = nextNumber(), let y = nextNumber() else { return path }
                current = point(relative: rel, x, y); path.addLine(to: current); lastControl = nil
            case "H":
                guard let x = nextNumber() else { return path }
                current = CGPoint(x: rel ? current.x + x : x, y: current.y); path.addLine(to: current); lastControl = nil
            case "V":
                guard let y = nextNumber() else { return path }
                current = CGPoint(x: current.x, y: rel ? current.y + y : y); path.addLine(to: current); lastControl = nil
            case "C":
                guard let x1 = nextNumber(), let y1 = nextNumber(), let x2 = nextNumber(), let y2 = nextNumber(),
                      let x = nextNumber(), let y = nextNumber() else { return path }
                let c1 = point(relative: rel, x1, y1), c2 = point(relative: rel, x2, y2), end = point(relative: rel, x, y)
                path.addCurve(to: end, control1: c1, control2: c2); current = end; lastControl = c2
            case "S":
                guard let x2 = nextNumber(), let y2 = nextNumber(), let x = nextNumber(), let y = nextNumber() else { return path }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(relative: rel, x2, y2), end = point(relative: rel, x, y)
                path.addCurve(to: end, control1: c1, control2: c2); current = end; lastControl = c2
            case "Z":
                path.closeSubpath(); current = start; lastControl = nil
            default:
                return path
            }
        }
        return path
    }
}
