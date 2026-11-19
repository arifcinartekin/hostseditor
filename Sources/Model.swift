import Foundation
import Darwin

enum IPFamily { case v4, v6 }

func ipFamily(_ raw: String) -> IPFamily? {
    var s = raw
    if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) } // fe80::1%lo0
    var a4 = in_addr()
    var a6 = in6_addr()
    if inet_pton(AF_INET, s, &a4) == 1 { return .v4 }
    if inet_pton(AF_INET6, s, &a6) == 1 { return .v6 }
    return nil
}

private let hostnameRegex = try! NSRegularExpression(
    pattern: #"^[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?(\.[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?)*\.?$"#
)

func isValidHostname(_ h: String) -> Bool {
    guard !h.isEmpty, h.count <= 253 else { return false }
    let range = NSRange(h.startIndex..., in: h)
    return hostnameRegex.firstMatch(in: h, range: range) != nil
}

struct HostEntry: Identifiable, Equatable {
    struct Fields: Equatable {
        var address: String
        var hosts: String
        var comment: String
        var active: Bool
    }

    var id = UUID()
    var address: String
    var hosts: String
    var comment: String
    var active: Bool

    /// Original text of the line, re-emitted verbatim while the entry is unchanged.
    var originalLine: String?
    var originalFields: Fields?

    init(address: String = "", hosts: String = "", comment: String = "", active: Bool = true) {
        self.address = address
        self.hosts = hosts
        self.comment = comment
        self.active = active
    }

    var fields: Fields { Fields(address: address, hosts: hosts, comment: comment, active: active) }

    var hostList: [String] {
        hosts.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var family: IPFamily? { ipFamily(address.trimmingCharacters(in: .whitespaces)) }

    var addressError: String? {
        let a = address.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return "Address is required" }
        return family == nil ? "Not a valid IPv4 or IPv6 address" : nil
    }

    var hostsError: String? {
        let list = hostList
        if list.isEmpty { return "At least one host is required" }
        if let bad = list.first(where: { !isValidHostname($0) }) { return "Invalid host name: \(bad)" }
        return nil
    }

    var commentError: String? {
        comment.contains(where: \.isNewline) ? "Comment must be a single line" : nil
    }

    var isValid: Bool { addressError == nil && hostsError == nil && commentError == nil }

    func render() -> String {
        if let line = originalLine, originalFields == fields { return line }
        var s = (active ? "" : "# ") + address.trimmingCharacters(in: .whitespaces) + "\t" + hostList.joined(separator: " ")
        let c = comment.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty { s += "\t# " + c }
        return s
    }

    static func parse(_ line: String) -> HostEntry? {
        var t = Substring(line).drop(while: \.isWhitespace)
        var active = true
        if t.hasPrefix("#") {
            active = false
            t = t.drop(while: { $0 == "#" }).drop(while: \.isWhitespace)
        }
        var comment = ""
        if let hash = t.firstIndex(of: "#") {
            comment = t[t.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            t = t[..<hash]
        }
        let tokens = t.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 2, ipFamily(tokens[0]) != nil else { return nil }
        let hosts = Array(tokens.dropFirst())
        guard hosts.allSatisfy(isValidHostname) else { return nil }

        var e = HostEntry(address: tokens[0], hosts: hosts.joined(separator: " "), comment: comment, active: active)
        e.originalLine = line
        e.originalFields = e.fields
        return e
    }
}

/// The hosts file as an ordered list of lines. Non-entry lines (comments, blanks)
/// keep their position; entry slots are filled in order from `entries`.
struct HostsDocument {
    enum Line: Equatable { case raw(String), entry }

    var lines: [Line] = []
    var entries: [HostEntry] = []

    static func parse(_ text: String) -> HostsDocument {
        var doc = HostsDocument()
        var rawLines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if rawLines.last == "" { rawLines.removeLast() }
        for l in rawLines {
            if let e = HostEntry.parse(l) {
                doc.lines.append(.entry)
                doc.entries.append(e)
            } else {
                doc.lines.append(.raw(l))
            }
        }
        return doc
    }

    func render() -> String {
        var out: [String] = []
        var it = entries.makeIterator()
        for line in lines {
            switch line {
            case .raw(let s): out.append(s)
            case .entry: if let e = it.next() { out.append(e.render()) }
            }
        }
        while let e = it.next() { out.append(e.render()) }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    private var firstEntrySlot: Int { lines.firstIndex(of: .entry) ?? lines.count }

    /// Comment/blank lines above the first entry ("Additional lines" in PowerToys).
    var header: String {
        lines[..<firstEntrySlot].compactMap { if case .raw(let s) = $0 { return s } else { return nil } }
            .joined(separator: "\n")
    }

    mutating func setHeader(_ text: String) {
        var newLines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if newLines.last == "" { newLines.removeLast() }
        lines.replaceSubrange(..<firstEntrySlot, with: newLines.map { .raw($0) })
    }

    mutating func append(_ e: HostEntry) {
        let slots = lines.filter { $0 == .entry }.count
        if slots < entries.count + 1 { lines.append(.entry) }
        entries.append(e)
    }

    mutating func insert(_ e: HostEntry, after index: Int) {
        let slotIdx = slotLineIndex(for: index)
        lines.insert(.entry, at: (slotIdx ?? lines.count - 1) + 1)
        entries.insert(e, at: index + 1)
    }

    mutating func remove(at index: Int) {
        if let s = slotLineIndex(for: index) { lines.remove(at: s) }
        entries.remove(at: index)
    }

    private func slotLineIndex(for entryIndex: Int) -> Int? {
        var n = -1
        for (i, l) in lines.enumerated() where l == .entry {
            n += 1
            if n == entryIndex { return i }
        }
        return nil
    }
}
