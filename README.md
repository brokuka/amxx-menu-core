<p align="center">
  <img src="assets/logo.png" alt="Menu Core" width="200">
</p>

<h1 align="center">Menu Core</h1>

A **configuration-driven dynamic menu engine for AMX Mod X**. Build in-game menus
from an INI config (or entirely in code) with conditional items, variant selection,
restrictions, placeholders, navigation history and lifecycle callbacks.

- **Version:** 1.6.2
- **Author:** kukson
- **License:** MIT (see `LICENSE`).

---

## Features

- Two menu types: **STRICT** (predefined items) and **LIST** (dynamic, data-driven).
- Dynamic player lists with real-time filtering, or custom data sources for arbitrary
  entities (weapons, items, …).
- **Conditional visibility** and **variant selection** per item (`condition | condition`).
- **Restriction system** with custom validators and per-item failure messages.
- **Placeholder system** for dynamic text substitution in list rows (`%name%`, `%health%`…).
- Menu history / back navigation, pagination, per-player and global countdown timers.
- Lifecycle callbacks: open / close / show-filter (central veto before a menu renders).
- Define menus in `menu.ini` **or** create and populate them at runtime
  (`mc_create_menu`, `mc_add_menu_item`, `mc_add_fixed_menu_item`).

## Dependencies

