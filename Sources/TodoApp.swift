import SwiftUI
import AppKit

// MARK: - Model

enum Tab: String, Codable, CaseIterable, Identifiable {
    case work = "Work", life = "Life", threads = "Threads"
    var id: String { rawValue }
}

struct TodoItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var tab: Tab

    init(title: String, tab: Tab) {
        self.title = title
        self.tab = tab
    }

    // Tolerates the older saved format (no `tab` field) by defaulting to Work.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        tab = try c.decodeIfPresent(Tab.self, forKey: .tab) ?? .work
    }
}

@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = [] {
        didSet { save() }
    }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuBarTodo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("todos.json")
    }()

    init() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // Drop anything marked done by the previous version of the app.
        struct Legacy: Decodable { var isDone: Bool? }
        let flags = (try? JSONDecoder().decode([Legacy].self, from: data)) ?? []
        let decoded = (try? JSONDecoder().decode([TodoItem].self, from: data)) ?? []
        items = decoded.enumerated()
            .filter { i, _ in !(i < flags.count && flags[i].isDone == true) }
            .map(\.element)
    }

    func items(in tab: Tab) -> [TodoItem] { items.filter { $0.tab == tab } }

    func add(_ title: String, to tab: Tab) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(TodoItem(title: trimmed, tab: tab))
    }

    /// Completing a todo removes it entirely — nothing is kept.
    func complete(_ item: TodoItem) {
        items.removeAll { $0.id == item.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// UI state shared between the AppKit panel controller and the SwiftUI view.
@MainActor
final class PanelState: ObservableObject {
    let store: TodoStore

    @Published var tab: Tab {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab")
            selectedID = nil
        }
    }
    /// Bumped each time the panel opens so the view can focus the text field.
    @Published var openCount = 0
    /// Row highlighted with the arrow keys. nil means the "add" row.
    @Published var selectedID: UUID?
    /// Rows showing their filled circle just before they disappear.
    @Published private(set) var completing: Set<UUID> = []

    init(store: TodoStore) {
        self.store = store
        tab = UserDefaults.standard.string(forKey: "selectedTab").flatMap(Tab.init) ?? .work
    }

    /// Items in the current tab that can still be selected.
    private var selectable: [TodoItem] {
        store.items(in: tab).filter { !completing.contains($0.id) }
    }

    func cycleTab(backward: Bool) {
        let all = Tab.allCases
        let i = all.firstIndex(of: tab) ?? 0
        tab = all[(i + (backward ? all.count - 1 : 1)) % all.count]
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

    func complete(_ item: TodoItem) {
        guard !completing.contains(item.id) else { return }
        if selectedID == item.id {
            let rows = selectable
            let i = rows.firstIndex(of: item) ?? 0
            let rest = rows.filter { $0.id != item.id }
            selectedID = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
        }
        completing.insert(item.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.store.complete(item) }
            self.completing.remove(item.id)
        }
    }
}

// MARK: - Views

struct TodoListView: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var state: PanelState
    @State private var newTitle = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tabs
            HStack(spacing: 16) {
                ForEach(Tab.allCases) { t in
                    Button(t.rawValue) { state.tab = t }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: state.tab == t ? .semibold : .regular))
                        .foregroundStyle(state.tab == t ? .primary : .tertiary)
                }
            }
            .padding(.bottom, 10)

            // Todos
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.items(in: state.tab)) { item in
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
                        store.add(newTitle, to: state.tab)
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
        .onChange(of: state.tab) { _ in inputFocused = true }
    }
}

struct TodoRow: View {
    @EnvironmentObject var state: PanelState
    let item: TodoItem

    private var checked: Bool { state.completing.contains(item.id) }
    private var selected: Bool { state.selectedID == item.id }

    var body: some View {
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
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.08 : 0))
        )
        .padding(.horizontal, -6)
        .transition(.opacity)
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

        installKeyMonitor()
    }

    // menubartodo://open  — opens the panel (used by Raycast)
    // menubartodo://toggle — opens or closes it
    // menubartodo://work | life | threads — opens on that tab
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "menubartodo" {
            let host = url.host?.lowercased() ?? "open"
            if host == "toggle" {
                panel.isVisible ? closePanel() : openPanel()
            } else {
                if let tab = Tab.allCases.first(where: { $0.rawValue.lowercased() == host }) {
                    state.tab = tab
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

    // MARK: Keyboard shortcuts
    // Esc closes the panel; Tab / Shift-Tab cycle tabs; ↑/↓ select a row;
    // Return completes the selected row (or adds the typed todo); ⌘Q quits.

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
