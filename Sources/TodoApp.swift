import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Model

/// A user-editable tab. `id` is stable; `name` can be renamed in Preferences.
/// The original three tabs use their names as ids, so older saved todos
/// (which stored "Work" / "Life" / "Threads") still land in the right place.
struct TodoTab: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String

    static let defaults = ["Work", "Life", "Threads"].map { TodoTab(id: $0, name: $0) }
    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : name }
}

struct TodoItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    /// The `TodoTab.id` this todo belongs to.
    var tab: String
    /// A horizontal-line separator (created by entering "---") rather than a todo.
    var isDivider = false

    init(title: String, tab: String, isDivider: Bool = false) {
        self.title = title
        self.tab = tab
        self.isDivider = isDivider
    }

    // Tolerates older saved formats (no `tab` / `isDivider` fields).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        tab = try c.decodeIfPresent(String.self, forKey: .tab) ?? ""
        isDivider = try c.decodeIfPresent(Bool.self, forKey: .isDivider) ?? false
    }
}

@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = [] {
        didSet { save(items, to: "todos.json") }
    }
    @Published var tabs: [TodoTab] = TodoTab.defaults {
        didSet { save(tabs, to: "tabs.json") }
    }

    private let dir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuBarTodo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        if let data = try? Data(contentsOf: dir.appendingPathComponent("tabs.json")),
           let saved = try? JSONDecoder().decode([TodoTab].self, from: data), !saved.isEmpty {
            tabs = saved
        }

        guard let data = try? Data(contentsOf: dir.appendingPathComponent("todos.json")) else { return }
        // Drop anything marked done by the first version of the app.
        struct Legacy: Decodable { var isDone: Bool? }
        let flags = (try? JSONDecoder().decode([Legacy].self, from: data)) ?? []
        let decoded = (try? JSONDecoder().decode([TodoItem].self, from: data)) ?? []
        let tabIDs = Set(tabs.map(\.id))
        items = decoded.enumerated()
            .filter { i, _ in !(i < flags.count && flags[i].isDone == true) }
            .map { _, item in
                // Anything whose tab no longer exists goes to the first tab.
                var item = item
                if !tabIDs.contains(item.tab) { item.tab = tabs[0].id }
                return item
            }
    }

    // MARK: Todos

    func items(in tabID: String) -> [TodoItem] { items.filter { $0.tab == tabID } }

    func todoCount(in tabID: String) -> Int { items.filter { $0.tab == tabID && !$0.isDivider }.count }

    func add(_ title: String, to tabID: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(TodoItem(title: trimmed, tab: tabID, isDivider: trimmed == "---"))
    }

    /// Moves `id` into the position currently held by `targetID` (used while dragging).
    func move(_ id: UUID, onto targetID: UUID) {
        guard id != targetID,
              let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == targetID }) else { return }
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    /// Completing a todo removes it entirely — nothing is kept.
    func complete(_ item: TodoItem) {
        items.removeAll { $0.id == item.id }
    }

    // MARK: Tabs

    @discardableResult
    func addTab() -> TodoTab {
        let tab = TodoTab(id: UUID().uuidString, name: "")
        tabs.append(tab)
        return tab
    }

    /// Removes a tab and every todo in it. The last remaining tab can't be removed.
    func removeTab(_ id: String) {
        guard tabs.count > 1 else { return }
        tabs.removeAll { $0.id == id }
        items.removeAll { $0.tab == id }
    }

    func moveTabs(from source: IndexSet, to destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    private func save<T: Encodable>(_ value: T, to file: String) {
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: dir.appendingPathComponent(file), options: .atomic)
        }
    }
}

/// UI state shared between the AppKit panel controller and the SwiftUI view.
@MainActor
final class PanelState: ObservableObject {
    let store: TodoStore

    /// The `TodoTab.id` currently shown.
    @Published var tabID: String {
        didSet {
            UserDefaults.standard.set(tabID, forKey: "selectedTab")
            selectedID = nil
        }
    }
    /// Bumped each time the panel opens so the view can focus the text field.
    @Published var openCount = 0
    /// Bumped to put keyboard focus back in the add field without clearing the selection.
    @Published var focusRequest = 0
    /// Row highlighted with the arrow keys. nil means the "add" row.
    @Published var selectedID: UUID?
    /// Rows showing their filled circle just before they disappear.
    @Published private(set) var completing: Set<UUID> = []
    /// Row currently being dragged to reorder.
    var draggingID: UUID?

    private var tabsObserver: AnyCancellable?

    init(store: TodoStore) {
        self.store = store
        let saved = UserDefaults.standard.string(forKey: "selectedTab")
        tabID = store.tabs.contains { $0.id == saved } ? saved! : store.tabs[0].id
        // If the shown tab is deleted in Preferences, fall back to the first tab.
        tabsObserver = store.$tabs.sink { [weak self] tabs in
            guard let self, !tabs.contains(where: { $0.id == self.tabID }), let first = tabs.first else { return }
            self.tabID = first.id
        }
    }

    /// Items in the current tab that can still be selected.
    private var selectable: [TodoItem] {
        store.items(in: tabID).filter { !completing.contains($0.id) }
    }

