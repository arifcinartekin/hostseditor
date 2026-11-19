import AppKit
import Foundation

enum PingState { case running, ok, failed }

@MainActor
final class HostsStore: ObservableObject {
    static let shared = HostsStore()
    nonisolated static let path = "/private/etc/hosts"
    nonisolated static let backupPath = "/private/etc/hosts.hostseditor.bak"
    nonisolated static let forwardDir = "/Library/Application Support/HostsEditor"
    nonisolated static let forwardConf = forwardDir + "/forwards.conf"
    nonisolated static let daemonLabel = "local.hostseditor.forwarding"
    nonisolated static let daemonPlist = "/Library/LaunchDaemons/\(daemonLabel).plist"

    @Published var doc = HostsDocument()
    @Published private(set) var savedText = ""
    @Published private(set) var savedForwards = ""
    /// 127.x addresses currently configured on lo0.
    @Published private(set) var liveAliases: Set<String> = []
    @Published var externalChange = false
    @Published var errorMessage: String?
    @Published var ping: [UUID: PingState] = [:]
    @Published var lastSaved: Date?

    private var backedUpThisSession = false

    init() { load() }

    var hasEdits: Bool { doc.render() != savedText || doc.renderForwards() != savedForwards }

    /// Forwarding is saved but some of its loopback aliases aren't on lo0 (e.g. after pf was reset).
    var forwardingInactive: Bool {
        !savedForwards.isEmpty && !Set(doc.activeAliases).isSubset(of: liveAliases)
    }

    var isDirty: Bool { hasEdits || forwardingInactive }

    // MARK: File I/O

    private func readFile() -> String? {
        try? String(contentsOfFile: Self.path, encoding: .utf8)
    }

    func load() {
        guard let text = readFile() else {
            errorMessage = "Could not read \(Self.path)"
            return
        }
        let conf = (try? String(contentsOfFile: Self.forwardConf, encoding: .utf8)) ?? ""
        var d = HostsDocument.parse(text)
        d.applyForwards(conf: conf)
        doc = d
        savedText = text
        savedForwards = d.renderForwards()
        refreshLiveAliases()
        externalChange = false
        ping = [:]
    }

    /// Called periodically and when the app becomes active.
    func checkExternal() {
        if !savedForwards.isEmpty { refreshLiveAliases() }
        guard let text = readFile(), text != savedText else { return }
        if isDirty { externalChange = true } else { load() }
    }

