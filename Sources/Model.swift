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

/// A TCP port redirect: connections to <alias>:listen go to <address>:target.
struct PortForward: Equatable, Hashable {
    var listen: Int
    var target: Int

    var text: String { "\(listen):\(target)" }

    /// Accepts "8080" (listen on 80) or "443:8443", separated by commas or spaces.
    static func parseList(_ s: String) -> (list: [PortForward], error: String?) {
        var list: [PortForward] = []
        let tokens = s.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        for tok in tokens {
            let parts = tok.split(separator: ":", omittingEmptySubsequences: false)
            let nums = parts.map { Int($0) }
            let pf: PortForward
            switch nums.count {
            case 1: guard let t = nums[0] else { return ([], "Invalid port: \(tok)") }
                pf = PortForward(listen: 80, target: t)
            case 2: guard let l = nums[0], let t = nums[1] else { return ([], "Invalid port: \(tok)") }
                pf = PortForward(listen: l, target: t)
            default: return ([], "Invalid port: \(tok)")
            }
            guard (1...65535).contains(pf.listen), (1...65535).contains(pf.target) else {
                return ([], "Ports must be between 1 and 65535")
            }
            if list.contains(where: { $0.listen == pf.listen }) {
                return ([], "Port \(pf.listen) is listed twice")
            }
            list.append(pf)
        }
        return (list, nil)
    }

    static func format(_ list: [PortForward]) -> String {
        if list.count == 1, list[0].listen == 80 { return String(list[0].target) }
        return list.map(\.text).joined(separator: ", ")
    }
}

struct HostEntry: Identifiable, Equatable {
    struct Fields: Equatable {
        var address: String
        var hosts: String
        var comment: String
        var active: Bool
        var forwards: [PortForward]
        var aliasIP: String?
    }

    var id = UUID()
    var address: String
    var hosts: String
    var comment: String
    var active: Bool

    /// Port forwarding. When non-empty, the hosts line points at `aliasIP` (a dedicated
    /// 127.0.0.x loopback address) and pf redirects its ports to `address`.
    var forwards: [PortForward] = []
    var aliasIP: String?

    /// Original text of the line, re-emitted verbatim while the entry is unchanged.
    var originalLine: String?
    var originalFields: Fields?

    init(address: String = "", hosts: String = "", comment: String = "", active: Bool = true) {
        self.address = address
        self.hosts = hosts
        self.comment = comment
        self.active = active
    }

    var fields: Fields {
        Fields(address: address, hosts: hosts, comment: comment, active: active, forwards: forwards, aliasIP: aliasIP)
    }

    var isForwarded: Bool { !forwards.isEmpty }

    /// The address written to the hosts file.
    var lineAddress: String {
        let a = address.trimmingCharacters(in: .whitespaces)
        return isForwarded ? (aliasIP ?? a) : a
    }

    /// "127.0.0.1:8080", or "127.0.0.1 (80:8080, 443:8443)" for several ports.
    var displayAddress: String {
        guard isForwarded else { return address }
        if forwards.count == 1, forwards[0].listen == 80 { return "\(address):\(forwards[0].target)" }
        return "\(address) (\(forwards.map(\.text).joined(separator: ", ")))"
    }

    var hostList: [String] {
        hosts.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var family: IPFamily? { ipFamily(address.trimmingCharacters(in: .whitespaces)) }

    var addressError: String? {
        let a = address.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return "Address is required" }
        if family == nil { return "Not a valid IPv4 or IPv6 address" }
        if isForwarded, !(family == .v4 && a.hasPrefix("127.")) {
            return "Port forwarding only works to a 127.x.x.x address"
        }
        return nil
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
        var s = (active ? "" : "# ") + lineAddress + "\t" + hostList.joined(separator: " ")
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

    // MARK: Port forwarding

    /// forwards.conf: one line per forwarded entry, `<alias> <target> <listen:target>...`.
    func renderForwards() -> String {
        let lines = entries.filter(\.isForwarded).compactMap { e -> String? in
            guard let alias = e.aliasIP else { return nil }
            return ([alias, e.address] + e.forwards.map(\.text)).joined(separator: " ")
        }
        return lines.isEmpty ? "" : "# Managed by Hosts Editor. Do not edit.\n" + lines.joined(separator: "\n") + "\n"
    }

    /// pf rdr rules for the active forwarded entries.
    func pfRules() -> String {
        var out = ""
        for e in entries where e.isForwarded && e.active {
            guard let alias = e.aliasIP else { continue }
            for f in e.forwards {
                out += "rdr pass on lo0 inet proto tcp from any to \(alias) port \(f.listen) -> \(e.address) port \(f.target)\n"
            }
        }
        return out
    }

    /// Loopback aliases that must exist on lo0.
    var activeAliases: [String] {
        entries.filter { $0.isForwarded && $0.active }.compactMap(\.aliasIP)
    }

    /// Turns entries whose hosts-file address is a known alias back into forwarded entries.
    mutating func applyForwards(conf: String) {
        var map: [String: (String, [PortForward])] = [:]
        for line in conf.split(separator: "\n") where !line.hasPrefix("#") {
            let t = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard t.count >= 3, ipFamily(t[0]) == .v4, ipFamily(t[1]) == .v4 else { continue }
            let fw = PortForward.parseList(t[2...].joined(separator: " "))
            guard fw.error == nil, !fw.list.isEmpty else { continue }
            map[t[0]] = (t[1], fw.list)
        }
        for i in entries.indices {
            guard let (target, list) = map[entries[i].address] else { continue }
            entries[i].aliasIP = entries[i].address
            entries[i].address = target
            entries[i].forwards = list
            if entries[i].originalLine != nil { entries[i].originalFields = entries[i].fields }
            map[entries[i].aliasIP!] = nil
        }
    }

    /// Gives every forwarded entry its own 127.0.0.x alias and clears it from the others.
    mutating func assignAliases() {
        var used = Set(entries.filter { !$0.isForwarded }.map { $0.address })
        used.insert("127.0.0.1")
        for i in entries.indices {
            if !entries[i].isForwarded { entries[i].aliasIP = nil; continue }
            if let a = entries[i].aliasIP, !used.contains(a) { used.insert(a) } else { entries[i].aliasIP = nil }
        }
        var next = 2
        for i in entries.indices where entries[i].isForwarded && entries[i].aliasIP == nil {
            while next < 255 && used.contains("127.0.0.\(next)") { next += 1 }
            guard next < 255 else { break }
            entries[i].aliasIP = "127.0.0.\(next)"
            used.insert("127.0.0.\(next)")
        }
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
