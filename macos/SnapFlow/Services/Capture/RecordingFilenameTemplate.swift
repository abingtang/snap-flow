import Foundation

/// 录制文件名模板：支持 date/time/counter/rand/type 等已确认令牌。
enum RecordingFilenameTemplate {
    static let defaultTemplate = "SnapFlow-rec-{date}-{time}"

    /// 将模板渲染为带扩展名的安全文件名；冲突由调用方追加序号处理。
    static func render(
        template: String,
        fileExtension: String,
        date: Date = Date(),
        counter: Int = 1,
        typeToken: String = "recording"
    ) -> String {
        let base = renderBase(
            template: template.isEmpty ? defaultTemplate : template,
            date: date,
            counter: counter,
            typeToken: typeToken
        )
        let safe = sanitize(base, fallback: "SnapFlow-rec")
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "\(safe).\(ext)"
    }

    static func renderBase(
        template: String,
        date: Date,
        counter: Int,
        typeToken: String
    ) -> String {
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            guard template[index] == "{" else {
                output.append(template[index])
                index = template.index(after: index)
                continue
            }
            let afterOpen = template.index(after: index)
            guard let close = template[afterOpen...].firstIndex(of: "}") else {
                output.append(template[index])
                index = afterOpen
                continue
            }
            let rawToken = String(template[afterOpen..<close])
            output += value(for: rawToken, date: date, counter: counter, typeToken: typeToken)
            index = template.index(after: close)
        }
        return output
    }

    static func value(
        for rawToken: String,
        date: Date,
        counter: Int,
        typeToken: String
    ) -> String {
        let pieces = rawToken.split(separator: ":", maxSplits: 1).map(String.init)
        let token = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let width = pieces.dropFirst().first.flatMap(Int.init).map { min(max($0, 1), 8) } ?? 0

        switch token {
        case "date":
            return formatted(date, "yyMMdd")
        case "time":
            return formatted(date, "HHmmss")
        case "yyyy":
            return formatted(date, "yyyy")
        case "yy":
            return formatted(date, "yy")
        case "MM":
            return formatted(date, "MM")
        case "dd":
            return formatted(date, "dd")
        case "HH":
            return formatted(date, "HH")
        case "mm":
            return formatted(date, "mm")
        case "ss":
            return formatted(date, "ss")
        case "counter":
            return padded(counter, width: width == 0 ? 0 : width)
        case "rand":
            return randomToken(length: width == 0 ? 4 : width)
        case "type":
            return typeToken
        default:
            // 未知令牌原样保留字面量，避免静默丢字。
            return token
        }
    }

    static func sanitize(_ raw: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>#&{}[]")
            .union(.controlCharacters)
            .union(.newlines)
        var output = ""
        var previousWasDash = false
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || forbidden.contains(scalar) {
                if !previousWasDash, !output.isEmpty {
                    output.append("-")
                    previousWasDash = true
                }
            } else {
                output.unicodeScalars.append(scalar)
                previousWasDash = false
            }
        }
        while output.hasPrefix("-") { output.removeFirst() }
        while output.hasSuffix("-") { output.removeLast() }
        return output.isEmpty ? fallback : output
    }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func padded(_ value: Int, width: Int) -> String {
        let text = "\(value)"
        guard width > 0, text.count < width else { return text }
        return String(repeating: "0", count: width - text.count) + text
    }

    private static func randomToken(length: Int) -> String {
        let target = min(max(length, 1), 16)
        var text = ""
        while text.count < target {
            text += UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return String(text.prefix(target))
    }
}