    @discardableResult
    func save() -> Bool {
        doc.assignAliases()
        let text = doc.render()
        let conf = doc.renderForwards()
        refreshLiveAliases()
        let forwardingChanged = conf != savedForwards
            || FileManager.default.fileExists(atPath: Self.forwardDir) != !conf.isEmpty
            || !Set(doc.activeAliases).isSubset(of: liveAliases) // re-apply if an alias went missing

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hostseditor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
            if forwardingChanged {
                try conf.write(to: dir.appendingPathComponent("forwards.conf"), atomically: true, encoding: .utf8)
                try doc.pfRules().write(to: dir.appendingPathComponent("pf.rules"), atomically: true, encoding: .utf8)
                let aliases = doc.activeAliases.map { $0 + "\n" }.joined()
                try aliases.write(to: dir.appendingPathComponent("aliases"), atomically: true, encoding: .utf8)
                try Forwarding.applyScript.write(to: dir.appendingPathComponent("apply.sh"), atomically: true, encoding: .utf8)
                try Forwarding.daemonPlist.write(to: dir.appendingPathComponent("daemon.plist"), atomically: true, encoding: .utf8)
            }
            let script = rootScript(tmp: dir.path, forwarding: forwardingChanged, enable: !conf.isEmpty)
            try script.write(to: dir.appendingPathComponent("save.sh"), atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Could not write temporary files: \(error.localizedDescription)"
            return false
        }

        let cmd = "/bin/sh \(shq(dir.path + "/save.sh"))"
        let source = "do shell script \"\(asq(cmd))\" with prompt \"Hosts Editor wants to save changes to /etc/hosts.\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int
            if code != -128 { // -128 = user cancelled
                errorMessage = (err[NSAppleScript.errorMessage] as? String) ?? "Saving failed."
            }
            return false
        }
        backedUpThisSession = true
        savedText = readFile() ?? text
        savedForwards = conf
        externalChange = false
        lastSaved = Date()
        refreshLiveAliases()
        return true
    }

    /// The script run as root. `tmp` holds the files prepared above.
    func rootScript(tmp: String, forwarding: Bool, enable: Bool) -> String {
        let t = shq(tmp), d = shq(Self.forwardDir), plist = shq(Self.daemonPlist)
        var s = "set -e\n"
        if !backedUpThisSession { s += "/bin/cp -p \(shq(Self.path)) \(shq(Self.backupPath))\n" }
        // `cat >` keeps the file's owner, mode and inode intact.
        s += "/bin/cat \(t)/hosts > \(shq(Self.path))\n"
        if forwarding && enable {
            s += """
            /bin/mkdir -p \(d)
            for f in forwards.conf pf.rules aliases apply.sh; do /bin/cp \(t)/$f \(d)/$f; done
            /usr/sbin/chown -R root:wheel \(d)
            /bin/chmod 644 \(d)/forwards.conf \(d)/pf.rules \(d)/aliases
            /bin/chmod 755 \(d)/apply.sh
            /bin/cp \(t)/daemon.plist \(plist)
            /usr/sbin/chown root:wheel \(plist)
            /bin/chmod 644 \(plist)
            /bin/sh \(d)/apply.sh

            """
        } else if forwarding {
            // Last forward removed: undo the aliases and rules, then remove everything.
            s += """
            if [ -d \(d) ]; then
              : > \(d)/pf.rules; : > \(d)/aliases
              /bin/sh \(d)/apply.sh || true
              /bin/rm -rf \(d)
            fi
            /bin/rm -f \(plist)

            """
        }
        s += "/usr/bin/dscacheutil -flushcache\n/usr/bin/killall -HUP mDNSResponder 2>/dev/null || true\n"
        return s
    }

    func refreshLiveAliases() {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        p.arguments = ["lo0"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        liveAliases = Set(out.split(separator: "\n").compactMap { line -> String? in
            let t = line.split(whereSeparator: \.isWhitespace)
            return t.count >= 2 && t[0] == "inet" ? String(t[1]) : nil
        })
    }

    private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func asq(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Editing

    func index(of id: UUID) -> Int? { doc.entries.firstIndex { $0.id == id } }

    func entry(_ id: UUID) -> HostEntry? { index(of: id).map { doc.entries[$0] } }

    func upsert(_ e: HostEntry) {
        var e = e
        e.address = e.address.trimmingCharacters(in: .whitespaces)
        e.hosts = e.hostList.joined(separator: " ")
        e.comment = e.comment.trimmingCharacters(in: .whitespaces)
        if let i = index(of: e.id) {
            if doc.entries[i].fields != e.fields { ping[e.id] = nil }
            doc.entries[i] = e
        } else {
            doc.append(e)
        }
        doc.assignAliases()
    }

    func setActive(_ id: UUID, _ on: Bool) {
        if let i = index(of: id) { doc.entries[i].active = on }
    }

    func setActive(_ ids: Set<UUID>, _ on: Bool) {
        for id in ids { setActive(id, on) }
    }

    func delete(_ ids: Set<UUID>) {
        for i in doc.entries.indices.reversed() where ids.contains(doc.entries[i].id) {
            doc.remove(at: i)
        }
        for id in ids { ping[id] = nil }
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard let i = index(of: id) else { return nil }
        var copy = HostEntry(address: doc.entries[i].address, hosts: doc.entries[i].hosts,
                             comment: doc.entries[i].comment, active: false)
        copy.forwards = doc.entries[i].forwards
        doc.insert(copy, after: i)
        doc.assignAliases()
        return copy.id
    }

    func move(_ id: UUID, by delta: Int) {
        guard let i = index(of: id) else { return }
        let j = i + delta
        guard doc.entries.indices.contains(j) else { return }
        doc.entries.swapAt(i, j)
    }

    func canMove(_ id: UUID, by delta: Int) -> Bool {
        guard let i = index(of: id) else { return false }
        return doc.entries.indices.contains(i + delta)
    }

    // MARK: Analysis

    /// Entries whose host name also appears in another entry of the same address family.
    var duplicateIDs: Set<UUID> {
        var seen: [String: [UUID]] = [:]
        for e in doc.entries {
            let fam = e.family == .v6 ? "6" : "4"
            for h in Set(e.hostList.map { $0.lowercased() }) {
                seen[fam + ":" + h, default: []].append(e.id)
            }
        }
        return Set(seen.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    // MARK: Ping

    func ping(_ id: UUID) {
        guard let e = entry(id) else { return }
        ping[id] = .running
        let addr = e.address
        let v6 = e.family == .v6
        Task.detached {
            let ok = await Self.runPing(addr, v6: v6)
            await MainActor.run { self.ping[id] = ok ? .ok : .failed }
        }
    }

    nonisolated private static func runPing(_ address: String, v6: Bool) async -> Bool {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: v6 ? "/sbin/ping6" : "/sbin/ping")
            p.arguments = v6 ? ["-c", "1", address] : ["-c", "1", "-W", "2000", address]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus == 0) }
            do {
                try p.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if p.isRunning { p.terminate() }
                }
            } catch {
                cont.resume(returning: false)
            }
        }
    }
}
