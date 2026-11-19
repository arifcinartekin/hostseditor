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
        .navigationSubtitle(store.isDirty ? "Edited" : "/etc/hosts")
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
                Text(e.address)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(e.active ? .primary : .secondary)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Hosts") { e in
                Text(e.hostList.joined(separator: "  "))
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
                Text("Unsaved changes").foregroundStyle(.secondary)
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
    @State var entry: HostEntry
    let isNew: Bool
    let onSave: (HostEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Entry" : "Edit Entry")
                .font(.headline)
                .padding([.top, .horizontal], 20)

            Form {
                Section {
                    // Text(verbatim:) keeps SwiftUI from parsing the prompt as Markdown,
                    // which turned "www.example.test" into a link.
                    TextField(text: $entry.address, prompt: Text(verbatim: "Required")) { Text("Address") }
                    validation(entry.addressError, value: entry.address,
                               hint: "IPv4 or IPv6, e.g. 127.0.0.1 or ::1")

                    TextField(text: $entry.hosts, prompt: Text(verbatim: "Required")) { Text("Hosts") }
                    validation(entry.hostsError, value: entry.hosts,
                               hint: "Separate multiple hosts with spaces, e.g. myapp.test api.myapp.test")

                    TextField(text: $entry.comment, prompt: Text(verbatim: "Optional")) { Text("Comment") }
                    validation(entry.commentError, value: entry.comment)

                    Toggle("Active", isOn: $entry.active)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    onSave(entry)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!entry.isValid)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
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
