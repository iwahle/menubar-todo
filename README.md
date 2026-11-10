# Menu Bar To-Do

A minimalist macOS menu bar to-do list with tabs (**Work**, **Life** and **Threads** by default; editable in Preferences).

- Click the circle to complete a todo; it disappears and isn't stored.
- Type in the last row and press Return to add a todo.
- Enter `---` to add a divider line. Select it by clicking it or with the arrow keys, then press Delete to remove it.
- Drag rows (todos or dividers) to reorder them.
- Todos persist in `~/Library/Application Support/MenuBarTodo/todos.json`.
- Press Tab / Shift-Tab to cycle between tabs.
- Click a todo or press ↑ / ↓ to select it, then press Return to complete it.
- Press ⌘, to open Preferences, where you can rename, add, remove and reorder tabs.
- Press Esc to close the popup.
- Press ⌘Q while the popup is open to quit.

## Open from Raycast (or anything that opens links)

The app responds to these links:

| Link | Does |
| --- | --- |
| `menubartodo://open` | Open the panel |
| `menubartodo://toggle` | Open or close the panel |
| `menubartodo://<tab name>` (e.g. `work`) | Open the panel on that tab (case and spaces ignored) |

To open it with a hotkey from any app:

1. In Raycast, run **Create Quicklink**. Name it `To-Do` and set the link to `menubartodo://open`.
2. Open Raycast Settings → Extensions, find the `To-Do` quicklink, and record a hotkey.

## Build

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh
open build/MenuBarTodo.app
```

To launch at login, move `build/MenuBarTodo.app` to `/Applications` and add it under
System Settings → General → Login Items.

## License

MIT — see [LICENSE](LICENSE).
