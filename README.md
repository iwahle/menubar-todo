# Menu Bar To-Do

A minimalist macOS menu bar to-do list with three tabs: **Work**, **Life** and **Threads**.

- Click the circle to complete a todo; it disappears and isn't stored.
- Type in the last row and press Return to add a todo.
- Todos persist in `~/Library/Application Support/MenuBarTodo/todos.json`.
- Press Tab / Shift-Tab to cycle between tabs.
- Press ↑ / ↓ to select a todo, then Return to complete it.
- Press Esc to close the popup.
- Press ⌘Q while the popup is open to quit.

## Open from Raycast (or anything that opens links)

The app responds to these links:

| Link | Does |
| --- | --- |
| `menubartodo://open` | Open the panel |
| `menubartodo://toggle` | Open or close the panel |
| `menubartodo://work`, `life`, `threads` | Open the panel on that tab |

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
