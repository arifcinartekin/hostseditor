import AppKit
import Foundation

enum PingState { case running, ok, failed }

@MainActor
final class HostsStore: ObservableObject {
    static let shared = HostsStore()
    static let path = "/private/etc/hosts"
    static let backupPath = "/private/etc/hosts.hostseditor.bak"

    @Published var doc = HostsDocument()
    @Published private(set) var savedText = ""
    @Published var externalChange = false
    @Published var errorMessage: String?
    @Published var ping: [UUID: PingState] = [:]
    @Published var lastSaved: Date?

    private var backedUpThisSession = false

    init() { load() }

    var isDirty: Bool { doc.render() != savedText }

    // MARK: File I/O

    private func readFile() -> String? {
        try? String(contentsOfFile: Self.path, encoding: .utf8)
    }

    func load() {
        guard let text = readFile() else {
            errorMessage = "Could not read \(Self.path)"
            return
        }
        doc = HostsDocument.parse(text)
        savedText = text
        externalChange = false
        ping = [:]
    }

    /// Called periodically and when the app becomes active.
    func checkExternal() {
        guard let text = readFile(), text != savedText else { return }
        if isDirty { externalChange = true } else { load() }
    }

    @discardableResult
    func save() -> Bool {
        let text = doc.render()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosts-\(UUID().uuidString).txt")
        do {
            try text.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Could not write temporary file: \(error.localizedDescription)"
            return false
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        var steps: [String] = []
        if !backedUpThisSession {
            steps.append("/bin/cp -p \(shq(Self.path)) \(shq(Self.backupPath))")
        }
        // `cat >` keeps the file's owner, mode and inode intact.
        steps.append("/bin/cat \(shq(tmp.path)) > \(shq(Self.path))")
        let cmd = steps.joined(separator: " && ")
            + "; rc=$?; /usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder 2>/dev/null; exit $rc"

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
        externalChange = false
        lastSaved = Date()
        return true
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
        copy.id = UUID()
        doc.insert(copy, after: i)
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
