import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Settings

/// Preferences stored in UserDefaults. Every option defaults to off, so the app
/// behaves exactly as it always has until you opt in.
enum Prefs {
    /// Completed and struck-through todos stay visible for `keepHours` instead of vanishing.
    static let keepCompleted = "keepCompleted"
    static let keepHours = "keepCompletedHours"
    /// Within each divider-separated section, list open todos, then done, then struck through.
    static let doneLast = "sortDoneLast"

    static let defaultHours = 24

    static var isKeepingCompleted: Bool { UserDefaults.standard.bool(forKey: keepCompleted) }
    static var hours: Int {
        let h = UserDefaults.standard.integer(forKey: keepHours)
        return h > 0 ? h : defaultHours
    }
}

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
    /// When the todo was checked off. Only set while "keep completed" is on;
    /// otherwise completing removes the todo.
    var completedAt: Date?
    /// When the todo was struck through — dropped rather than done. Never set
    /// together with `completedAt`.
    var struckAt: Date?

    var isDone: Bool { completedAt != nil }
    var isStruck: Bool { struckAt != nil }
    var isOpen: Bool { !isDone && !isStruck }

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
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        struckAt = try c.decodeIfPresent(Date.self, forKey: .struckAt)
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

    private var observers: Set<AnyCancellable> = []

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

    /// Re-check expiry when preferences change and once an hour.
    func startExpiryChecks() {
        purgeExpired()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.purgeExpired()
                self?.objectWillChange.send() // re-sort if "done first" changed
            }
            .store(in: &observers)
        Timer.publish(every: 3600, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.purgeExpired() }
            .store(in: &observers)
    }

    /// Removes done / struck todos older than the keep duration — or all of them when
    /// "keep completed" is off.
    func purgeExpired() {
        let keep = Prefs.isKeepingCompleted
        let cutoff = Date().addingTimeInterval(-Double(Prefs.hours) * 3600)
        let expired = { (item: TodoItem) in
            guard let closed = item.completedAt ?? item.struckAt else { return false }
            return !keep || closed < cutoff
        }
        if items.contains(where: expired) { items.removeAll(where: expired) }
    }

    // MARK: Todos

    /// Items in a tab, in display order. With "done last" on, each divider-separated
    /// section lists open todos, then done, then struck through (otherwise stored order is kept).
    func items(in tabID: String) -> [TodoItem] {
        let rows = items.filter { $0.tab == tabID }
        guard Prefs.isKeepingCompleted, UserDefaults.standard.bool(forKey: Prefs.doneLast) else { return rows }
        var result: [TodoItem] = []
        var section: [TodoItem] = []
        func flush() {
            result += section.filter(\.isOpen) + section.filter(\.isDone) + section.filter(\.isStruck)
            section = []
        }
        for row in rows {
            if row.isDivider { flush(); result.append(row) } else { section.append(row) }
        }
        flush()
        return result
    }

    func todoCount(in tabID: String) -> Int { items.filter { $0.tab == tabID && !$0.isDivider }.count }

    // MARK: Undo / redo
    // Each change to the list saves a snapshot of it beforehand. Kept in memory
    // only (cleared on quit), capped at `undoLimit` steps.

    private var undoStack: [[TodoItem]] = []
    private var redoStack: [[TodoItem]] = []
    private let undoLimit = 100

    /// Call before changing `items` so the change can be undone.
    func recordUndo() {
        undoStack.append(items)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Returns false when there's nothing to undo.
    @discardableResult
    func undo() -> Bool {
        // Skip snapshots identical to now (e.g. a drag that didn't move anything).
        while let last = undoStack.last, last == items { undoStack.removeLast() }
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(items)
        items = previous
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(items)
        items = next
        return true
    }

    func add(_ title: String, to tabID: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recordUndo()
        items.append(TodoItem(title: trimmed, tab: tabID, isDivider: trimmed == "---"))
    }

    /// Moves `id` into the position currently held by `targetID` (used while dragging).
    /// Not recorded per step — the row records one undo when the drag starts.
    func move(_ id: UUID, onto targetID: UUID) {
        guard id != targetID,
              let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == targetID }) else { return }
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    /// Completing removes the todo entirely, unless "keep completed" is on, in which
    /// case it's marked done and removed once it expires. Dividers are always removed.
    func complete(_ item: TodoItem) {
        recordUndo()
        if Prefs.isKeepingCompleted && !item.isDivider,
           let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i].completedAt = Date()
            items[i].struckAt = nil
        } else {
            items.removeAll { $0.id == item.id }
        }
    }

    /// Adds a divider just below `afterID` if given, otherwise at the end of the tab.
    func addDivider(to tabID: String, after afterID: UUID?) {
        let divider = TodoItem(title: "---", tab: tabID, isDivider: true)
        recordUndo()
        if let afterID, let i = items.firstIndex(where: { $0.id == afterID }) {
            items.insert(divider, at: i + 1)
        } else {
            items.append(divider)
        }
    }

    /// Deletes a todo or divider outright, whatever its state.
    func remove(_ item: TodoItem) {
        recordUndo()
        items.removeAll { $0.id == item.id }
    }

    /// Strikes a todo through: it fell off the plate rather than got done. Only
    /// meaningful while "keep completed" is on (callers check).
    func strike(_ item: TodoItem) {
        guard !item.isDivider, let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        recordUndo()
        items[i].struckAt = Date()
        items[i].completedAt = nil
    }

    /// Returns a done or struck-through todo to open.
    func reopen(_ item: TodoItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        recordUndo()
        items[i].completedAt = nil
        items[i].struckAt = nil
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
        // Old snapshots would bring back todos for a tab that's gone.
        undoStack.removeAll()
        redoStack.removeAll()
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

    /// Completes the selected row (or un-completes a done one) and moves the
    /// highlight to the next row.
    /// Returns false when nothing is selected (so Return adds a todo instead).
    func completeSelected() -> Bool {
        guard let id = selectedID, let item = selectable.first(where: { $0.id == id }) else { return false }
        toggle(item)
        return true
    }

    /// Delete / Backspace removes the selected row (todo or divider) from the list.
    /// Returns false when nothing is selected, so the key edits the add field instead.
    func deleteSelected() -> Bool {
        guard let id = selectedID, let item = selectable.first(where: { $0.id == id }) else { return false }
        advanceSelection(past: item)
        // Remove on the next run-loop pass, outside the key event (like completing
        // does). Removing inside the event left the panel undrawn until the next key.
        DispatchQueue.main.async { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) { self?.store.remove(item) }
        }
        return true
    }

    /// Shift-↑ / Shift-↓: move the selected row one place up or down (one undo step
    /// per press). Returns false when nothing is selected, so Shift-arrows can
    /// select text in the add field instead.
    func moveSelectedRow(up: Bool) -> Bool {
        guard let id = selectedID, let item = selectable.first(where: { $0.id == id }) else { return false }
        let rows = store.items(in: tabID)
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return true }
        let candidates = up ? Array(rows[..<i].reversed()) : Array(rows[(i + 1)...])
        // With sorting on, hop over rows in a different group (open / done / struck);
        // swapping with them wouldn't visibly move anything.
        let sorted = Prefs.isKeepingCompleted && UserDefaults.standard.bool(forKey: Prefs.doneLast)
        func group(_ t: TodoItem) -> Int { t.isOpen ? 0 : t.isDone ? 1 : 2 }
        guard let target = candidates.first(where: {
            !sorted || item.isDivider || $0.isDivider || group($0) == group(item)
        }) else { return true }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.store.recordUndo()
            withAnimation(.easeInOut(duration: 0.15)) { self.store.move(id, onto: target.id) }
        }
        return true
    }

    /// ⌘Z / ⌘⇧Z on the list. Clears the highlight if its row no longer exists.
    func undo(redo: Bool) {
        withAnimation(.easeOut(duration: 0.2)) {
            _ = redo ? store.redo() : store.undo()
        }
        if let id = selectedID, !store.items.contains(where: { $0.id == id }) { selectedID = nil }
    }

    /// ⌘⇧D: add a divider below the selected row, or at the end of the tab.
    func addDivider() {
        let after = selectedID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.store.addDivider(to: self.tabID, after: after) }
        }
    }

    /// ⌘⇧X: strike through the selected todo (or restore a struck one).
    /// Returns false when no todo is selected.
    func strikeSelected() -> Bool {
        guard let id = selectedID, let item = selectable.first(where: { $0.id == id }),
              !item.isDivider else { return false }
        toggleStrike(item)
        return true
    }

    /// Completes a todo, or reopens one that's already done.
    /// A struck-through todo becomes done.
    func toggle(_ item: TodoItem) {
        if item.isDone {
            withAnimation(.easeOut(duration: 0.2)) { store.reopen(item) }
        } else {
            complete(item)
        }
    }

    /// Strikes a todo through, or reopens one that's already struck.
    /// Does nothing unless "keep completed" is on.
    func toggleStrike(_ item: TodoItem) {
        guard Prefs.isKeepingCompleted, !item.isDivider, !completing.contains(item.id) else { return }
        if item.isStruck {
            withAnimation(.easeOut(duration: 0.2)) { store.reopen(item) }
        } else {
            advanceSelection(past: item)
            withAnimation(.easeOut(duration: 0.2)) { store.strike(item) }
        }
    }

    /// If `item` is highlighted, move the highlight to the row after it.
    private func advanceSelection(past item: TodoItem) {
        guard selectedID == item.id else { return }
        let rows = selectable
        let i = rows.firstIndex(of: item) ?? 0
        let rest = rows.filter { $0.id != item.id }
        selectedID = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
    }

    func complete(_ item: TodoItem) {
        guard !completing.contains(item.id), !item.isDone else { return }
        advanceSelection(past: item)
        completing.insert(item.id)
        // Todos show their filled circle briefly; dividers just go.
        // (With "keep completed" on, the todo then stays, greyed out.)
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

    private var checked: Bool { !item.isOpen || state.completing.contains(item.id) }
    private var selected: Bool { state.selectedID == item.id }

    var body: some View {
        content
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                // Click anywhere on a row (except the circle) to select it;
                // then Return completes it and Delete removes it.
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
                state.store.recordUndo() // one undo step per drag
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
                    state.toggle(item)
                } label: {
                    Image(systemName: checked ? "circle.inset.filled" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                Text(item.title)
                    .font(.system(size: 13))
                    .strikethrough(item.isStruck)
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
    @AppStorage(Prefs.keepCompleted) private var keepCompleted = false
    @AppStorage(Prefs.keepHours) private var keepHours = Prefs.defaultHours
    @AppStorage(Prefs.doneLast) private var doneLast = false

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

            Divider().padding(.vertical, 4)

            Text("Completed todos")
                .font(.system(size: 13, weight: .semibold))

            Toggle("Keep done and struck-through todos", isOn: $keepCompleted)
            Stepper(value: $keepHours, in: 1...168) {
                Text("Remove after \(keepHours) hour\(keepHours == 1 ? "" : "s")")
            }
            .disabled(!keepCompleted)
            .padding(.leading, 20)
            Toggle("Sort sections: open, done, struck through", isOn: $doneLast)
                .disabled(!keepCompleted)
            Text("⌘⇧X strikes through the selected todo (it fell off the plate).")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Quit Menu Bar To-Do") { NSApp.terminate(nil) }
            }
        }
        .toggleStyle(.checkbox)
        .padding(16)
        .frame(width: 300, height: 520)
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

        store.startExpiryChecks()
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
        store.purgeExpired()
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
    // Delete removes the selected row;
    // Shift-↑/↓ moves the selected row up / down;
    // ⌘Z / ⌘⇧Z undo / redo list changes (text edits while typing in the add field);
    // ⌘⇧D adds a divider (below the selected row, or at the end);
    // ⌘⇧X strikes through the selected todo (when keeping completed todos);
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
                let arrowMods = mods.subtracting([.function, .numericPad])
                if arrowMods == .shift { // Shift-↑/↓ reorders the selected row
                    return self.state.moveSelectedRow(up: event.keyCode == 126) ? nil : event
                }
                guard arrowMods.isEmpty else { return event }
                self.state.moveSelection(up: event.keyCode == 126)
                return nil
            case 36, 76: // Return, keypad Enter
                guard mods.subtracting(.numericPad).isEmpty else { return event }
                return self.state.completeSelected() ? nil : event
            case 51, 117: // Delete (Backspace), Forward Delete
                guard mods.subtracting([.function, .numericPad]).isEmpty else { return event }
                return self.state.deleteSelected() ? nil : event
            case 2 where mods == [.command, .shift]: // ⌘⇧D
                self.state.addDivider()
                return nil
            case 7 where mods == [.command, .shift]: // ⌘⇧X
                return self.state.strikeSelected() ? nil : event
            case 43 where mods == .command: // ⌘,
                self.openPreferences()
                return nil
            case 6 where mods == .command || mods == [.command, .shift]: // ⌘Z, ⌘⇧Z
                // While something is typed in the add field, ⌘Z edits that text.
                if let editor = self.panel.firstResponder as? NSTextView, !editor.string.isEmpty {
                    return event
                }
                let redo = mods.contains(.shift)
                DispatchQueue.main.async { self.state.undo(redo: redo) }
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
