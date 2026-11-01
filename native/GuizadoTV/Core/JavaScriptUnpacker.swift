import Foundation

/// Decodes the public player's data packing. It does not evaluate scripts or implement DRM.
enum JavaScriptUnpacker {
    static func unpack(_ html: String) throws -> String {
        guard let start = html.range(of: "}('") else { return html }
        let chars = Array(html[start.upperBound...])
        func quoteEnd(_ start: Int) throws -> Int {
            var i = start
            while i < chars.count {
                if chars[i] == "\\" { i += 2; continue }
                if chars[i] == "'" { return i }; i += 1
            }
            throw AppFailure.invalidData
        }
        let end = try quoteEnd(0), payload = try decodeString(String(chars[0..<end]))
        let tail = String(chars[(end + 1)...])
        guard let header = TextTools.captures(#"^,(\d+),(\d+),'"#, in: tail).first,
              let radix = Int(header[1]), (2...62).contains(radix) else { throw AppFailure.invalidData }
        let wordStart = end + 1 + header[0].count, wordEnd = try quoteEnd(wordStart)
        guard String(chars[(wordEnd + 1)...]).hasPrefix(".split('|')") else { throw AppFailure.invalidData }
        let words = try decodeString(String(chars[wordStart..<wordEnd])).components(separatedBy: "|")
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let regex = try NSRegularExpression(pattern: #"\b[0-9A-Za-z]+\b"#)
        var output = payload
        for match in regex.matches(in: payload, range: NSRange(payload.startIndex..., in: payload)).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let token = output[range]; var index = 0; var valid = true
            for char in token {
                guard let digit = digits.firstIndex(of: char), digit < radix, index < words.count else { valid = false; break }
                let product = index.multipliedReportingOverflow(by: radix)
                let sum = product.partialValue.addingReportingOverflow(digit)
                if product.overflow || sum.overflow || sum.partialValue >= words.count { valid = false; break }
                index = sum.partialValue
            }
            if valid && !words[index].isEmpty { output.replaceSubrange(range, with: words[index]) }
        }
        return output
    }
    static func decodeString(_ raw: String) throws -> String {
        let chars = Array(raw); var output = ""; var i = 0
        while i < chars.count {
            let char = chars[i]; i += 1
            guard char == "\\", i < chars.count else { output.append(char); continue }
            let escaped = chars[i]; i += 1
            switch escaped {
            case "n": output.append("\n")
            case "r": output.append("\r")
            case "t": output.append("\t")
            case "\\", "'", "\"", "/": output.append(escaped)
            case "x", "u":
                let count = escaped == "x" ? 2 : 4
                guard i + count <= chars.count, let value = UInt32(String(chars[i..<(i + count)]), radix: 16), let scalar = UnicodeScalar(value) else { throw AppFailure.invalidData }
                output.unicodeScalars.append(scalar); i += count
            default: output.append("\\"); output.append(escaped)
            }
        }
        return output
    }
}
