import Foundation

extension StringProtocol {
    func legacyFirstMatch(_ pattern: String) -> (Substring, Substring, Substring, Substring)? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: String(self), range: NSRange(startIndex..., in: self)) else { return nil }
        func capture(_ index: Int) -> Substring {
            guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: self) else { return Substring(self[startIndex..<startIndex]) }
            return Substring(self[range])
        }
        return (capture(0), capture(1), capture(2), capture(3))
    }
    func legacyMatches(_ pattern: String) -> [(Substring, Substring, Substring, Substring)] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: String(self), range: NSRange(startIndex..., in: self)).map { match in
            func capture(_ index: Int) -> Substring {
                guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: self) else { return Substring(self[startIndex..<startIndex]) }
                return Substring(self[range])
            }
            return (capture(0), capture(1), capture(2), capture(3))
        }
    }
    func legacyReplacing(_ pattern: String, with replacement: String) -> String {
        String(self).replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    func legacyReplacingTags(_ pattern: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return String(self) }
        var result = String(self)
        for match in expression.matches(in: String(self), range: NSRange(startIndex..., in: self)).reversed() {
            guard let full = Range(match.range, in: result), let slash = Range(match.range(at: 1), in: self), let tag = Range(match.range(at: 2), in: self) else { continue }
            result.replaceSubrange(full, with: "\u{1}\(self[slash])\(self[tag].lowercased())\u{2}")
        }
        return result
    }
}
