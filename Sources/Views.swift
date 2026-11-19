import AppKit
import Combine
import SwiftUI

enum EntryFilter: String, CaseIterable, Identifiable {
    case all = "All", active = "Active", inactive = "Inactive", duplicates = "Duplicates"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var store: HostsStore
    @State private var search = ""
    @State private var filter: EntryFilter = .all
    @State private var selection = Set<UUID>()
    @State private var editing: HostEntry?
    @State private var showHeader = false

    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let dups = store.duplicateIDs
        let rows = filteredEntries(dups)

        VStack(spacing: 0) {
            if store.externalChange { externalBanner }

            if store.doc.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Entries", systemImage: "network")
                } description: {
                    Text("Add an entry to map a host name to an IP address.")
                } actions: {
                    Button("New Entry") { editing = HostEntry() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(rows, dups: dups)
            }

            Divider()
            statusBar(dups: dups)
        }
        .navigationTitle("Hosts File Editor")
        .navigationSubtitle(store.hasEdits ? "Edited" : "/etc/hosts")
        .searchable(text: $search, placement: .toolbar, prompt: "Filter addresses, hosts, comments")
        .toolbar { toolbar }
        .sheet(item: $editing) { e in
            EntryEditor(entry: e, isNew: store.index(of: e.id) == nil) { store.upsert($0); selection = [$0.id] }
        }
        .sheet(isPresented: $showHeader) {
            HeaderEditor(text: store.doc.header) { store.doc.setHeader($0) }
        }
        .alert("Error", isPresented: Binding(get: { store.errorMessage != nil },
                                             set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onReceive(tick) { _ in store.checkExternal() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.checkExternal()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newEntry)) { _ in editing = HostEntry() }
    }

    // MARK: Table

