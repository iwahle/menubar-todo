# Menu Bar To-Do

A minimalist macOS menu bar to-do list with three tabs: **Work**, **Life** and **Threads**.

- Click the circle to complete a todo; it disappears and isn't stored.
- Type in the last row and press Return to add a todo.
- Todos persist in `~/Library/Application Support/MenuBarTodo/todos.json`.
- Press ⌘Q while the popup is open to quit.

## Build

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh
open build/MenuBarTodo.app
```

To launch at login, move `build/MenuBarTodo.app` to `/Applications` and add it under
System Settings → General → Login Items.
