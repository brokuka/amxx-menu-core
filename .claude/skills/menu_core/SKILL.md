---
name: menu_core
description: Build in-game menus from an AMXX plugin via the Menu Core engine (mc_* natives from include/menu_core.inc). Use when a plugin needs to register/show menus, add items, or wire conditions, actions, placeholders, restrictions, data sources and lifecycle callbacks. Covers the API, the menu.ini config format (STRICT vs LIST, ITEMS/VIEW/FILTER/FIXED_ITEMS), built-in SHOW_/CLOSE_MENU actions, and gotchas.
---

# Menu Core — consumer guide

`menu_core.amxx` is a **foundational, config-driven menu engine**. A menu is usually declared
as a section in `configs/.../menu.ini`; the plugin registers callbacks and shows it. Other
plugins consume it through `mc_*` natives.

```pawn
#include <menu_core>
```
`menu_core.amxx` must load **after** `universal_config.amxx` in `configs/plugins.ini`.

## Two menu types
- **STRICT** — fixed list of items from config `ITEMS`. Action callback: `public cb(id, const key[])`.
- **LIST** — dynamic rows (players by default, or a custom data source). Section name **must
  start with `LIST_`**. Action callback: `public cb(id, targetId)`.

## Minimal recipe
```pawn
public plugin_init() {
    register_plugin("My Mod", "1.0", "kukson")
    mc_register_menu("MY_MENU")                       // section must exist in menu.ini
    mc_register_action("DO_HEAL", "Act_Heal")
    mc_register_condition("IS_ALIVE", "Cond_Alive")
}
public Act_Heal(id, const key[]) { /* STRICT handler */ }
public bool:Cond_Alive(id)       { return bool:is_user_alive(id); }

public CmdOpen(id) { mc_show_menu(id, "MY_MENU"); return PLUGIN_HANDLED }
```

## Registration natives (call in plugin_init)
- `mc_register_menu(section)` → menu id (config-backed). Or build in code with
  `mc_create_menu(section, title)` + `mc_add_menu_item(...)` / `mc_add_fixed_menu_item(...)`.
- `mc_register_condition(name, callback)` — `public cb(id)` → bool. Controls item/variant visibility.
- `mc_register_action(name, callback, bool:isCritical=false)` — runs on select (signature by type).
- `mc_register_placeholder(name, callback)` — `public cb(id, targetId, value[], len)`; referenced
  as `%name%` in item text.
- `mc_register_restriction(name, callback, message="")` — `public cb(id, const restrictName[])` → bool;
  `"*"` = wildcard. Failing renders the item disabled with `message`.
- `mc_register_action_condition(menuSection, actionName, callback)` — gray out an item when
  `public cb(id, const menuSection[], const actionName[])` returns false (empty args = match all).
- `mc_register_list_data_source(menuName, callback)` — feed a LIST menu custom rows; see item
  layout below. **The callback must `return 1`** to use its items (any other value falls back
  to the default player list).
- `mc_register_menu_open_callback(cb)` / `mc_register_menu_close_callback(cb)` — lifecycle hooks
  (`cb(id, section)` / `cb(id, bool:isTimeout, section)`).

