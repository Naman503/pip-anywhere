import Foundation

/// Converts Adblock Plus–style filter lists (EasyList, EasyPrivacy) into WebKit
/// content-blocker rules (the JSON `WKContentRuleListStore` compiles). Only what WebKit
/// can express is converted; everything else is skipped rather than risked, because one
/// invalid rule can make a whole list fail to compile.
public enum ContentBlocker {
    public struct Result {
        public var network: [[String: Any]] = []
        public var cosmetic: [[String: Any]] = []
        public var skipped = 0

        public func json(_ rules: [[String: Any]]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// WebKit's per-list maximum.
    public static let maxRules = 150_000
    /// Generic hiding selectors are grouped; a bad selector only loses its own small group.
    static let selectorsPerRule = 40

    public static func convert(_ lists: [String]) -> Result {
        var result = Result()
        var blocks: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        var genericSelectors: [String] = []
        var domainSelectors: [String: [String]] = [:] // selector -> domains

        for list in lists {
            for raw in list.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
                if let rule = cosmetic(line) {
                    if rule.domains.isEmpty { genericSelectors.append(rule.selector) } else {
                        domainSelectors[rule.selector, default: []].append(contentsOf: rule.domains)
                    }
                } else if line.contains("#") && (line.contains("##") || line.contains("#@#") || line.contains("#?#") || line.contains("#$#") || line.contains("#%#")) {
                    result.skipped += 1
                } else if let rule = network(line) {
                    if rule.exception { exceptions.append(rule.json) } else { blocks.append(rule.json) }
                } else {
                    result.skipped += 1
                }
            }
        }

        // Exceptions must come after the rules they override.
        result.network = Array((blocks + exceptions).prefix(maxRules))

        for chunk in stride(from: 0, to: genericSelectors.count, by: selectorsPerRule) {
            let selectors = genericSelectors[chunk..<min(chunk + selectorsPerRule, genericSelectors.count)]
            result.cosmetic.append([
                "trigger": ["url-filter": ".*"],
                "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")],
            ])
        }
        for (selector, domains) in domainSelectors.sorted(by: { $0.key < $1.key }) {
            result.cosmetic.append([
                "trigger": ["url-filter": ".*", "if-domain": domains.map { "*" + $0 }],
                "action": ["type": "css-display-none", "selector": selector],
            ])
        }
        result.cosmetic = Array(result.cosmetic.prefix(maxRules))
        return result
    }

    // MARK: Element hiding ("example.com##.ad", "##.banner")

    struct Cosmetic {
        var domains: [String]
        var selector: String
    }

    /// Pseudo-classes only ad blockers understand (procedural filters): WebKit would reject them.
    static let unsupportedSelectorParts = [
        ":-abp-", ":has-text(", ":contains(", ":matches-css", ":xpath(", ":upward(", ":remove(", ":style(",
        ":nth-ancestor(", ":watch-attr(", ":min-text-length(", ":matches-path(", ":matches-attr(", ":matches-prop",
        ":if(", ":if-not(", ":others(", "[-ext-", ":-ext-", ":remove-attr(", ":remove-class(",
    ]

    static func cosmetic(_ line: String) -> Cosmetic? {
        guard let range = line.range(of: "##"), !line.contains("#@#") else { return nil }
        let domainPart = String(line[..<range.lowerBound])
        let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty, !selector.hasPrefix("+js("), !selector.hasPrefix("^"),
              selector.unicodeScalars.allSatisfy(\.isASCII),
              !unsupportedSelectorParts.contains(where: selector.contains) else { return nil }
        let domains = domainPart.split(separator: ",").map(String.init).filter { !$0.hasPrefix("~") && !$0.isEmpty }
        // "~example.com##sel" (everywhere except) can't be expressed together with a selector list; skip.
        if !domainPart.isEmpty && domains.isEmpty { return nil }
        guard domains.allSatisfy(isPlainDomain) else { return nil }
        return Cosmetic(domains: domains.map { $0.lowercased() }, selector: selector)
    }

    // MARK: Network rules ("||ads.example.com^$third-party")

    struct Network {
        var exception: Bool
        var json: [String: Any]
    }

    static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet", "font": "font",
        "media": "media", "xmlhttprequest": "fetch", "xhr": "fetch", "subdocument": "document", "frame": "document",
        "ping": "ping", "websocket": "websocket", "other": "other", "popup": "popup",
    ]

    /// Options that change what a rule does in ways WebKit can't do: drop those rules.
    static let unsupportedOptions: Set<String> = [
        "csp", "redirect", "redirect-rule", "removeparam", "rewrite", "replace", "badfilter", "document", "doc",
        "elemhide", "ehide", "generichide", "ghide", "specifichide", "shide", "genericblock", "denyallow", "header",
        "permissions", "to", "method", "urltransform", "uritransform", "jsonprune", "cookie", "hls", "empty", "mp4",
        "webrtc", "object", "object-subrequest", "inline-script", "inline-font", "content", "strict1p", "strict3p",
    ]

    static func network(_ line: String) -> Network? {
        var text = line
        let exception = text.hasPrefix("@@")
        if exception { text.removeFirst(2) }

        var options: [String] = []
        // Options follow the last "$", unless that "$" is part of a path.
        if let dollar = text.lastIndex(of: "$"), !text[text.index(after: dollar)...].contains("/") {
            options = text[text.index(after: dollar)...].split(separator: ",").map { String($0).lowercased() }
            text = String(text[..<dollar])
        }
        // Regular-expression filters: WebKit's url-filter dialect is too limited.
        if text.hasPrefix("/") && text.hasSuffix("/") && text.count > 1 { return nil }
        guard text.unicodeScalars.allSatisfy(\.isASCII) else { return nil }

        var trigger: [String: Any] = [:]
        var types: [String] = []
        var loadType: String?
        var frameOnly = false
        for option in options {
            let (name, value) = option.split(separator: "=", maxSplits: 1).map(String.init).splitPair
            let negated = name.hasPrefix("~")
            let key = negated ? String(name.dropFirst()) : name
            if unsupportedOptions.contains(key) { return nil }
            switch key {
            case "third-party", "3p": loadType = negated ? "first-party" : "third-party"
            case "first-party", "1p": loadType = negated ? "third-party" : "first-party"
            case "match-case": trigger["url-filter-is-case-sensitive"] = true
            case "important", "all": break
            case "domain", "from":
                let domains = (value ?? "").split(separator: "|").map(String.init)
                let include = domains.filter { !$0.hasPrefix("~") }
                let exclude = domains.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }
                guard (include + exclude).allSatisfy(isPlainDomain) else { return nil }
                if !include.isEmpty { trigger["if-domain"] = include.map { "*" + $0.lowercased() } }
                else if !exclude.isEmpty { trigger["unless-domain"] = exclude.map { "*" + $0.lowercased() } }
            default:
                guard let type = resourceTypes[key] else { return nil } // unknown option: don't guess
                if negated { return nil } // "everything except images" isn't expressible simply
                types.append(type)
                if key == "subdocument" || key == "frame" { frameOnly = true }
            }
        }

        guard let filter = urlFilter(text) else { return nil }
        trigger["url-filter"] = filter
        if !types.isEmpty { trigger["resource-type"] = Array(Set(types)).sorted() }
        if let loadType { trigger["load-type"] = [loadType] }
        if frameOnly { trigger["load-context"] = ["child-frame"] }
        return Network(exception: exception, json: [
            "trigger": trigger,
            "action": ["type": exception ? "ignore-previous-rules" : "block"],
        ])
    }

    /// "||ads.example.com^" → a WebKit url-filter regular expression.
    static func urlFilter(_ pattern: String) -> String? {
        var p = pattern
        var prefix = ""
        var suffix = ""
        if p.hasPrefix("||") {
            p.removeFirst(2)
            prefix = "^[^:]+://+([^:/]+\\.)?"
        } else if p.hasPrefix("|") {
            p.removeFirst()
            prefix = "^"
        }
        if p.hasSuffix("|") {
            p.removeLast()
            suffix = "$"
        }
        // A bare pattern without any anchor that is too short would block half the web.
        if p.isEmpty { return prefix.isEmpty ? ".*" : nil }
        var out = ""
        for ch in p {
            switch ch {
            case "*": out += ".*"
            case "^": out += "[/:?=&]"
            case ".", "+", "?", "$", "{", "}", "(", ")", "[", "]", "\\", "|": out += "\\" + String(ch)
            default: out.append(ch)
            }
        }
        if prefix.isEmpty && out.count < 4 { return nil }
        // A trailing separator also matches the end of the address.
        if out.hasSuffix("[/:?=&]") && suffix.isEmpty {
            out = String(out.dropLast("[/:?=&]".count)) + "([/:?=&].*)?$"
            return prefix + out
        }
        return prefix + out + suffix
    }

    static func isPlainDomain(_ domain: String) -> Bool {
        !domain.isEmpty && domain.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") }
    }
}

private extension Array where Element == String {
    var splitPair: (String, String?) { (first ?? "", count > 1 ? self[1] : nil) }
}