    func cycleTab(backward: Bool) {
        let all = store.tabs
        guard !all.isEmpty else { return }
        let i = all.firstIndex { $0.id == tabID } ?? 0
        tabID = all[(i + (backward ? all.count - 1 : 1)) % all.count].id
    }

    /// Up/Down through the rows; the add row sits after the last item.
    func moveSelection(up: Bool) {
        let rows = selectable
        guard !rows.isEmpty else { selectedID = nil; return }
        // Positions 0..<count are items; count is the add row.
        let current = selectedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? rows.count
        let next = up ? max(current - 1, 0) : min(current + 1, rows.count)
        selectedID = next == rows.count ? nil : rows[next].id
    }

    /// Completes the selected row and moves the highlight to the next one.
    /// Returns false when nothing is selected (so Return adds a todo instead).
    func completeSelected() -> Bool {
        guard let id = selectedID, let item = selectable.first(where: { $0.id == id }) else { return false }
        complete(item)
        return true
    }

    /// Delete / Backspace on a selected divider removes it. Returns true whenever a
    /// row is selected, so the key never edits the add field behind the highlight.
    func deleteSelected() -> Bool {
        guard let id = selectedID, let item = selectable.first(where: { $0.id == id }) else { return false }
        if item.isDivider { complete(item) }
        return true
    }

    func complete(_ item: TodoItem) {
        guard !completing.contains(item.id) else { return }
        if selectedID == item.id {
            let rows = selectable
            let i = rows.firstIndex(of: item) ?? 0
            let rest = rows.filter { $0.id != item.id }
            selectedID = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
        }
        completing.insert(item.id)
        // Todos show their filled circle briefly; dividers just go.
        DispatchQueue.main.asyncAfter(deadline: .now() + (item.isDivider ? 0 : 0.25)) { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.store.complete(item) }
            self.completing.remove(item.id)
        }
    }
}

// MARK: - Panel views

struct TodoListView: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var state: PanelState
    @State private var newTitle = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tabs (scrolls sideways if there are more than fit)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(store.tabs) { t in
                            Button(t.displayName) { state.tabID = t.id }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: state.tabID == t.id ? .semibold : .regular))
                                .foregroundStyle(state.tabID == t.id ? .primary : .tertiary)
                                .id(t.id)
                        }
                    }
                }
                .onChange(of: state.tabID) { id in
                    withAnimation { proxy.scrollTo(id) }
                }
            }
            .padding(.bottom, 10)

            // Todos
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.items(in: state.tabID)) { item in
                            TodoRow(item: item).id(item.id)
                        }
                    }
                }
                .onChange(of: state.selectedID) { id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)

            // Add row
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                TextField("", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($inputFocused)
                    .onChange(of: newTitle) { _ in state.selectedID = nil }
                    .onSubmit {
                        store.add(newTitle, to: state.tabID)
                        newTitle = ""
                    }
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(width: 280)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { inputFocused = true }
        .onChange(of: state.openCount) { _ in
            state.selectedID = nil
            inputFocused = true
        }
        .onChange(of: state.tabID) { _ in inputFocused = true }
        .onChange(of: state.focusRequest) { _ in inputFocused = true }
    }
}

struct TodoRow: View {
    @EnvironmentObject var state: PanelState
    let item: TodoItem

    private var checked: Bool { state.completing.contains(item.id) }
    private var selected: Bool { state.selectedID == item.id }