## Showing / controlling
- `mc_show_menu(id, section, time=-1, targetId=0, bool:resetHistory=false, bool:forceOpen=false, bool:ignoreHistory=false)`
  — **note this native arg order** (it differs from the engine's internal stock; consumers use this one).
- `mc_refresh_menu("A B C")`, `mc_notify_condition_changed(name)` (refreshes menus depending on it),
  `mc_set_menu_timer`, `mc_cancel_menu_timer`, `mc_lock_menu`, `mc_hide_menu`, `mc_is_menu_locked`,
  `mc_get_active_menu`, `mc_set_menu_page`, `mc_set_menu_property[_string]`.

## Live updates / auto-refresh (no manual re-show needed)
An open menu re-evaluates its placeholders, variant visibility and item availability **every
time it is rendered** — so you update what a player sees by triggering a refresh, not by
rebuilding the menu.

- **Reactive (preferred):** the engine auto-tracks every condition a menu references (in
  `ACTIVE_ON`, item conditions, `FILTER`, variant conditions). When the underlying value
  changes, call `mc_notify_condition_changed("COND_NAME")` and the engine re-renders that menu
  for **all** players currently viewing it. Use this for state-driven visibility/availability
  (e.g. a player became chief → `mc_notify_condition_changed("IS_CHIEF")`).
- **Direct:** `mc_refresh_menu("SECTION_A SECTION_B")` re-renders the named sections for their
  current viewers. Use it when the changed value is a **placeholder** (not a condition) — e.g. a
  `%hp%` / `%money%` shown in the title or items: change the value, then `mc_refresh_menu(section)`.
- **Automatic `%time%`:** while a menu timer is active the engine re-renders once per second, so a
  `%time%` placeholder (or the built-in timer line) counts down on its own — no calls needed.

Rule of thumb: put dynamic text in a placeholder, then call `mc_refresh_menu` (placeholder
changed) or `mc_notify_condition_changed` (a registered condition changed). Do **not** call
`mc_show_menu` again just to refresh — it restarts history/timer state.

## Built-in actions (do NOT register)
- `SHOW_<SECTION>` — opens section `<SECTION>` (don't write a wrapper action just to call
  `mc_show_menu`). e.g. action `SHOW_ADMIN_MENU`.
- `CLOSE_MENU` — closes the player's menu.
Both work in STRICT and LIST and combine in a space-separated action list
(e.g. `"PLAYER_HEAL CLOSE_MENU"`).

## menu.ini config format (per section)
- `TITLE` — required (raw text or ML key).
- A block is opened with `KEY = {` and closed by `}` on its own line.
- STRICT: `ITEMS = { "name|variants" "placeholder" "condition" "action" "restriction" "restrictMsg" "skip" }` rows (7 columns; the action is the 4th).
- LIST: `VIEW = { "name" "condition" "action" "restriction" "restrictMsg" }` (single template row) + optional `FILTER = { "CONDITION" "MSG" }` rows.
- `FIXED_ITEMS` — pinned-slot rows (slot is the first column, 1-based).
- Flags: `HIDE_BACK`, `HIDE_EXIT`, `LOCKED`, `GLOBAL` (`1`/`true`/`yes`), `TIME`, `ON_TIMEOUT`,
  `ACTIVE_ON` (visibility condition for the whole menu).
- Variant syntax: `"A|B|C"` in name/condition/action columns produces per-condition variants.
- Placeholders in text: `%name%`, `%target%`, `%time%`, plus any registered `%custom%`.

## Data source row layout (289-cell item for LIST menus)
Inside `public cb(id, Array:items)`: each item is a 289-cell array —
`item[0]`=targetId (use `-2` for a display-only text row), `item[1..64]`=action/entity key,
`item[65..128]`=display text/ML key, `item[129..160]`=restriction name, `item[161..288]`=disabled
message. Use `mc_add_list_text(items, text, centered)` to push a separator/header row.
**Return 1** from the callback to activate the data source.

## Gotchas
- LIST sections **must** be prefixed `LIST_` (sets `MENU_TYPE_LIST`).
- The plugin must load after `universal_config`; `menu.ini` must exist.
- Color tags in text: `!g`/`!t`/`!y`/`!r`/`!b`/`!w` (TeamInfo trick) for chat messages.
- `mc_register_menu` returns -1 if the section is `"MAIN"` (reserved: holds the chat prefix +
  button language keys), missing `TITLE`, or absent from `menu.ini`.
- UI lang keys (`KEY/EXIT`, `KEY/NUMBER`, …) and `PREFIX` in `[MAIN]` fall back to built-in
  defaults when the configured ML key is not registered (e.g. its dictionary plugin is off),
  so the menu never prints raw key names. (Built-in defaults are English: Exit/Back/Next/…)
- `menu_core` only provides menu natives — pull gameplay natives from your own includes
  (`<fun>` for `set_user_health`/`user_kill`, `<engine>`/`<hamsandwich>`/`<reapi>` as needed).

## Build
```bash
cd scripting
./amxxpc.exe yourmod.sma -i./include -o../plugins/yourmod.amxx
```
Recompile and fix every compiler warning before shipping. Full native docs:
`scripting/include/menu_core.inc`.
