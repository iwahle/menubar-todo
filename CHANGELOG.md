# Changelog

New features, most recent first.

## 2026-11-18 — Keep done and struck-through todos (optional)
New Preferences options, all off by default so nothing changes unless you turn them on:
- **Keep done and struck-through todos**: checked-off todos stay, greyed out, for a set number of hours (24 by default; 1–168), then disappear. Click the circle or press Return again to reopen one.
- **Strike through**: select a todo and press ⌘⇧X to cross it out — for things that fell off the plate rather than got done. Press again to reopen.
- **Sort sections: open, done, struck through**: within each divider-separated section, open todos come first, then done, then struck through.
- A **Quit** button in Preferences.
- ⌘Z / ⌘⇧Z undo and redo changes to the list.
- Shift-↑ / Shift-↓ move the selected row up or down.
- ⌘⇧D adds a divider below the selected row (or at the end of the list).
- Delete / Backspace on a selected todo now deletes it from the list (previously it only removed dividers).

## 2026-11-10 — Click to select rows
Click any row (todo or divider) to select it, then press Return to complete a todo.

## 2026-11-10 — Editable tabs in Preferences
Press ⌘, to open Preferences, where you can rename, add, remove and reorder tabs.
Removing a tab deletes its todos; if it has any, the app asks first. The last tab can't be removed.
`menubartodo://<tab name>` links now work for any tab.

## 2026-11-10 — Delete key removes dividers
Select a divider by clicking it or with ↑/↓, then press Delete to remove it.

## 2026-11-10 — Divider lines
Enter `---` to add a horizontal divider line instead of a todo. Dividers have no circle and can be dragged like todos.

## 2026-11-10 — Drag to reorder
Drag any row up or down to change its position in the list. The order is saved.

## 2026-11-09 — Arrow-key selection
↑/↓ highlight a todo; Return completes it and moves the highlight to the next one.

## 2026-11-09 — Open from Raycast
The app responds to `menubartodo://open` and `menubartodo://toggle` links, so a Raycast quicklink with a hotkey can open it from any app.

## 2026-11-09 — Keyboard shortcuts
Esc closes the panel; Tab / Shift-Tab cycle between tabs.

## 2026-11-09 — Threads tab
Added a third tab, Threads.

## 2026-11-09 — Work and Life tabs
Minimalist redesign with Work and Life tabs. Checking off a todo removes it entirely.

## 2026-11-09 — Menu bar to-do list
First version: a to-do list that lives in the macOS menu bar.