    private func table(_ rows: [HostEntry], dups: Set<UUID>) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("On") { e in
                Toggle("", isOn: Binding(get: { e.active }, set: { store.setActive(e.id, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .width(44)

            TableColumn("Address") { e in
                HStack(spacing: 5) {
                    Text(e.displayAddress)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(e.active ? .primary : .secondary)
                        .lineLimit(1)
                        .help(e.displayAddress)
                    if e.isForwarded { forwardBadge(e) }
                }
            }
            .width(min: 130, ideal: 190)

            TableColumn("Hosts") { e in
                Text(e.displayHosts)
                    .foregroundStyle(e.active ? .primary : .secondary)
                    .lineLimit(1)
                    .help(e.hostList.joined(separator: "\n"))
            }
            .width(min: 140, ideal: 260)

            TableColumn("Comment") { e in
                Text(e.comment).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 180)

            TableColumn("") { e in
                HStack(spacing: 6) {
                    if dups.contains(e.id) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("A host in this entry is also defined in another entry")
                    }
                    pingIcon(store.ping[e.id])
                }
            }
            .width(44)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            if let id = ids.first, let e = store.entry(id) { editing = e }
        }
        .onDeleteCommand { store.delete(selection); selection = [] }
    }

    @ViewBuilder
    private func forwardBadge(_ e: HostEntry) -> some View {
        let alias = e.aliasIP ?? "a new 127.0.0.x address"
        let routes = e.forwards.map { "\(alias):\($0.listen) → \(e.address):\($0.target)" }.joined(separator: "\n")
        let saved = store.savedForwards.contains(alias + " ")
        let live = e.aliasIP.map { store.liveAliases.contains($0) } ?? false
        if !e.active || !saved || live {
            Image(systemName: "arrow.triangle.turn.up.right.circle")
                .foregroundStyle(.secondary)
                .help("Port forwarding\n" + routes + (saved ? "" : "\n(applied when you save)"))
        } else {
            Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                .foregroundStyle(.orange)
                .help("Port forwarding is saved but not active: \(alias) is not set up on lo0.\n" + routes)
        }
    }

    @ViewBuilder
    private func pingIcon(_ s: PingState?) -> some View {
        switch s {
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Ping succeeded")
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Ping failed")
        case nil: EmptyView()
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<UUID>) -> some View {
        if ids.count == 1, let id = ids.first {
            Button("Edit…") { editing = store.entry(id) }
            Button("Duplicate") { if let n = store.duplicate(id) { selection = [n] } }
            Button("Ping") { store.ping(id) }
            Divider()
            Button("Move Up") { store.move(id, by: -1) }.disabled(!store.canMove(id, by: -1))
            Button("Move Down") { store.move(id, by: 1) }.disabled(!store.canMove(id, by: 1))
            Divider()
            Button("Copy Line") { copy([id]) }
        } else if !ids.isEmpty {
            Button("Enable") { store.setActive(ids, true) }
            Button("Disable") { store.setActive(ids, false) }
            Button("Ping All") { ids.forEach(store.ping) }
            Button("Copy Lines") { copy(ids) }
        }
        if !ids.isEmpty {
            Divider()
            Button("Delete", role: .destructive) { store.delete(ids); selection.subtract(ids) }
        }
    }

    private func copy(_ ids: Set<UUID>) {
        let text = store.doc.entries.filter { ids.contains($0.id) }.map { $0.render() }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func filteredEntries(_ dups: Set<UUID>) -> [HostEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.doc.entries.filter { e in
            switch filter {
            case .all: break
            case .active: if !e.active { return false }
            case .inactive: if e.active { return false }
            case .duplicates: if !dups.contains(e.id) { return false }
            }
            if q.isEmpty { return true }
            return e.address.lowercased().contains(q) || e.hosts.lowercased().contains(q)
                || e.comment.lowercased().contains(q)
        }
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { editing = HostEntry() } label: { Label("New Entry", systemImage: "plus") }
                .help("New entry (⌘N)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(selection: $filter) {
                ForEach(EntryFilter.allCases) { Text($0.rawValue).tag($0) }
            } label: {
                Label("Filter", systemImage: filter == .all
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .pickerStyle(.menu)
            .help("Show entries")

            Button { showHeader = true } label: { Label("Additional Lines", systemImage: "text.alignleft") }
                .help("Edit the comment lines at the top of the file")

            Menu {
                Button("Reload from Disk") { store.load(); selection = [] }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(HostsStore.path, inFileViewerRootedAtPath: "")
                }
                Button("Reveal Backup in Finder") {
                    NSWorkspace.shared.selectFile(HostsStore.backupPath, inFileViewerRootedAtPath: "")
                }
                .disabled(!FileManager.default.fileExists(atPath: HostsStore.backupPath))
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private var externalBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            Text("The hosts file was changed by another app.")
            Spacer()
            Button("Keep My Changes") { store.externalChange = false }
            Button("Reload") { store.load(); selection = [] }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.18))
    }

    private func statusBar(dups: Set<UUID>) -> some View {
        let total = store.doc.entries.count
        let active = store.doc.entries.filter(\.active).count
        return HStack(spacing: 12) {
            Text("\(total) entries · \(active) active")
            if !dups.isEmpty {
                Button {
                    filter = .duplicates
                } label: {
                    Label("\(dups.count) with duplicates", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if store.isDirty {
                Text(store.hasEdits ? "Unsaved changes" : "Port forwarding not active")
                    .foregroundStyle(store.hasEdits ? Color.secondary : Color.orange)
                Button("Revert") { store.load(); selection = [] }
                Button("Save") { store.save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
            } else if let t = store.lastSaved {
                Text("Saved \(t.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// MARK: - Entry editor

struct EntryEditor: View {
    /// One "host port → service port" row, kept as text while editing.
    struct PortPair: Identifiable {
        let id = UUID()
        var service = ""
        var host = ""
    }

    @State var entry: HostEntry
    let isNew: Bool
    let onSave: (HostEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pairs: [PortPair]

    init(entry: HostEntry, isNew: Bool, onSave: @escaping (HostEntry) -> Void) {
        _entry = State(initialValue: entry)
        let p = entry.forwards.map { PortPair(service: String($0.target), host: $0.listen == 80 ? "" : String($0.listen)) }
        _pairs = State(initialValue: p.isEmpty ? [PortPair()] : p)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var parsed: (list: [PortForward], error: String?) {
        var list: [PortForward] = []
        for p in pairs {
            let s = p.service.trimmingCharacters(in: .whitespaces)
            let h = p.host.trimmingCharacters(in: .whitespaces)
            if s.isEmpty && h.isEmpty { continue }
            // Either side may be left empty; it then means port 80.
            let target: Int
            if s.isEmpty { target = 80 } else {
                guard let t = Int(s), (1...65535).contains(t) else { return ([], "Invalid port: \(s)") }
                target = t
            }
            let listen: Int
            if h.isEmpty { listen = 80 } else {
                guard let l = Int(h), (1...65535).contains(l) else { return ([], "Invalid host port: \(h)") }
                listen = l
            }
            if list.contains(where: { $0.listen == listen }) { return ([], "Host port \(listen) is used twice") }
            list.append(PortForward(listen: listen, target: target))
        }
        return (list, nil)
    }

    /// The entry as it would be saved.
    private var candidate: HostEntry {
        var e = entry
        e.forwards = parsed.list
        return e
    }

    private var forwarding: Bool {
        pairs.count > 1 || pairs.contains {
            !$0.service.trimmingCharacters(in: .whitespaces).isEmpty || !$0.host.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        let c = candidate
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Entry" : "Edit Entry")
                .font(.headline)
                .padding([.top, .horizontal], 20)

            Form {
                Section {
                    TextField(text: $entry.address, prompt: Text(verbatim: "Required")) { Text("Address") }
                    validation(c.addressError, value: entry.address,
                               hint: "Where the service runs, e.g. 127.0.0.1 or ::1")

                    TextField(text: $pairs[0].service, prompt: Text(verbatim: forwarding ? "80" : "Optional")) { Text("Port") }

                    TextField(text: $entry.hosts, prompt: Text(verbatim: "Required")) { Text("Hosts") }
                    validation(c.hostsError, value: entry.hosts,
                               hint: "Separate multiple hosts with spaces, e.g. myapp.test api.myapp.test")

                    TextField(text: $pairs[0].host, prompt: Text(verbatim: forwarding ? "80" : "Optional")) { Text("Host port") }
                    if !forwarding {
                        Text("Port is where the service listens, Host port is what you use with the domain. Either one defaults to 80. Leave both empty for a plain hosts entry.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if forwarding {
                        ForEach($pairs) { $p in
                            if p.id != pairs.first?.id {
                                LabeledContent("Also forward") {
                                    HStack(spacing: 6) {
                                        TextField("Host port", text: $p.host, prompt: Text(verbatim: "host port"))
                                            .labelsHidden().frame(width: 80)
                                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                        TextField("Port", text: $p.service, prompt: Text(verbatim: "port"))
                                            .labelsHidden().frame(width: 80)
                                        Button {
                                            pairs.removeAll { $0.id == p.id }
                                        } label: {
                                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove")
                                    }
                                    .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                        portSummary(c)
                        Button("Add Another Port") { pairs.append(PortPair()) }
                            .buttonStyle(.link)
                    }

                    TextField(text: $entry.comment, prompt: Text(verbatim: "Optional")) { Text("Comment") }
                    validation(c.commentError, value: entry.comment)

                    Toggle("Active", isOn: $entry.active)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true) // grow the sheet as port rows are added

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    onSave(candidate)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!c.isValid || parsed.error != nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
    }

    /// "http://myapp.test → 127.0.0.1:8080" lines, the port error, and browser warnings.
    @ViewBuilder
    private func portSummary(_ c: HostEntry) -> some View {
        if let err = parsed.error {
            Text(err).font(.caption).foregroundStyle(.red)
        } else {
            let host = c.hostList.first ?? "myapp.test"
            let addr = c.address.trimmingCharacters(in: .whitespaces).isEmpty ? "127.0.0.1" : c.address
            VStack(alignment: .leading, spacing: 3) {
                ForEach(c.forwards, id: \.listen) { f in
                    Text(verbatim: (f.listen == 80 ? "http://\(host)" : "\(host):\(f.listen)") + "  →  \(addr):\(f.target)")
                }
                let blocked = c.forwards.map(\.listen).filter(browserBlockedPorts.contains)
                if !blocked.isEmpty {
                    Text("Browsers refuse port \(blocked.map(String.init).joined(separator: ", ")) (ERR_UNSAFE_PORT). curl and other clients work; pick another host port for browser use.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func validation(_ error: String?, value: String, hint: String? = nil) -> some View {
        // Empty fields only show the hint; the Add button stays disabled until they're valid.
        if let error, !value.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(error).font(.caption).foregroundStyle(.red)
        } else if let hint {
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Ports Chrome, Safari and Firefox refuse to connect to.
let browserBlockedPorts: Set<Int> = [
    1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77, 79, 87, 95, 101, 102, 103,
    104, 109, 110, 111, 113, 115, 117, 119, 123, 135, 137, 139, 143, 161, 179, 389, 427, 465, 512, 513,
    514, 515, 526, 530, 531, 532, 540, 548, 554, 556, 563, 587, 601, 636, 989, 990, 993, 995, 1719, 1720,
    1723, 2049, 3659, 4045, 5060, 5061, 6000, 6566, 6665, 6666, 6667, 6668, 6669, 6697, 10080,
]

// MARK: - Additional lines editor

struct HeaderEditor: View {
    @State var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Additional Lines").font(.headline)
            Text("Lines kept at the top of the hosts file, above the first entry. Start comments with #.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { onSave(text); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 380)
    }
}

extension Notification.Name {
    static let newEntry = Notification.Name("HostsEditor.newEntry")
}
