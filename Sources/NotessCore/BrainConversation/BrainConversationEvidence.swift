import Foundation

/// Supporting links in an answer, not Citations (which belong to Brain Notes).
/// Parsing reuses the editor's Markdown rules, so examples inside code are inert.
public enum BrainConversationEvidence {
    public struct Source: Identifiable, Equatable, Sendable {
        public let label: String
        public let url: URL
        public var id: URL { url }
    }

    public static func sources(in answer: String) -> [Source] {
        let text = answer as NSString
        let notes = WikiLink.links(in: answer).map { link in
            (link.range.location, Source(
                label: text.substring(with: link.range),
                url: noteURL(target: link.target, section: link.section)
            ))
        }
        let web = WebLink.links(in: answer).map { link in
            (link.range.location, Source(label: text.substring(with: link.range), url: link.url))
        }
        var seen = Set<URL>()
        return (notes + web).sorted { $0.0 < $1.0 }.compactMap { _, source in
            seen.insert(source.url).inserted ? source : nil
        }
    }

    /// Converts wiki-links into native Markdown links without changing code spans.
    public static func markdown(_ answer: String) -> String {
        let result = NSMutableString(string: answer)
        for link in WikiLink.links(in: answer).reversed() {
            let label = (answer as NSString).substring(with: link.range)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            let url = noteURL(target: link.target, section: link.section)
            result.replaceCharacters(in: link.range, with: "[\(label)](\(url.absoluteString))")
        }
        return result as String
    }

    public static func noteURL(target: String, section: String?) -> URL {
        var components = URLComponents()
        components.scheme = "notess-source"
        components.host = "note"
        components.queryItems = [URLQueryItem(name: "target", value: target)]
        if let section { components.queryItems?.append(URLQueryItem(name: "section", value: section)) }
        // Parentheses are legal in URL queries, but delimit native Markdown links.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        return components.url!
    }

    /// Only this private link format can navigate notes; no file or command URLs.
    public static func noteLink(from url: URL) -> WikiLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "notess-source", components.host == "note",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems,
              items.allSatisfy({ $0.name == "target" || $0.name == "section" }),
              items.filter({ $0.name == "target" }).count == 1,
              items.filter({ $0.name == "section" }).count <= 1,
              let target = items.first(where: { $0.name == "target" })?.value,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !target.hasPrefix("/"), !target.contains("\\"),
              !target.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return WikiLink(
            target: target,
            section: items.first(where: { $0.name == "section" })?.value,
            range: NSRange(location: 0, length: 0)
        )
    }

    public static func isWebURL(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "")
            && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
    }
}