    var body: some View {
        content
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                // Click anywhere on a row (except the circle) to select it;
                // then Return completes a todo and Delete removes a divider.
                state.selectedID = item.id
                state.focusRequest += 1
            }
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.08 : 0))
            )
            .padding(.horizontal, -6)
            .transition(.opacity)
            .onDrag {
                state.draggingID = item.id
                return NSItemProvider(object: item.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: RowDropDelegate(target: item, state: state))
    }

    @ViewBuilder private var content: some View {
        if item.isDivider {
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        } else {
            HStack(spacing: 10) {
                Button {
                    state.complete(item)
                } label: {
                    Image(systemName: checked ? "circle.inset.filled" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(checked ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
        }
    }
}

/// Live reordering: as a dragged row passes over another, they swap places.
struct RowDropDelegate: DropDelegate {
    let target: TodoItem
    let state: PanelState

    func dropEntered(info: DropInfo) {
        guard let dragging = state.draggingID, dragging != target.id else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            state.store.move(dragging, onto: target.id)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        state.draggingID = nil
        return true
    }
}

/// The translucent menu-style background used by system menu bar panels.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Preferences

struct PreferencesView: View {
    @EnvironmentObject var store: TodoStore
    @State private var pendingDelete: TodoTab?
    @FocusState private var focusedTab: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tabs")
                .font(.system(size: 13, weight: .semibold))

            List {
                ForEach($store.tabs) { $tab in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        TextField("Untitled", text: $tab.name)
                            .textFieldStyle(.plain)
                            .focused($focusedTab, equals: tab.id)
                        Button { requestDelete(tab) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(store.tabs.count <= 1)
                        .help("Remove tab")
                    }
                    .padding(.vertical, 2)
                }
                .onMove { store.moveTabs(from: $0, to: $1) }
            }
            .listStyle(.inset)

            Button {
                focusedTab = store.addTab().id
            } label: {
                Label("Add tab", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Text("Drag to reorder. Removing a tab deletes its todos.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 300, height: 320)
        .alert(
            "Remove “\(pendingDelete?.displayName ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { tab in
            Button("Remove", role: .destructive) { store.removeTab(tab.id) }
            Button("Cancel", role: .cancel) {}
        } message: { tab in
            let n = store.todoCount(in: tab.id)
            Text("Its \(n) todo\(n == 1 ? "" : "s") will be deleted.")
        }
    }

    /// Empty tabs go immediately; tabs with todos ask first.
    private func requestDelete(_ tab: TodoTab) {
        if store.todoCount(in: tab.id) == 0 { store.removeTab(tab.id) }
        else { pendingDelete = tab }
    }
}

// MARK: - Panel (AppKit)

/// Borderless panel that can take keyboard focus without activating the app,
/// so Esc drops you straight back into whatever you were doing.
final class TodoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = TodoStore()
    private lazy var state = PanelState(store: store)
    private var statusItem: NSStatusItem!
    private var panel: TodoPanel!
    private var prefsWindow: NSWindow?
    private var keyMonitor: Any?
    private var lastClosed = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "To-Do")
            button.target = self
            button.action = #selector(statusItemClicked)
        }

        let root = TodoListView()
            .environmentObject(store)
            .environmentObject(state)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = .preferredContentSize

        panel = TodoPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self

        setUpMainMenu()
        installKeyMonitor()
    }

    // menubartodo://open    — opens the panel (used by Raycast)
    // menubartodo://toggle  — opens or closes it
    // menubartodo://<tab>   — opens on the tab with that name (case and spaces ignored)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "menubartodo" {
            let host = (url.host?.removingPercentEncoding ?? "open").lowercased()
            if host == "toggle" {
                panel.isVisible ? closePanel() : openPanel()
            } else {
                let key = { (s: String) in s.lowercased().replacingOccurrences(of: " ", with: "") }
                if host != "open", let tab = store.tabs.first(where: { key($0.name) == key(host) }) {
                    state.tabID = tab.id
                }
                openPanel()
            }
        }
    }

    @objc private func statusItemClicked() {
        // Clicking the icon while open first makes the panel resign key (closing it);
        // don't immediately reopen it.
        if panel.isVisible { closePanel() }
        else if Date().timeIntervalSince(lastClosed) > 0.25 { openPanel() }
    }

    private func openPanel() {
        state.openCount += 1
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        lastClosed = Date()
    }

    @objc func openPreferences() {
        closePanel()
        if prefsWindow == nil {
            let hosting = NSHostingController(rootView: PreferencesView().environmentObject(store))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Preferences"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            prefsWindow = window
        }
        // A regular window needs the app to be active to take keyboard input.
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        prefsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Drop the panel down from the menu bar icon, keeping it on screen.
    private func positionPanel() {
        guard let buttonWindow = statusItem.button?.window else { return }
        let anchor = buttonWindow.frame
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = panel.frame.size == .zero ? panel.contentViewController!.view.fittingSize : panel.frame.size
        var x = anchor.minX
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let top = anchor.minY - 4
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    // Content grows/shrinks as todos are added or completed — keep the top pinned.
    func windowDidResize(_ notification: Notification) {
        if panel.isVisible { positionPanel() }
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

    /// The menu bar is hidden for this app, but a main menu still supplies the
    /// standard shortcuts (⌘, ⌘W ⌘Q, and copy/paste/undo in text fields).
    private func setUpMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(withTitle: "App", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        NSApp.mainMenu = main
    }

    // MARK: Keyboard shortcuts (panel)
    // Esc closes the panel; Tab / Shift-Tab cycle tabs; ↑/↓ select a row;
    // Return completes the selected row (or adds the typed todo);
    // Delete removes a selected divider;
    // ⌘, opens Preferences; ⌘Q quits.

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 53: // Esc
                self.closePanel()
                return nil
            case 48 where mods.subtracting(.shift).isEmpty: // Tab, Shift-Tab
                self.state.cycleTab(backward: mods.contains(.shift))
                return nil
            case 125, 126: // ↓ ↑ (arrow keys carry the function/numericPad flags)
                guard mods.subtracting([.function, .numericPad]).isEmpty else { return event }
                self.state.moveSelection(up: event.keyCode == 126)
                return nil
            case 36, 76: // Return, keypad Enter
                guard mods.subtracting(.numericPad).isEmpty else { return event }
                return self.state.completeSelected() ? nil : event
            case 51, 117: // Delete (Backspace), Forward Delete
                guard mods.subtracting([.function, .numericPad]).isEmpty else { return event }
                return self.state.deleteSelected() ? nil : event
            case 43 where mods == .command: // ⌘,
                self.openPreferences()
                return nil
            case 12 where mods == .command: // ⌘Q
                NSApp.terminate(nil)
                return nil
            default:
                return event
            }
        }
    }
}

// MARK: - Entry point

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
