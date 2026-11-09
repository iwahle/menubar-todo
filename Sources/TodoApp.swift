import SwiftUI

// MARK: - Model

enum Tab: String, Codable, CaseIterable, Identifiable {
    case work = "Work", life = "Life"
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

// MARK: - Views

struct TodoListView: View {
    @EnvironmentObject var store: TodoStore
    @AppStorage("selectedTab") private var tab: Tab = .work
    @State private var newTitle = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tabs
            HStack(spacing: 16) {
                ForEach(Tab.allCases) { t in
                    Button(t.rawValue) { tab = t }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? .primary : .tertiary)
                }
            }
            .padding(.bottom, 10)

            // Todos
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.items(in: tab)) { item in
                        TodoRow(item: item)
                    }
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
                    .onSubmit {
                        store.add(newTitle, to: tab)
                        newTitle = ""
                    }
            }
            .padding(.vertical, 6)

            // Invisible ⌘Q so the app can still be quit.
            Button("") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(width: 280)
        .onAppear { inputFocused = true }
        .onChange(of: tab) { _ in inputFocused = true }
    }
}

struct TodoRow: View {
    @EnvironmentObject var store: TodoStore
    let item: TodoItem
    @State private var checked = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                checked = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.easeOut(duration: 0.2)) { store.complete(item) }
                }
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
        .transition(.opacity)
    }
}

// MARK: - App

@main
struct MenuBarTodoApp: App {
    @StateObject private var store = TodoStore()

    var body: some Scene {
        MenuBarExtra {
            TodoListView().environmentObject(store)
        } label: {
            Image(systemName: "checklist")
        }
        .menuBarExtraStyle(.window)
    }
}