- **[Universal Config System](https://github.com/brokuka/amxx-universal-config)** — the
  config engine Menu Core reads its `menu.ini` through. Its `universal_config.amxx`
  must be loaded **before** `menu_core.amxx`.
- **[ReAPI](https://github.com/rehlds/ReAPI/releases)** (`reapi`) — used for player/team queries.

> `scripting/include/universal_config.inc` is bundled here so Menu Core compiles
> out of the box; the runtime `universal_config.amxx` plugin still has to be installed
> separately (see its repository).

## Installation

1. Install **Universal Config System** first.
2. Copy `scripting/menu_core.sma` into your AMX Mod X `scripting/` folder.
3. Copy `scripting/include/menu_core.inc` (and the bundled `universal_config.inc`,
   if you don't already have it) into `scripting/include/`.
4. Compile:
   ```
   amxxpc menu_core.sma -i./include -o../plugins/menu_core.amxx
   ```
5. In `configs/plugins.ini`, load in this order:
   ```
   universal_config.amxx
   menu_core.amxx
   ```
6. Place your `menu.ini` in the configs directory used by the config engine.

## Quick start (config-driven)

`configs/menu.ini`:

```ini
[MAIN]
PREFIX = "!g[MyMenu]!y"
KEY = {
    EXIT = "Exit"
    BACK = "Back"
    NEXT = "Next"
}

[CHOOSE_TEAM]
TITLE = "\yChoose your team"
; STRICT row columns: "Name" "Placeholder" "Condition" "Action" "Restriction" "Message" "Skip"
ITEMS = {
    "Terrorists" "" "" "JOIN_T"  "" "" ""
    "CT"         "" "" "JOIN_CT" "" "" ""
}
```

> **Block syntax:** a block is opened with `KEY = {` (note the `=`) and closed by `}`
> on its own line. STRICT `ITEMS` rows always carry the 7 columns above — the action
> sits in the **4th** column, so empty leading columns must be kept as `""`.

Plugin:

```pawn
#include <amxmodx>
#include <menu_core>

public plugin_init() {
    register_clcmd("say /team", "cmd_team")
    mc_register_action("JOIN_T",  "act_join_t")
    mc_register_action("JOIN_CT", "act_join_ct")
    mc_register_menu("CHOOSE_TEAM")
}

public cmd_team(id) { mc_show_menu(id, "CHOOSE_TEAM"); return PLUGIN_HANDLED }
public act_join_t(id, const key[])  { /* ... */ }
public act_join_ct(id, const key[]) { /* ... */ }
```

## Quick start (code-driven)

```pawn
mc_create_menu("MY_MENU", "\yMy menu")
mc_add_menu_item("MY_MENU", "Heal me", _, _, "HEAL")
mc_add_menu_item("MY_MENU", "Give weapon", _, _, "GIVE_GUN")
mc_show_menu(id, "MY_MENU")
```

## API overview

See `scripting/include/menu_core.inc` for the fully documented native list.

| Area | Natives |
|------|---------|
| Registration | `mc_register_menu`, `mc_register_condition`, `mc_register_action`, `mc_register_placeholder`, `mc_register_restriction` |
| Advanced hooks | `mc_register_action_condition`, `mc_register_condition_filter`, `mc_register_list_data_source`, `mc_register_show_filter`, `mc_register_menu_open_callback`, `mc_register_menu_close_callback` |
| Display & control | `mc_show_menu`, `mc_hide_menu`, `mc_refresh_menu`, `mc_set_menu_page`, `mc_lock_menu`, `mc_is_menu_locked`, `mc_get_active_menu` |
| Timers | `mc_set_menu_timer`, `mc_cancel_menu_timer`, `mc_notify_condition_changed` |
| Build in code | `mc_create_menu`, `mc_add_menu_item`, `mc_add_fixed_menu_item`, `mc_add_list_text`, `mc_clear_menu_items` |
| Properties | `mc_set_menu_property`, `mc_set_menu_property_string`, `mc_get_menu_property_string` |

### Built-in actions

- `SHOW_<SECTION>` — opens the named menu section (chains into sub-menus without a wrapper action).
- `CLOSE_MENU` — closes the player's current menu.

Both work in STRICT and LIST menus and may be combined in a space-separated action list.

## Use cases & recipes

Every feature the engine exposes, with runnable snippets.

### 1. STRICT menu from config + actions

```ini
[CHOOSE_TEAM]
TITLE = "\yChoose your team"
ITEMS = {
    "Terrorists" "" "" "JOIN_T"  "" "" ""
    "CT"         "" "" "JOIN_CT" "" "" ""
}
```
```pawn
mc_register_action("JOIN_T",  "act_join_t")
mc_register_action("JOIN_CT", "act_join_ct")
mc_register_menu("CHOOSE_TEAM")
// ...
public act_join_t(id, const key[])  { /* ... */ }
```

### 2. Sub-menu navigation with the built-in `SHOW_` action

```ini
[MAIN_MENU]
TITLE = "\yMain"
ITEMS = {
    "Admin panel" "" "" "SHOW_ADMIN_MENU" "" "" ""   ; opens [ADMIN_MENU], no wrapper needed
    "Close"       "" "" "CLOSE_MENU"      "" "" ""
}
```

### 3. LIST menu over the player list + placeholders

```ini
[LIST_SLAP]
TITLE = "\ySlap a player"
; LIST VIEW columns: "Name" "Condition" "Action" "Restriction" "RestrictionMsg"
VIEW = {
    "%name% \d[\r%health%hp\d]" "" "DO_SLAP" "" ""
}
```
```pawn
mc_register_placeholder("name",   "ph_name")
mc_register_placeholder("health", "ph_health")
mc_register_action("DO_SLAP", "act_slap")          // LIST action: (id, targetId)
mc_register_menu("LIST_SLAP")

public ph_health(id, targetId, value[], len) {
    formatex(value, len, "%d", get_user_health(targetId))
}
public act_slap(id, targetId) { /* slap targetId */ }
```

### 4. LIST menu with a custom data source (non-player entities)

```pawn
mc_register_list_data_source("LIST_GUNS", "ds_guns")

public ds_guns(id, Array:items) {
    new item[289]
    item[0] = 1                                     // targetId passed to the action
    copy(item[1],  63, "weapon_ak47")               // action key
    copy(item[65], 63, "AK-47")                     // display text / lang key
    ArrayPushArray(items, item)

    mc_add_list_text(items, "=== Rifles ===", true) // display-only separator row
    return 1                                         // REQUIRED: 1 = use these items;
                                                     // any other value discards them and
                                                     // falls back to the default player list
}
```

### 5. Conditional item visibility

```ini
ITEMS = {
    "Admin tools" "" "IS_ADMIN" "SHOW_ADMIN" "" "" ""  ; condition (col 3) gates visibility
}
```
```pawn
mc_register_condition("IS_ADMIN", "cond_is_admin")
public bool:cond_is_admin(id) { return (get_user_flags(id) & ADMIN_KICK) != 0 }
// notify the engine when the value changes so open menus refresh:
mc_notify_condition_changed("IS_ADMIN")
```

### 6. Variant selection (one item, different labels by condition)

The name/condition/action fields accept `|`-separated variants; the first variant
whose condition passes is rendered.

```pawn
mc_add_menu_item("SETTINGS",
    "HUD: ON|HUD: OFF",   // names
    "",
    "IS_HUD_ON|",         // conditions: variant 1 needs IS_HUD_ON, variant 2 is default
    "HUD_OFF|HUD_ON")     // actions: matched per selected variant
```

### 7. Restrictions (block selection with a reason)

```pawn
mc_register_restriction("VIP", "rest_vip", "This option is VIP-only")
public bool:rest_vip(id, const restrictName[]) { return is_user_vip(id) }
```
```ini
ITEMS = {
    "VIP skin" "" "" "GIVE_SKIN" "VIP" "" ""   ; restriction (col 5) = VIP; non-VIPs see the message
}
```

### 8. Action conditions (gray out / disable an item)

```pawn
// Disable "OPEN_CELLS" in CHIEF_MENU while it is not allowed yet.
mc_register_action_condition("CHIEF_MENU", "OPEN_CELLS", "ac_can_open")
public bool:ac_can_open(id, const section[], const action[]) { return g_bCellsReady }
```

### 9. Condition filters (override another plugin's condition)

```pawn
// Force IS_TRAINING_ENABLED to false while a mix is running, without owning it.
mc_register_condition_filter("IS_TRAINING_ENABLED", "cf_block_in_mix")
public bool:cf_block_in_mix(id, viewerId, const condition[], bool:currentVal) {
    return g_bMixActive ? false : currentVal
}
```

### 10. Show filter (one central gate for all menu openings)

```pawn
mc_register_show_filter("sf_gate")
public bool:sf_gate(id, const section[]) {
    if (g_bFrozen) { client_print(id, print_chat, "Menus are locked right now"); return false }
    return true   // allow
}
```

### 11. Lifecycle callbacks (open / close)

```pawn
mc_register_menu_open_callback("on_open")
mc_register_menu_close_callback("on_close")
public on_open(id, const section[]) { /* ... */ }
public on_close(id, bool:isTimeout, const section[]) { /* ... */ }
```

### 12. Menu timers (countdown)

```ini
[VOTE]
TITLE = "\yVote"
TIME = 15           ; auto-close after 15s
ON_TIMEOUT = "TALLY_VOTE"
```
```pawn
mc_set_menu_timer("VOTE", 10)     // change a live timer
mc_cancel_menu_timer("VOTE")      // stop it and close for everyone
```

### 13. Build a menu entirely in code

```pawn
mc_create_menu("MY_MENU", "\yMy menu")
mc_add_menu_item("MY_MENU", "Heal me",      _, _, "HEAL")
mc_add_menu_item("MY_MENU", "Give weapon",  _, _, "GIVE_GUN", _, _, _, 1) // blank line before
mc_show_menu(id, "MY_MENU")
```

### 14. Fixed-slot items (always at a given position)

```pawn
// Pin "Back to lobby" to slot 7 regardless of pagination.
mc_add_fixed_menu_item("SHOP", 7, "Back to lobby", _, "SHOW_LOBBY")
```

### 15. Refresh, lock, hide and introspect

```pawn
mc_refresh_menu("CHOOSE_TEAM LIST_SLAP")  // re-render for current viewers
mc_lock_menu(id, true)                    // block selections for a player
if (mc_get_active_menu(id) != -1) mc_hide_menu(id)
```

## Build environment

Built and tested with the AMX Mod X 1.9 compiler (`amxxpc 1.9.0.5294`), `reapi` and
the Universal Config System.
