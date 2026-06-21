/**
 * ================================================================================================
 *  Menu Core
 * ================================================================================================
 *
 *  Description:
 *	  Universal configuration-based menu system with support for dynamic menus,
 *	  conditional items, variant selection, restrictions, and placeholders.
 *
 *  Features:
 *	  - STRICT and LIST menu types
 *	  - Dynamic player lists with real-time filtering
 *	  - Conditional item visibility and variant selection
 *	  - Restriction system with custom validators
 *	  - Placeholder system for dynamic content
 *	  - Menu history and navigation
 *	  - Lifecycle callbacks (OnMenuOpen/OnMenuClose)
 *
 *  Version: 1.6.2
 *  Author:  kukson
 *  License: free to use and modify, keep the author credit.
 *
 * ================================================================================================
 */

/* ============================================================================================== */
/*                                          [ INCLUDES ]                                          */
/* ============================================================================================== */

#include <amxmodx>
#include <reapi>
#include <universal_config>

// TeamInfo trick constants
#define TEAM_FOR_RED   "TERRORIST"
#define TEAM_FOR_BLUE  "CT"
#define TEAM_FOR_GREY  "SPECTATOR"

/* ============================================================================================== */
/*                                     [ COMPILER SETTINGS ]                                      */
/* ============================================================================================== */

#define DEBUG 0

// Config file (without ".ini") and the reserved section holding chat prefix +
// button language keys. The MAIN section name is reserved (cannot be a menu).
#define MENU_CONFIG_FILE "menu"
#define MAIN_SECTION     "MAIN"

/* ============================================================================================== */
/*                                     [ CONSTANTS - LIMITS ]                                     */
/* ============================================================================================== */

#define MAX_MENU_ITEMS 7					// Maximum items per menu page
#define MAX_MENU_HISTORY 8				  // Maximum menu navigation history depth
#define MAX_MENU_RECURSION_DEPTH 5		  // Maximum recursion depth to prevent stack overflow

/* ============================================================================================== */
/*                                  [ CONSTANTS - BUFFER SIZES ]                                  */
/* ============================================================================================== */

#define NAME_LENGTH 64					  // Menu/item names, callbacks
#define CONDITION_LENGTH 128				// Condition expressions
#define ACTION_LENGTH 64					// Action names
#define PLACEHOLDER_LENGTH 32			   // Placeholder names
#define RESTRICT_LENGTH 32				  // Restriction names
#define RESTRICT_MSG_LENGTH 128			 // Restriction failure messages
#define LINES_LENGTH 8					  // Empty lines count

/* ============================================================================================== */
/*                                   [ CONSTANTS - CALCULATED ]                                   */
/* ============================================================================================== */

#define VARIANT_SIZE (NAME_LENGTH + CONDITION_LENGTH + ACTION_LENGTH)
#define MENU_ITEM_SIZE (MAX_VARIANTS * VARIANT_SIZE + 1 + PLACEHOLDER_LENGTH + RESTRICT_LENGTH + RESTRICT_MSG_LENGTH + LINES_LENGTH)
#define MENU_KEY_MASK (1<<0|1<<1|1<<2|1<<3|1<<4|1<<5|1<<6|1<<7|1<<8|1<<9)
#define TASK_REFRESH_MENU 1000
#define TASK_PLAYER_TIMEOUT 2000

// Sentinel stored in a registry's cached func-id cell meaning "not resolved yet".
// get_func_id() returns -1 (not found) or >= 0 (valid), so -2 is a safe sentinel.
#define FUNC_UNRESOLVED -2

// Built-in fallbacks for UI lang keys, used when a configured KEY/* (or PREFIX)
// is an ML key that is not registered (e.g. its dictionary plugin is disabled).
#define DEF_KEY_EXIT     "Exit"
#define DEF_KEY_BACK     "Back"
#define DEF_KEY_NEXT     "Next"
#define DEF_KEY_NUMBER   "\y[%d]\w"
#define DEF_KEY_DISABLED "\d[%d]"
#define DEF_KEY_PAGE     "\y[\r%d\y | \y%d\y]"
#define DEF_KEY_TIMER    "Time left \y[\r%d \wsec\y]"
#define DEF_CHAT_PREFIX  "!g[MenuCore]!y"
#define MENU_BUF_SIZE 1024				 // Main menu display buffer
#define ITEM_BUF_SIZE 256				  // Single item buffer

/* ============================================================================================== */
/*                                        [ ENUMERATIONS ]                                        */
/* ============================================================================================== */

enum MenuType {
	MENU_TYPE_STRICT,	// Static menu with predefined items
	MENU_TYPE_LIST	   // Dynamic menu with player lists
}

/* ============================================================================================== */
/*                                      [ DATA STRUCTURES ]                                       */
/* ============================================================================================== */

enum _:MenuDataStruct {
	MENU_SECTION[NAME_LENGTH],
	MENU_TITLE[NAME_LENGTH],
	MENU_ACTIVE_ON[CONDITION_LENGTH],
	Array:MENU_FILTERS_COND,
	Array:MENU_FILTERS_MSG,
	Array:MENU_ITEMS_ARRAY,
	Array:MENU_FIXED_ITEMS,
	MENU_REG_ID,
	bool:MENU_HIDE_BACK,
	bool:MENU_HIDE_EXIT,
	MenuType:MENU_TYPE,
	MENU_TIMER_DURATION,
	MENU_ON_TIMEOUT[ACTION_LENGTH],
	bool:MENU_LOCKED,
	bool:MENU_GLOBAL_TIMER
}

enum _:ConditionDataStruct {
	COND_NAME[CONDITION_LENGTH],
	COND_CALLBACK[NAME_LENGTH],
	COND_PLUGIN,
	COND_FUNC				// Cached get_func_id() result (FUNC_UNRESOLVED until first use)
}

enum _:ActionDataStruct {
	ACTION_NAME[ACTION_LENGTH],
	ACTION_CALLBACK[NAME_LENGTH],
	ACTION_PLUGIN,
	ACTION_FUNC				// Cached get_func_id() result
}

enum _:PlaceholderDataStruct {
	PLACE_NAME[NAME_LENGTH],
	PLACE_CALLBACK[NAME_LENGTH],
	PLACE_PLUGIN,
	PLACE_FUNC				// Cached get_func_id() result
}

enum _:RestrictionDataStruct {
	RESTRICT_NAME[NAME_LENGTH],
	RESTRICT_CALLBACK[NAME_LENGTH],
	RESTRICT_PLUGIN,
	RESTRICT_MESSAGE[RESTRICT_MSG_LENGTH],
	RESTRICT_FUNC			// Cached get_func_id() result
}

enum _:ActionConditionStruct {
	AC_MENU_SECTION[NAME_LENGTH],
	AC_ACTION_NAME[ACTION_LENGTH],
	AC_CALLBACK[NAME_LENGTH],
	AC_PLUGIN,
	AC_FUNC					// Cached get_func_id() result
}

enum _:ConditionFilterStruct {
	CF_COND_NAME[CONDITION_LENGTH],
	CF_CALLBACK[NAME_LENGTH],
	CF_PLUGIN,
	CF_FUNC					// Cached get_func_id() result
}

enum _:LifecycleCallbackStruct {
	LC_CALLBACK[NAME_LENGTH],
	LC_PLUGIN,
	LC_FUNC					// Cached get_func_id() result
}

enum _:DataSourceStruct {
	DS_MENU[NAME_LENGTH],
	DS_CALLBACK[NAME_LENGTH],
	DS_PLUGIN
}

enum _:MenuItemStruct {
	Array:ITEM_VARIANTS, // Array of VariantStruct
	ITEM_PLACEHOLDER[PLACEHOLDER_LENGTH],
	ITEM_RESTRICTION[RESTRICT_LENGTH],
	ITEM_RESTRICT_MSG[RESTRICT_MSG_LENGTH],
	ITEM_EMPTY_BEFORE,
	ITEM_EMPTY_AFTER
}

enum _:FixedItemStruct {
	FIXED_SLOT,
	FIXED_DATA[MenuItemStruct]
}

enum _:VariantStruct {
	VAR_NAME[NAME_LENGTH],
	VAR_CONDITION[CONDITION_LENGTH],
	VAR_ACTION[ACTION_LENGTH]
}

/* ============================================================================================== */
/*                           [ GLOBAL VARIABLES - MENU CONFIGURATION ]                            */
/* ============================================================================================== */

new ConfigFile:g_Config									 // Universal config handle
new Array:g_Menus										   // Array of MenuDataStruct
new Array:g_MenuActiveTimers								// Array of timers per menu index (parallel to g_Menus)
new g_ForwardMenuTimerExpired							   // Forward handle for timer expiration
new Trie:g_MenuTrie										 // Menu name -> index in g_Menus
new Trie:g_ConditionMenuMap								 // Condition -> Array of menu names

/* ============================================================================================== */
/*                           [ GLOBAL VARIABLES - DATA SOURCE SYSTEM ]                            */
/* ============================================================================================== */

new Array:g_DataSources									 // Array of DataSourceStruct
new Trie:g_DataSourceTrie								   // Menu name -> index in g_DataSources

new Array:g_Conditions									  // Array of ConditionDataStruct
new Trie:g_ConditionTrie									// UPPER(condition name) -> index in g_Conditions (first-wins)
new Array:g_Actions										 // Array of ActionDataStruct
new Trie:g_ActionTrie									   // action name -> index in g_Actions (first-wins, case-sensitive)
new Trie:g_CriticalActions								  // Critical actions that block menu

new Array:g_Placeholders									// Array of PlaceholderDataStruct
new Array:g_Restrictions									// Array of RestrictionDataStruct
new Trie:g_RestrictionTrie								  // UPPER(restriction name) -> index in g_Restrictions (first-wins)
new g_WildcardRestrictIdx = -1							  // Index of the "*" wildcard restriction (-1 if none)
new Array:g_ActionConditions
new Array:g_ConditionFilters

new Array:g_MenuOpenCallbacks							   // Array of LifecycleCallbackStruct
new Array:g_MenuCloseCallbacks							  // Array of LifecycleCallbackStruct
new Array:g_ShowFilters									   // Array of LifecycleCallbackStruct; veto a menu OPEN (mc_show_menu) before it renders

/* ============================================================================================== */
/*                              [ GLOBAL VARIABLES - PLAYER STATE ]                               */
/* ============================================================================================== */

new g_ActiveMenu[MAX_PLAYERS + 1] = { -1, ... } // Current active menu per player
new bool:g_ShouldAddToHistory[MAX_PLAYERS + 1]                  // Should current menu transition be added to history
new g_MenuTargetId[MAX_PLAYERS + 1]						 // Current active menu target index
new g_szMenu[MAX_PLAYERS + 1][MENU_BUF_SIZE]				  // Menu text buffer per player
new g_MenuHistory[MAX_PLAYERS + 1][MAX_MENU_HISTORY]		// Menu navigation history
new g_MenuHistoryPage[MAX_PLAYERS + 1][MAX_MENU_HISTORY]	// Page navigation history
new g_MenuHistoryDepth[MAX_PLAYERS + 1]					 // History depth per player
new g_MenuPage[MAX_PLAYERS + 1]						 // Current page for menus (pagination)
new g_MenuTotalItems[MAX_PLAYERS + 1]				   // Total items count for current menu
new g_ShowMenuDepth[MAX_PLAYERS + 1]						// Recursion depth tracking
new g_MenuItemTargetIds[MAX_PLAYERS + 1][MAX_MENU_ITEMS]	// TargetId for each displayed menu item
new g_MenuItemTypes[MAX_PLAYERS + 1][MAX_MENU_ITEMS]		// 0: Dynamic, 1: Fixed
new g_MenuItemActions[MAX_PLAYERS + 1][MAX_MENU_ITEMS][ACTION_LENGTH] // Custom Action for each item
new bool:g_IsItemDisabled[MAX_PLAYERS + 1][MAX_MENU_ITEMS]      // Disabled state for each slot
new bool:g_IsMenuLocked[MAX_PLAYERS + 1]					// Menu items lock state per player
new g_PlayerMenuTimer[MAX_PLAYERS + 1]					// Individual menu timer per player

/* ============================================================================================== */
/*                             [ GLOBAL VARIABLES - DISPLAY BUFFERS ]                             */
/* ============================================================================================== */
/* Static buffers used in mc_show_menu() to reduce stack usage */

static g_DisplayStrBuffer[ITEM_BUF_SIZE]

/* ============================================================================================== */
/*                                           [ ENUMS ]                                            */
/* ============================================================================================== */

enum {
    MP_LOCKED,           // 0 - Lock the menu (prevents it from being overwritten)
    MP_GLOBAL_TIMER,    // 1 - Use a global timer (shared by all players)
    MP_TIMER_DURATION,  // 2 - Default timer duration in seconds
    MP_HIDE_BACK,        // 3 - Hide the "Back" button
    MP_SECTION           // 4 - Get menu section name (for mc_get_menu_property_string)
};

new g_LangKeyExit[NAME_LENGTH] = DEF_KEY_EXIT // Exit button (overridable by config; this is the fallback)
new g_LangKeyBack[NAME_LENGTH] = DEF_KEY_BACK // Back button (overridable by config; this is the fallback)
new g_LangKeyNext[NAME_LENGTH] = DEF_KEY_NEXT // Next-page button (overridable by config; this is the fallback)
new g_LangKeyNumber[NAME_LENGTH] = DEF_KEY_NUMBER // Item numbering format (overridable by config; this is the fallback)
new g_LangKeyDisabled[NAME_LENGTH] = DEF_KEY_DISABLED // Disabled item format (overridable by config; this is the fallback)
new g_LangKeyPage[NAME_LENGTH] = DEF_KEY_PAGE // Page indicator format (overridable by config; this is the fallback)
new g_LangKeyTimer[NAME_LENGTH] = DEF_KEY_TIMER // Menu timer format (overridable by config; this is the fallback)
new g_ChatPrefix[128] = DEF_CHAT_PREFIX // Chat message prefix (overridable by config; this is the fallback)

/* ============================================================================================== */
/*                                      [ PLUGIN LIFECYCLE ]                                      */
/* ============================================================================================== */

public plugin_init() {
	register_plugin("Menu Core", "1.6.2", "kukson")
	g_Config = cfg_load_file(MENU_CONFIG_FILE)
	if (g_Config == CFG_FILE_INVALID) {
		#if DEBUG
			log_amx("[MenuSystem] Config load failed")
		#endif
		return
	}
	#if DEBUG
		log_amx("[MenuSystem] Config load succeeded: handle=%d", g_Config)
	#endif

	// Initialize dynamic arrays
	g_Menus = ArrayCreate(MenuDataStruct)
	g_MenuActiveTimers = ArrayCreate(1)
	g_Conditions = ArrayCreate(ConditionDataStruct)
	g_Actions = ArrayCreate(ActionDataStruct)
	g_Placeholders = ArrayCreate(PlaceholderDataStruct)
	g_Restrictions = ArrayCreate(RestrictionDataStruct)
	g_ActionConditions = ArrayCreate(ActionConditionStruct)
	g_ConditionFilters = ArrayCreate(ConditionFilterStruct)
	g_DataSources = ArrayCreate(DataSourceStruct)
	g_MenuOpenCallbacks = ArrayCreate(LifecycleCallbackStruct)
	g_MenuCloseCallbacks = ArrayCreate(LifecycleCallbackStruct)
	g_ShowFilters = ArrayCreate(LifecycleCallbackStruct)

	g_MenuTrie = TrieCreate()
	g_ConditionMenuMap = TrieCreate()
	g_CriticalActions = TrieCreate()
	g_DataSourceTrie = TrieCreate()
	g_ConditionTrie = TrieCreate()
	g_ActionTrie = TrieCreate()
	g_RestrictionTrie = TrieCreate()

	g_ForwardMenuTimerExpired = CreateMultiForward("mc_menu_timer_expired", ET_IGNORE, FP_STRING)

	for (new i = 0; i < sizeof(g_ActiveMenu); i++) {
		g_ActiveMenu[i] = -1
	}

	// Load language keys from the [MAIN] section
	new ConfigSection:mainSection = cfg_get_section(g_Config, MAIN_SECTION)
	if (mainSection != CFG_SECTION_INVALID) {
		new value[NAME_LENGTH]

		if (cfg_get_value_by_path(mainSection, "KEY/EXIT", value, sizeof(value) - 1, 0, 0)) {
			formatex(g_LangKeyExit, sizeof(g_LangKeyExit) - 1, "%s", value)
		}
		if (cfg_get_value_by_path(mainSection, "KEY/BACK", value, sizeof(value) - 1, 0, 0)) {
			formatex(g_LangKeyBack, sizeof(g_LangKeyBack) - 1, "%s", value)
		}
		if (cfg_get_value_by_path(mainSection, "KEY/NEXT", value, sizeof(value) - 1, 0, 0)) {
			formatex(g_LangKeyNext, sizeof(g_LangKeyNext) - 1, "%s", value)
		}
		if (cfg_get_value_by_path(mainSection, "KEY/NUMBER", value, sizeof(value) - 1, 0, 0)) {
			formatex(g_LangKeyNumber, sizeof(g_LangKeyNumber) - 1, "%s", value)
		}
		if (cfg_get_value_by_path(mainSection, "KEY/DISABLED", value, sizeof(value) - 1, 0, 0)) {
			formatex(g_LangKeyDisabled, sizeof(g_LangKeyDisabled) - 1, "%s", value)
		}
		if (cfg_get_value_by_path(mainSection, "KEY/PAGE", value, sizeof(value) - 1, 0, 0)) {
			formatex(g_LangKeyPage, sizeof(g_LangKeyPage) - 1, "%s", value)
		}
		if (cfg_get_value_by_path(mainSection, "KEY/TIME", value, sizeof(value) - 1, 0, 0)) {
			formatex(g_LangKeyTimer, sizeof(g_LangKeyTimer) - 1, "%s", value)
		}
		if (cfg_get_value_by_path(mainSection, "PREFIX", value, sizeof(value) - 1, 0, 0)) {
			formatex(g_ChatPrefix, sizeof(g_ChatPrefix) - 1, "%s", value)
		}
	}
}

public plugin_natives() {
	register_library("menu_core")
	register_native("mc_register_condition", "native_mc_register_condition")
	register_native("mc_register_menu", "native_mc_register_menu")
	register_native("mc_show_menu", "native_mc_show_menu")
	register_native("mc_register_action", "native_mc_register_action")
	register_native("mc_register_placeholder", "native_mc_register_placeholder")
	register_native("mc_notify_condition_changed", "native_mc_notify_condition_changed")
	register_native("mc_register_menu_open_callback", "native_mc_register_menu_open_callback")
	register_native("mc_register_menu_close_callback", "native_mc_register_menu_close_callback")
	register_native("mc_register_show_filter", "native_mc_register_show_filter")
	register_native("mc_register_restriction", "native_mc_register_restriction")
	register_native("mc_get_active_menu", "native_mc_get_active_menu")
	register_native("mc_get_menu_property_string", "native_mc_get_menu_property_string")
	register_native("mc_register_list_data_source", "native_mc_register_list_data_source")
	register_native("mc_cancel_menu_timer", "native_mc_cancel_menu_timer")
	register_native("mc_add_menu_item", "native_mc_add_menu_item")
	register_native("mc_set_menu_page", "native_mc_set_menu_page")
	register_native("mc_refresh_menu", "native_mc_refresh_menu")
	register_native("mc_clear_menu_items", "native_mc_clear_menu_items")
	register_native("mc_set_menu_timer", "native_mc_set_menu_timer")
	register_native("mc_lock_menu", "native_mc_lock_menu")
	register_native("mc_hide_menu", "native_mc_hide_menu")
	register_native("mc_is_menu_locked", "native_mc_is_menu_locked")
	register_native("mc_set_menu_property", "native_mc_set_menu_property")
	register_native("mc_set_menu_property_string", "native_mc_set_menu_property_string")
	register_native("mc_add_fixed_menu_item", "native_mc_add_fixed_menu_item")
	register_native("mc_add_list_text", "native_mc_add_list_text")
	register_native("mc_create_menu", "native_mc_create_menu")
	register_native("mc_register_action_condition", "native_mc_register_action_cond")
	register_native("mc_register_condition_filter", "native_mc_register_condition_filter")
}

public client_putinserver(id) {
	g_ActiveMenu[id] = -1
	g_MenuHistoryDepth[id] = 0
	g_MenuPage[id] = 0
	g_IsMenuLocked[id] = false
	remove_task(id + TASK_PLAYER_TIMEOUT)
}

public client_disconnected(id) {
	mc_internal_close_menu(id)
	g_MenuHistoryDepth[id] = 0
	if (g_ActiveMenu[id] != -1) {
		static szSection[NAME_LENGTH];
		new menu_data[MenuDataStruct]; ArrayGetArray(g_Menus, g_ActiveMenu[id], menu_data);
		copy(szSection, charsmax(szSection), menu_data[MENU_SECTION]);

		g_ActiveMenu[id] = -1
		g_szMenu[id][0] = 0
		for (new i = 0; i < MAX_MENU_HISTORY; i++) {
			g_MenuHistory[id][i] = 0
			g_MenuHistoryPage[id][i] = 0
		}
		g_IsMenuLocked[id] = false
		g_MenuTargetId[id] = 0
		remove_task(id + TASK_PLAYER_TIMEOUT)
		InvokeMenuCloseCallbacks(id, false, szSection)
		#if DEBUG
			log_amx("[MenuSystem] Cleared menu data for disconnected player %d", id)
		#endif
	}
}

/* ============================================================================================== */
/*                                   [ NATIVES - REGISTRATION ]                                   */
/* ============================================================================================== */

public native_mc_register_condition(plugin_id, num_params) {
	new cond_data[ConditionDataStruct]
	get_string(1, cond_data[COND_NAME], CONDITION_LENGTH - 1)
	get_string(2, cond_data[COND_CALLBACK], NAME_LENGTH - 1)
	cond_data[COND_PLUGIN] = plugin_id
	cond_data[COND_FUNC] = FUNC_UNRESOLVED

	#if DEBUG
		log_amx("[MenuSystem] Registered condition: %s, callback: %s, plugin: %d", cond_data[COND_NAME], cond_data[COND_CALLBACK], plugin_id)
	#endif
	new idx = ArrayPushArray(g_Conditions, cond_data)

	// Index by UPPER(name) for O(1) case-insensitive lookup; first registration wins.
	new key[CONDITION_LENGTH]; copy(key, charsmax(key), cond_data[COND_NAME]); strtoupper(key)
	if (!TrieKeyExists(g_ConditionTrie, key)) TrieSetCell(g_ConditionTrie, key, idx)

	return idx
}

public native_mc_register_action(plugin_id, num_params) {
	new action_data[ActionDataStruct]
	get_string(1, action_data[ACTION_NAME], ACTION_LENGTH - 1)
	get_string(2, action_data[ACTION_CALLBACK], NAME_LENGTH - 1)
	action_data[ACTION_PLUGIN] = plugin_id
	action_data[ACTION_FUNC] = FUNC_UNRESOLVED

	#if DEBUG
		log_amx("[MenuSystem] Registered action: %s, callback: %s, plugin: %d", action_data[ACTION_NAME], action_data[ACTION_CALLBACK], plugin_id)
	#endif
	new idx = ArrayPushArray(g_Actions, action_data)

	// Action names are matched case-sensitively (equal), so index by raw name; first-wins.
	if (!TrieKeyExists(g_ActionTrie, action_data[ACTION_NAME])) TrieSetCell(g_ActionTrie, action_data[ACTION_NAME], idx)

	return idx
}

public native_mc_register_action_cond(plugin_id, num_params) {
	new ac_data[ActionConditionStruct]
	get_string(1, ac_data[AC_MENU_SECTION], NAME_LENGTH - 1)
	get_string(2, ac_data[AC_ACTION_NAME], ACTION_LENGTH - 1)
	get_string(3, ac_data[AC_CALLBACK], NAME_LENGTH - 1)
	ac_data[AC_PLUGIN] = plugin_id
	ac_data[AC_FUNC] = FUNC_UNRESOLVED

	#if DEBUG
		log_amx("[MenuSystem] Registered action condition for Menu: '%s', Action: '%s', callback: %s, plugin: %d", ac_data[AC_MENU_SECTION], ac_data[AC_ACTION_NAME], ac_data[AC_CALLBACK], plugin_id)
	#endif
	return ArrayPushArray(g_ActionConditions, ac_data)
}

public native_mc_register_condition_filter(plugin_id, num_params) {
	new cf_data[ConditionFilterStruct]
	get_string(1, cf_data[CF_COND_NAME], CONDITION_LENGTH - 1)
	get_string(2, cf_data[CF_CALLBACK], NAME_LENGTH - 1)
	cf_data[CF_PLUGIN] = plugin_id
	cf_data[CF_FUNC] = FUNC_UNRESOLVED

	#if DEBUG
		log_amx("[MenuSystem] Registered condition filter for: %s, callback: %s, plugin: %d", cf_data[CF_COND_NAME], cf_data[CF_CALLBACK], plugin_id)
	#endif
	return ArrayPushArray(g_ConditionFilters, cf_data)
}

public native_mc_register_placeholder(plugin_id, num_params) {
	new place_data[PlaceholderDataStruct]
	get_string(1, place_data[PLACE_NAME], NAME_LENGTH - 1)
	get_string(2, place_data[PLACE_CALLBACK], NAME_LENGTH - 1)
	place_data[PLACE_PLUGIN] = plugin_id
	place_data[PLACE_FUNC] = FUNC_UNRESOLVED

	for (new i = 0, size = ArraySize(g_Placeholders); i < size; i++) {
		new temp[PlaceholderDataStruct]
		ArrayGetArray(g_Placeholders, i, temp)
		if (equal(temp[PLACE_NAME], place_data[PLACE_NAME])) {
			#if DEBUG
				log_amx("[MenuSystem] Placeholder already registered: %s", place_data[PLACE_NAME])
			#endif
			return i
		}
	}

	#if DEBUG
		log_amx("[MenuSystem] Registered placeholder: %s, callback: %s, plugin: %d", place_data[PLACE_NAME], place_data[PLACE_CALLBACK], plugin_id)
	#endif
	return ArrayPushArray(g_Placeholders, place_data)
}

public native_mc_register_menu(plugin_id, num_params) {
	new section[NAME_LENGTH]
	get_string(1, section, sizeof(section) - 1)
	return mc_register_menu(section)
}

public native_mc_register_restriction(plugin_id, num_params) {
	new rest_data[RestrictionDataStruct]
	get_string(1, rest_data[RESTRICT_NAME], NAME_LENGTH - 1)
	get_string(2, rest_data[RESTRICT_CALLBACK], NAME_LENGTH - 1)

	if (num_params >= 3) {
		get_string(3, rest_data[RESTRICT_MESSAGE], RESTRICT_MSG_LENGTH - 1)
	} else {
		rest_data[RESTRICT_MESSAGE][0] = 0
	}

	rest_data[RESTRICT_PLUGIN] = plugin_id
	rest_data[RESTRICT_FUNC] = FUNC_UNRESOLVED
	#if DEBUG
		log_amx("[MenuSystem] Registered restriction: %s, callback: %s, plugin: %d, message: %s", rest_data[RESTRICT_NAME], rest_data[RESTRICT_CALLBACK], plugin_id, rest_data[RESTRICT_MESSAGE])
	#endif
	new idx = ArrayPushArray(g_Restrictions, rest_data)

	if (equal(rest_data[RESTRICT_NAME], "*")) {
		// Single wildcard handler; first-wins to mirror the old linear-scan order.
		if (g_WildcardRestrictIdx == -1) g_WildcardRestrictIdx = idx
	} else {
		// Index by UPPER(name): matching is case-insensitive (equali); first-wins.
		new key[NAME_LENGTH]; copy(key, charsmax(key), rest_data[RESTRICT_NAME]); strtoupper(key)
		if (!TrieKeyExists(g_RestrictionTrie, key)) TrieSetCell(g_RestrictionTrie, key, idx)
	}

	return idx
}

public native_mc_register_list_data_source(plugin_id, num_params) {
	new ds_data[DataSourceStruct]
	get_string(1, ds_data[DS_MENU], NAME_LENGTH - 1)
	get_string(2, ds_data[DS_CALLBACK], NAME_LENGTH - 1)
	ds_data[DS_PLUGIN] = plugin_id

	new existingIdx
	if (TrieGetCell(g_DataSourceTrie, ds_data[DS_MENU], existingIdx)) {
		#if DEBUG
			log_amx("[MenuSystem] Data source already registered for menu: %s, replacing", ds_data[DS_MENU])
		#endif
		ArraySetArray(g_DataSources, existingIdx, ds_data)
		return existingIdx
	}

	existingIdx = ArrayPushArray(g_DataSources, ds_data)
	TrieSetCell(g_DataSourceTrie, ds_data[DS_MENU], existingIdx)

	return existingIdx;
}

public native_mc_register_menu_open_callback(plugin_id, num_params) {
	new callback_data[LifecycleCallbackStruct]
	get_string(1, callback_data[LC_CALLBACK], NAME_LENGTH - 1)
	callback_data[LC_PLUGIN] = plugin_id
	callback_data[LC_FUNC] = FUNC_UNRESOLVED

	#if DEBUG
		log_amx("[MenuSystem] Registered menu open callback: %s, plugin: %d", callback_data[LC_CALLBACK], plugin_id)
	#endif
	return ArrayPushArray(g_MenuOpenCallbacks, callback_data)
}

public native_mc_register_show_filter(plugin_id, num_params) {
	new callback_data[LifecycleCallbackStruct]
	get_string(1, callback_data[LC_CALLBACK], NAME_LENGTH - 1)
	callback_data[LC_PLUGIN] = plugin_id
	callback_data[LC_FUNC] = FUNC_UNRESOLVED

	#if DEBUG
		log_amx("[MenuSystem] Registered show filter: %s, plugin: %d", callback_data[LC_CALLBACK], plugin_id)
	#endif
	return ArrayPushArray(g_ShowFilters, callback_data)
}

public native_mc_register_menu_close_callback(plugin_id, num_params) {
	new callback_data[LifecycleCallbackStruct]
	get_string(1, callback_data[LC_CALLBACK], NAME_LENGTH - 1)
	callback_data[LC_PLUGIN] = plugin_id
	callback_data[LC_FUNC] = FUNC_UNRESOLVED

	#if DEBUG
		log_amx("[MenuSystem] Registered menu close callback: %s, plugin: %d", callback_data[LC_CALLBACK], plugin_id)
	#endif
	return ArrayPushArray(g_MenuCloseCallbacks, callback_data)
}

/* ============================================================================================== */
/*                                   [ NATIVES - MENU CONTROL ]                                   */
/* ============================================================================================== */

public native_mc_show_menu(plugin_id, num_params) {
	new id = get_param(1)
	new section[NAME_LENGTH]; get_string(2, section, sizeof(section) - 1)
	new time = (num_params >= 3) ? get_param(3) : -1
	new targetId = (num_params >= 4) ? get_param(4) : 0
	new bool:resetHistory = (num_params >= 5) ? (bool:get_param(5)) : false
	new bool:forceOpen = (num_params >= 6) ? (bool:get_param(6)) : false
	new bool:ignoreHistory = (num_params >= 7) ? (bool:get_param(7)) : false

	return mc_show_menu(id, section, time, ignoreHistory, resetHistory, targetId, forceOpen)
}

public native_mc_get_active_menu(plugin_id, num_params) {
	new id = get_param(1)
	new retVal = -1
	if (is_user_connected(id)) {
		retVal = g_ActiveMenu[id]
	}
	return retVal
}

public native_mc_set_menu_property_string(plugin_id, num_params) {
	new section[NAME_LENGTH]; get_string(1, section, charsmax(section))
	new property = get_param(2)
	new value[256]; get_string(3, value, charsmax(value))

	new menuIdx; if (!TrieGetCell(g_MenuTrie, section, menuIdx)) return 0
	new menu_data[MenuDataStruct]; ArrayGetArray(g_Menus, menuIdx, menu_data)

	switch (property) {
		case 5: copy(menu_data[MENU_ON_TIMEOUT], ACTION_LENGTH - 1, value) // MP_ON_TIMEOUT (Action name)
		case 6: { // MP_ACTIVE_ON (visibility condition)
			copy(menu_data[MENU_ACTIVE_ON], CONDITION_LENGTH - 1, value)
			if (value[0]) AddMenuToConditionMap(value, section)
		}
		case 7: { // MP_FILTER
			if (menu_data[MENU_TYPE] == MENU_TYPE_LIST) {
				if (menu_data[MENU_FILTERS_COND] == Invalid_Array) {
					menu_data[MENU_FILTERS_COND] = ArrayCreate(CONDITION_LENGTH);
				}
				if (menu_data[MENU_FILTERS_MSG] == Invalid_Array) {
					menu_data[MENU_FILTERS_MSG] = ArrayCreate(NAME_LENGTH);
				}
				
				new condStr[CONDITION_LENGTH], msgStr[NAME_LENGTH];
				new pipePos = contain(value, "|");
				if (pipePos != -1) {
					copy(condStr, pipePos, value);
					copy(msgStr, charsmax(msgStr), value[pipePos + 1]);
				} else {
					copy(condStr, charsmax(condStr), value);
					msgStr[0] = 0;
				}
				trim(condStr);
				trim(msgStr);
				
				if (condStr[0]) {
					RegisterConditionTokens(condStr, section);
					
					ArrayPushString(menu_data[MENU_FILTERS_COND], condStr);
					ArrayPushString(menu_data[MENU_FILTERS_MSG], msgStr);
				}
			}
		}
		default: return 0
	}

	ArraySetArray(g_Menus, menuIdx, menu_data)
	return 1
}

public native_mc_get_menu_property_string(plugin_id, num_params) {
	new menuIdx = get_param(1)
	if (menuIdx < 0 || menuIdx >= ArraySize(g_Menus)) return 0

	new property = get_param(2)
	new menu_data[MenuDataStruct]; ArrayGetArray(g_Menus, menuIdx, menu_data)

	if (property == MP_SECTION) {
		set_string(3, menu_data[MENU_SECTION], get_param(4))
		return 1
	}
	return 0
}

public native_mc_set_menu_property(plugin_id, num_params) {
	new section[NAME_LENGTH]; get_string(1, section, charsmax(section))
	new property = get_param(2)
	new value = get_param(3)

	new menuIdx; if (!TrieGetCell(g_MenuTrie, section, menuIdx)) return 0
	new menu_data[MenuDataStruct]; ArrayGetArray(g_Menus, menuIdx, menu_data)

	switch (property) {
		case 0: menu_data[MENU_LOCKED] = bool:value	 // MP_LOCKED
		case 1: menu_data[MENU_GLOBAL_TIMER] = bool:value // MP_GLOBAL_TIMER
		case 2: menu_data[MENU_TIMER_DURATION] = value	// MP_TIMER_DURATION
		case 3: menu_data[MENU_HIDE_BACK] = bool:value	// MP_HIDE_BACK
		case 4: menu_data[MENU_HIDE_EXIT] = bool:value	// MP_HIDE_EXIT
		default: return 0
	}

	ArraySetArray(g_Menus, menuIdx, menu_data)
	return 1
}

public native_mc_set_menu_timer(plugin_id, num_params) {
	new section[NAME_LENGTH]
	get_string(1, section, sizeof(section) - 1)
	new time = get_param(2)

	new menuIdx
	if (!TrieGetCell(g_MenuTrie, section, menuIdx)) return 0

	new activeTimer = ArrayGetCell(g_MenuActiveTimers, menuIdx)

	if (activeTimer == 0 && time > 0) {
		ArraySetCell(g_MenuActiveTimers, menuIdx, time)

		new menu_data[MenuDataStruct]; ArrayGetArray(g_Menus, menuIdx, menu_data)
		menu_data[MENU_GLOBAL_TIMER] = true
		ArraySetArray(g_Menus, menuIdx, menu_data)

		set_task(1.0, "GlobalMenuTimerTask", menuIdx, _, _, "b")
		mc_refresh_menu(section)
		return 1
	} else if (activeTimer > 0) {
		ArraySetCell(g_MenuActiveTimers, menuIdx, time)
		if (time == 0) {
			GlobalMenuTimerTask(menuIdx)
		} else {
			mc_refresh_menu(section)
		}
		return 1
	}

	return 0
}

public native_mc_notify_condition_changed(plugin_id, num_params) {
	new condition[NAME_LENGTH]
	get_string(1, condition, sizeof(condition) - 1)
	mc_notify_condition_changed(condition)
}

public native_mc_refresh_menu(plugin_id, num_params) {
	new sections[512]
	get_string(1, sections, sizeof(sections) - 1)
	return mc_refresh_menu(sections)
}

public native_mc_cancel_menu_timer(plugin_id, num_params) {
	new section[NAME_LENGTH]
	get_string(1, section, sizeof(section) - 1)

	new menuIdx
	new retVal = 0
	if (TrieGetCell(g_MenuTrie, section, menuIdx)) {
		retVal = InternalCancelMenuTimer(menuIdx)
	}
	return retVal
}

public native_mc_lock_menu(plugin_id, num_params) {
	new id = get_param(1)
	if (!is_user_connected(id)) return

	g_IsMenuLocked[id] = bool:get_param(2)
	#if DEBUG
		log_amx("[MenuSystem] Menu %s for player %d", g_IsMenuLocked[id] ? "LOCKED" : "UNLOCKED", id)
	#endif
}

public native_mc_hide_menu(plugin_id, num_params) {
	new id = get_param(1)
	if (!is_user_connected(id)) return
	mc_internal_close_menu(id)
}

public native_mc_set_menu_page(plugin_id, num_params) {
	new id = get_param(1)
	if (!is_user_connected(id)) return
	new page = get_param(2)
	g_MenuPage[id] = page
}

public bool:native_mc_is_menu_locked(plugin_id, num_params) {
	new id = get_param(1)
	new bool:retVal = false
	if (is_user_connected(id)) {
		retVal = g_IsMenuLocked[id]
	}
	return retVal
}

public native_mc_add_menu_item(plugin_id, num_params) {
    new section[NAME_LENGTH]; get_string(1, section, charsmax(section))
    new menuIdx; if (!TrieGetCell(g_MenuTrie, section, menuIdx)) return 0

    new menu_data[MenuDataStruct]; ArrayGetArray(g_Menus, menuIdx, menu_data)

    new item_data[MenuItemStruct]
    get_string(3, item_data[ITEM_PLACEHOLDER], PLACEHOLDER_LENGTH - 1)
    new condStr[CONDITION_LENGTH], actStr[ACTION_LENGTH]
    get_string(4, condStr, charsmax(condStr))
    get_string(5, actStr, charsmax(actStr))
    get_string(6, item_data[ITEM_RESTRICTION], RESTRICT_LENGTH - 1)
    get_string(7, item_data[ITEM_RESTRICT_MSG], RESTRICT_MSG_LENGTH - 1)

    new name[256]; get_string(2, name, charsmax(name))

    item_data[ITEM_VARIANTS] = ArrayCreate(VariantStruct)
    new varCount = ParseVariantsToPool(name, condStr, actStr, item_data[ITEM_VARIANTS])

    if (varCount > 0) {
        for (new i = 0; i < varCount; i++) {
            new var[VariantStruct]; ArrayGetArray(item_data[ITEM_VARIANTS], i, var)
            if (var[VAR_CONDITION][0]) {
                RegisterConditionTokens(var[VAR_CONDITION], section)
            }
        }
        new iPosition = (num_params >= 8) ? get_param(8) : -1
        item_data[ITEM_EMPTY_BEFORE] = (num_params >= 9) ? get_param(9) : 0
        item_data[ITEM_EMPTY_AFTER] = (num_params >= 10) ? get_param(10) : 0
        new size = ArraySize(menu_data[MENU_ITEMS_ARRAY])
        if (iPosition >= 0 && iPosition < size) {
            ArrayInsertArrayBefore(menu_data[MENU_ITEMS_ARRAY], iPosition, item_data)
        } else {
            ArrayPushArray(menu_data[MENU_ITEMS_ARRAY], item_data)
        }
        ArraySetArray(g_Menus, menuIdx, menu_data)
        return 1
    } else {
        ArrayDestroy(item_data[ITEM_VARIANTS])
    }

    return 0
}

public native_mc_add_fixed_menu_item(plugin_id, num_params) {
    new section[NAME_LENGTH]; get_string(1, section, charsmax(section))
    new menuIdx; if (!TrieGetCell(g_MenuTrie, section, menuIdx)) return 0

    new menu_data[MenuDataStruct]; ArrayGetArray(g_Menus, menuIdx, menu_data)
    if (menu_data[MENU_FIXED_ITEMS] == Invalid_Array) {
        menu_data[MENU_FIXED_ITEMS] = ArrayCreate(FixedItemStruct)
    }

    new fixed_item[FixedItemStruct]
    fixed_item[FIXED_SLOT] = get_param(2) - 1 // 1-7 -> 0-6

    new name[256], actStr[ACTION_LENGTH], condStr[CONDITION_LENGTH]
    get_string(3, name, charsmax(name))
    get_string(4, fixed_item[FIXED_DATA][ITEM_PLACEHOLDER], PLACEHOLDER_LENGTH - 1)
    get_string(5, actStr, charsmax(actStr))
    get_string(6, condStr, charsmax(condStr))
    get_string(7, fixed_item[FIXED_DATA][ITEM_RESTRICTION], RESTRICT_LENGTH - 1)
    fixed_item[FIXED_DATA][ITEM_EMPTY_BEFORE] = get_param(8)
    fixed_item[FIXED_DATA][ITEM_EMPTY_AFTER] = get_param(9)

    fixed_item[FIXED_DATA][ITEM_VARIANTS] = ArrayCreate(VariantStruct)
    new varCount = ParseVariantsToPool(name, condStr, actStr, fixed_item[FIXED_DATA][ITEM_VARIANTS])

    if (varCount > 0) {
        ArrayPushArray(menu_data[MENU_FIXED_ITEMS], fixed_item)
        ArraySetArray(g_Menus, menuIdx, menu_data)
        return 1
    } else {
        ArrayDestroy(fixed_item[FIXED_DATA][ITEM_VARIANTS])
    }

    return 0
}

public native_mc_add_list_text(plugin_id, num_params) {
    new Array:aItems = Array:get_param(1);
    new text[256]; get_string(2, text, charsmax(text));
    new bool:centered = bool:get_param(3);

    new item[289];
    item[0] = -2; // TEXT_ONLY marker

    if (centered) {
        new len = strlen(text);
        new spaces = (42 - len) / 2;
        if (spaces > 0) {
            new szTemp[256];
            for (new i = 0; i < spaces; i++) szTemp[i] = ' ';
            szTemp[spaces] = 0;
            add(szTemp, charsmax(szTemp), text);
            copy(item[65], 63, szTemp);
        } else {
            copy(item[65], 63, text);
        }
    } else {
        copy(item[65], 63, text);
    }

    ArrayPushArray(aItems, item);
    return 1;
}

public native_mc_clear_menu_items(plugin_id, num_params) {
    new section[NAME_LENGTH]; get_string(1, section, charsmax(section))
    new menuIdx; if (!TrieGetCell(g_MenuTrie, section, menuIdx)) return 0

    new menu_data[MenuDataStruct]; ArrayGetArray(g_Menus, menuIdx, menu_data)

    new Array:items = menu_data[MENU_ITEMS_ARRAY]
    for (new i = 0, size = ArraySize(items); i < size; i++) {
        new item[MenuItemStruct]; ArrayGetArray(items, i, item)
        ArrayDestroy(item[ITEM_VARIANTS])
    }
    ArrayClear(items)

    if (menu_data[MENU_FIXED_ITEMS] != Invalid_Array) {
        new Array:fixed = menu_data[MENU_FIXED_ITEMS]
        for (new i = 0, size = ArraySize(fixed); i < size; i++) {
            new item[FixedItemStruct]; ArrayGetArray(fixed, i, item)
            ArrayDestroy(item[FIXED_DATA][ITEM_VARIANTS])
        }
        ArrayClear(fixed)
    }

    return 1
}

public native_mc_create_menu(plugin_id, num_params) {
    new section[NAME_LENGTH]; get_string(1, section, charsmax(section))
    new title[256]; get_string(2, title, charsmax(title))

    if (TrieKeyExists(g_MenuTrie, section)) return 0

    new menu_data[MenuDataStruct]
    copy(menu_data[MENU_SECTION], NAME_LENGTH - 1, section)
    copy(menu_data[MENU_TITLE], 255, title)
    menu_data[MENU_TYPE] = equal(section, "LIST_", 5) ? MENU_TYPE_LIST : MENU_TYPE_STRICT
    menu_data[MENU_ITEMS_ARRAY] = ArrayCreate(MenuItemStruct)
    menu_data[MENU_FIXED_ITEMS] = Invalid_Array
    menu_data[MENU_FILTERS_COND] = Invalid_Array
    menu_data[MENU_FILTERS_MSG] = Invalid_Array

    new menuIdx = ArrayPushArray(g_Menus, menu_data)
    TrieSetCell(g_MenuTrie, section, menuIdx)
    ArrayPushCell(g_MenuActiveTimers, 0)

    // Crucial: Register the menu with AMXModX so HandleMenu catches the key presses
    register_menucmd(register_menuid(section), MENU_KEY_MASK, "HandleMenu")

    return 1
}

/* ============================================================================================== */
/*                              [ CORE - MENU REGISTRATION & FLOW ]                               */
/* ============================================================================================== */

stock mc_register_menu(const section[]) {
	new menuIdx
	if (TrieGetCell(g_MenuTrie, section, menuIdx)) return menuIdx

	if (equali(section, MAIN_SECTION)) return -1

	if (g_Config == CFG_FILE_INVALID) {
		g_Config = cfg_load_file(MENU_CONFIG_FILE)
	}

	if (g_Config == CFG_FILE_INVALID) return -1

	new ConfigSection:cfgSection = cfg_get_section(g_Config, section)
	if (cfgSection == CFG_SECTION_INVALID) return -1

	new menu_data[MenuDataStruct]
	copy(menu_data[MENU_SECTION], NAME_LENGTH - 1, section)

	if (!cfg_get_value(cfgSection, "TITLE", menu_data[MENU_TITLE], NAME_LENGTH - 1)) {
		return -1
	}

	menu_data[MENU_TYPE] = equal(section, "LIST_", 5) ? MENU_TYPE_LIST : MENU_TYPE_STRICT
	menu_data[MENU_FIXED_ITEMS] = Invalid_Array
	menu_data[MENU_FILTERS_COND] = Invalid_Array
	menu_data[MENU_FILTERS_MSG] = Invalid_Array

	// ACTIVE_ON
	new activeOn[CONDITION_LENGTH], tempVal[CONDITION_LENGTH]
	new valCount = cfg_get_array_size(cfgSection, "ACTIVE_ON")
	activeOn[0] = 0

	if (valCount > 0) {
		for (new v = 0; v < valCount; v++) {
			if (cfg_get_value(cfgSection, "ACTIVE_ON", tempVal, sizeof(tempVal) - 1, v)) {
				if (v > 0) add(activeOn, sizeof(activeOn) - 1, " ")
				add(activeOn, sizeof(activeOn) - 1, tempVal)
			}
		}

		if (activeOn[0]) {
			copy(menu_data[MENU_ACTIVE_ON], CONDITION_LENGTH - 1, activeOn)

			// Register conditions for automatic refresh
			RegisterConditionTokens(activeOn, section)
		}
	}

	// HIDE_BACK
	new hideBackStr[8]
	if (cfg_get_value(cfgSection, "HIDE_BACK", hideBackStr, sizeof(hideBackStr) - 1)) {
		menu_data[MENU_HIDE_BACK] = ParseBoolFlag(hideBackStr)
	}

	// HIDE_EXIT
	new hideExitStr[8]
	if (cfg_get_value(cfgSection, "HIDE_EXIT", hideExitStr, sizeof(hideExitStr) - 1)) {
		menu_data[MENU_HIDE_EXIT] = ParseBoolFlag(hideExitStr)
	}

	// TIME
	new timeStr[8]
	if (cfg_get_value(cfgSection, "TIME", timeStr, sizeof(timeStr) - 1)) {
		menu_data[MENU_TIMER_DURATION] = str_to_num(timeStr)
	}

	// ON_TIMEOUT
	cfg_get_value(cfgSection, "ON_TIMEOUT", menu_data[MENU_ON_TIMEOUT], ACTION_LENGTH - 1)

	// LOCKED
	new lockedStr[8]
	if (cfg_get_value(cfgSection, "LOCKED", lockedStr, sizeof(lockedStr) - 1)) {
		menu_data[MENU_LOCKED] = ParseBoolFlag(lockedStr)
	}

	// GLOBAL
	new globalStr[8]
	if (cfg_get_value(cfgSection, "GLOBAL", globalStr, sizeof(globalStr) - 1)) {
		menu_data[MENU_GLOBAL_TIMER] = ParseBoolFlag(globalStr)
	}

	menu_data[MENU_ITEMS_ARRAY] = ArrayCreate(MenuItemStruct)
	menu_data[MENU_FIXED_ITEMS] = Invalid_Array
	new itemCount = 0

	if (menu_data[MENU_TYPE] == MENU_TYPE_LIST) {
		// FILTER
		menu_data[MENU_FILTERS_COND] = ArrayCreate(CONDITION_LENGTH)
		menu_data[MENU_FILTERS_MSG] = ArrayCreate(NAME_LENGTH)

		new rowIndex = 0
		while (rowIndex >= 0) {
			new Array:filterArray = cfg_get_value_array_by_path(cfgSection, "FILTER", 0, rowIndex)
			if (filterArray == Invalid_Array) break

			if (ArraySize(filterArray) > 0) {
				new condStr[CONDITION_LENGTH], msgStr[NAME_LENGTH]
				ArrayGetString(filterArray, 0, condStr, charsmax(condStr))
				
				if (condStr[0]) {
					RegisterConditionTokens(condStr, section)
					
					ArrayPushString(menu_data[MENU_FILTERS_COND], condStr)
					
					if (ArraySize(filterArray) > 1) {
						ArrayGetString(filterArray, 1, msgStr, charsmax(msgStr))
					} else {
						msgStr[0] = 0
					}
					ArrayPushString(menu_data[MENU_FILTERS_MSG], msgStr)
				}
			}
			ArrayDestroy(filterArray)
			rowIndex++
		}

		// VIEW
		new Array:viewArray = cfg_get_value_array_by_path(cfgSection, "VIEW", 0, 0)
		if (viewArray != Invalid_Array && ArraySize(viewArray) > 0) {
			new item_data[MenuItemStruct]
			new nameStr[256], condStr[256], actStr[256]

			ArrayGetString(viewArray, 0, nameStr, 255)
			ArrayGetString(viewArray, 1, condStr, 255)
			ArrayGetString(viewArray, 2, actStr, 255)
			ArrayGetString(viewArray, 3, item_data[ITEM_RESTRICTION], RESTRICT_LENGTH - 1)
			ArrayGetString(viewArray, 4, item_data[ITEM_RESTRICT_MSG], RESTRICT_MSG_LENGTH - 1)
			ArrayDestroy(viewArray)

			item_data[ITEM_VARIANTS] = ArrayCreate(VariantStruct)
			new varCount = ParseVariantsToPool(nameStr, condStr, actStr, item_data[ITEM_VARIANTS])

			if (varCount > 0) {
				// Register variant conditions for refresh
				for (new i = 0; i < varCount; i++) {
					new var[VariantStruct]
					ArrayGetArray(item_data[ITEM_VARIANTS], i, var)
					if (var[VAR_CONDITION][0]) {
						RegisterConditionTokens(var[VAR_CONDITION], section)
					}
				}
				ArrayPushArray(menu_data[MENU_ITEMS_ARRAY], item_data)
				itemCount = 1
			} else {
				ArrayDestroy(item_data[ITEM_VARIANTS])
			}
		}

		// FIXED_ITEMS
		static parsedSlot[8], fixedNameStr[256], fixedCondStr[256], fixedActStr[256], fixedTemp[512]
		menu_data[MENU_FIXED_ITEMS] = ArrayCreate(FixedItemStruct)

		for (new line = 0; cfg_get_value_by_path(cfgSection, "FIXED_ITEMS", parsedSlot, 7, 0, line); line++) {
			new fixed_item[FixedItemStruct]
			fixed_item[FIXED_SLOT] = str_to_num(parsedSlot) - 1

			cfg_get_value_by_path(cfgSection, "FIXED_ITEMS", fixedNameStr, 255, 1, line)
			cfg_get_value_by_path(cfgSection, "FIXED_ITEMS", fixed_item[FIXED_DATA][ITEM_PLACEHOLDER], PLACEHOLDER_LENGTH - 1, 2, line)
			cfg_get_value_by_path(cfgSection, "FIXED_ITEMS", fixedCondStr, 255, 3, line)
			cfg_get_value_by_path(cfgSection, "FIXED_ITEMS", fixedActStr, 255, 4, line)
			cfg_get_value_by_path(cfgSection, "FIXED_ITEMS", fixed_item[FIXED_DATA][ITEM_RESTRICTION], RESTRICT_LENGTH - 1, 5, line)
			cfg_get_value_by_path(cfgSection, "FIXED_ITEMS", fixed_item[FIXED_DATA][ITEM_RESTRICT_MSG], RESTRICT_MSG_LENGTH - 1, 6, line)

			if (cfg_get_value_by_path(cfgSection, "FIXED_ITEMS", fixedTemp, 511, 7, line)) {
				new b[8], a[8]
				if (parse(fixedTemp, b, 7, a, 7) == 1) {
					fixed_item[FIXED_DATA][ITEM_EMPTY_BEFORE] = 0
					fixed_item[FIXED_DATA][ITEM_EMPTY_AFTER] = str_to_num(b)
				} else {
					fixed_item[FIXED_DATA][ITEM_EMPTY_BEFORE] = str_to_num(b)
					fixed_item[FIXED_DATA][ITEM_EMPTY_AFTER] = str_to_num(a)
				}
			}

			fixed_item[FIXED_DATA][ITEM_VARIANTS] = ArrayCreate(VariantStruct)
			new fVarCount = ParseVariantsToPool(fixedNameStr, fixedCondStr, fixedActStr, fixed_item[FIXED_DATA][ITEM_VARIANTS])

			if (fVarCount > 0) {
				for (new i = 0; i < fVarCount; i++) {
					new var[VariantStruct]
					ArrayGetArray(fixed_item[FIXED_DATA][ITEM_VARIANTS], i, var)
					if (var[VAR_CONDITION][0]) {
						RegisterConditionTokens(var[VAR_CONDITION], section)
					}
				}
				ArrayPushArray(menu_data[MENU_FIXED_ITEMS], fixed_item)
				itemCount++
			} else {
				ArrayDestroy(fixed_item[FIXED_DATA][ITEM_VARIANTS])
			}
		}
	} else {
		// ITEMS STRICT
		static nameStr[256], condStr[256], actStr[256], szTemp[512]
		for (new line = 0; cfg_get_value_by_path(cfgSection, "ITEMS", nameStr, 255, 0, line); line++) {

			new item_data[MenuItemStruct]
			cfg_get_value_by_path(cfgSection, "ITEMS", item_data[ITEM_PLACEHOLDER], PLACEHOLDER_LENGTH - 1, 1, line)
			cfg_get_value_by_path(cfgSection, "ITEMS", condStr, 255, 2, line)
			cfg_get_value_by_path(cfgSection, "ITEMS", actStr, 255, 3, line)
			cfg_get_value_by_path(cfgSection, "ITEMS", item_data[ITEM_RESTRICTION], RESTRICT_LENGTH - 1, 4, line)
			cfg_get_value_by_path(cfgSection, "ITEMS", item_data[ITEM_RESTRICT_MSG], RESTRICT_MSG_LENGTH - 1, 5, line)

			if (cfg_get_value_by_path(cfgSection, "ITEMS", szTemp, 511, 6, line)) {
				new b[8], a[8]
				if (parse(szTemp, b, 7, a, 7) == 1) {
					item_data[ITEM_EMPTY_BEFORE] = 0
					item_data[ITEM_EMPTY_AFTER] = str_to_num(b)
				} else {
					item_data[ITEM_EMPTY_BEFORE] = str_to_num(b)
					item_data[ITEM_EMPTY_AFTER] = str_to_num(a)
				}
			}

			item_data[ITEM_VARIANTS] = ArrayCreate(VariantStruct)
			new varCount = ParseVariantsToPool(nameStr, condStr, actStr, item_data[ITEM_VARIANTS])

			if (varCount > 0) {
				for (new i = 0; i < varCount; i++) {
					new var[VariantStruct]
					ArrayGetArray(item_data[ITEM_VARIANTS], i, var)
					if (var[VAR_CONDITION][0]) {
						RegisterConditionTokens(var[VAR_CONDITION], section)
					}
				}
				ArrayPushArray(menu_data[MENU_ITEMS_ARRAY], item_data)
				itemCount++
			} else {
				ArrayDestroy(item_data[ITEM_VARIANTS])
			}

		}
	}

	if (!itemCount) {
		log_amx("[MenuSystem] ERROR: No items found for menu section '%s'", section)
		ArrayDestroy(menu_data[MENU_ITEMS_ARRAY])
		if (menu_data[MENU_FIXED_ITEMS] != Invalid_Array) {
			ArrayDestroy(menu_data[MENU_FIXED_ITEMS])
		}
		return -1
	}

	menu_data[MENU_REG_ID] = register_menuid(section)
	menuIdx = ArrayPushArray(g_Menus, menu_data)
	ArrayPushCell(g_MenuActiveTimers, 0)
	TrieSetCell(g_MenuTrie, section, menuIdx)
	register_menucmd(menu_data[MENU_REG_ID], MENU_KEY_MASK, "HandleMenu")

	return menuIdx
}

stock mc_show_menu(id, const section[], time = -1, bool:ignoreHistory = false, bool:resetHistory = false, targetId = 0, bool:forceOpening = false) {
	if (!is_user_connected(id)) return 0
	g_MenuTargetId[id] = targetId

	new menuIdx
	if (!TrieGetCell(g_MenuTrie, section, menuIdx)) return 0

	// Central open gate: a registered show filter may veto opening this menu (and notify the player
	// why) before anything renders — e.g. the license gate blocks every menu while unlicensed.
	if (!InvokeShowFilters(id, section)) return 0

	new bool:isRefresh
	new bool:hasDataSource
	new bool:hasTemplate
	new bool:showItem
	new bool:restrictionMet
	new bool:isDisabled
	new bool:hasTimePlaceholder
	new bool:isReturnToCurrent
	new bool:hasPagination

	new iKeys, iLen, timerDuration
	new activeGlobal, totalItems, totalPages, currentPage, itemsPerPage
	new fixedItemsCount, startIndex, dynRenderCount
	new variantCount, fVarCount
	new selectedVariant
	new targetIdVal
	new count, pCount, colon, j, size, f, e, i, slot, normalItemAdded, hasFixed, vCount
	new fixedIdx, fixedPerPage
	new maxLen, len
	new foundInHistory, prevPage
	new pNum

	new Array:customItems
	new players[32]
	new failedRestrict[RESTRICT_LENGTH]
	new langKey[64]
	new itemRestrict[32]
	new itemRestrictMsg[128]
	new var[VariantStruct]

	static formatted[512]

	static menu_data[MenuDataStruct]
	ArrayGetArray(g_Menus, menuIdx, menu_data)
	prevPage = g_MenuPage[id]

	if (!forceOpening && g_ActiveMenu[id] != -1 && g_ActiveMenu[id] != menuIdx) {
		if (g_PlayerMenuTimer[id] > 0 || g_IsMenuLocked[id]) {
			return 0
		}
	}

	if (g_ActiveMenu[id] != -1 && g_ActiveMenu[id] != menuIdx) {
		remove_task(id + TASK_PLAYER_TIMEOUT)
		g_PlayerMenuTimer[id] = 0
		InvokeMenuCloseCallbacks(id, false)
	}

	if (resetHistory) {
		g_MenuHistoryDepth[id] = 0
		g_ActiveMenu[id] = -1
	}

	if (menu_data[MENU_ACTIVE_ON][0]) {
		if (!CheckCondition(id, id, menu_data[MENU_ACTIVE_ON], false)) {
#if DEBUG
			log_amx("[MenuCore] Blocked: Condition '%s' failed for player %d on menu '%s'", menu_data[MENU_ACTIVE_ON], id, section);
#endif
			mc_internal_close_menu(id)
			g_ShowMenuDepth[id]--
			return 0
		}
	}

	if (g_ShowMenuDepth[id] >= MAX_MENU_RECURSION_DEPTH) {
		return 0
	}
	g_ShowMenuDepth[id]++

	isReturnToCurrent = (g_ActiveMenu[id] == menuIdx)

	// History rewind: if the menu is already in history, roll back to it
	foundInHistory = -1
	for (i = 0; i < g_MenuHistoryDepth[id]; i++) {
		if (g_MenuHistory[id][i] == menuIdx) {
			foundInHistory = i; break
		}
	}

	if (foundInHistory != -1) {
		g_MenuPage[id] = g_MenuHistoryPage[id][foundInHistory]
		g_MenuHistoryDepth[id] = foundInHistory
		// On history return, do not re-add this same menu on the next step
	}

	g_ShouldAddToHistory[id] = !isReturnToCurrent && g_ActiveMenu[id] != -1 && !ignoreHistory && foundInHistory == -1

	if (g_ShouldAddToHistory[id]) {
		new prev_menu_data[MenuDataStruct]
		ArrayGetArray(g_Menus, g_ActiveMenu[id], prev_menu_data)
		if (containi(prev_menu_data[MENU_SECTION], "CONFIRM") != -1) {
			g_ShouldAddToHistory[id] = false
		}
	}

#if DEBUG
	log_amx("[MenuCore] Player %d: Menu '%s', Depth: %d, shouldAdd: %d, found: %d, prevActive: %d",
		id, section, g_MenuHistoryDepth[id], g_ShouldAddToHistory[id], foundInHistory, g_ActiveMenu[id]);
#endif

	if (time != -1) remove_task(id + TASK_PLAYER_TIMEOUT)
	InvokeMenuOpenCallbacks(id, section)

	if (!isReturnToCurrent) g_IsMenuLocked[id] = menu_data[MENU_LOCKED]

	isRefresh = (time == -1)
	iKeys = 0
	iLen = 0
	timerDuration = (time == -1) ? 0 : time

	if (isRefresh) {
		activeGlobal = ArrayGetCell(g_MenuActiveTimers, menuIdx)
		timerDuration = (activeGlobal > 0) ? activeGlobal : g_PlayerMenuTimer[id]
	}

	if (timerDuration <= 0) {
		timerDuration = menu_data[MENU_TIMER_DURATION]
	}

	// Pre-compute pagination so it can be shown in the title
	totalItems = 0
	totalPages = 1
	currentPage = 0
	itemsPerPage = MAX_MENU_ITEMS
	customItems = Invalid_Array
	hasDataSource = false
	pNum = 0

	if (!isReturnToCurrent && !ignoreHistory && foundInHistory == -1) g_MenuPage[id] = 0
	currentPage = g_MenuPage[id]

	if (menu_data[MENU_TYPE] == MENU_TYPE_LIST) {
		new iFilterCount = (menu_data[MENU_FILTERS_COND] != Invalid_Array) ? ArraySize(menu_data[MENU_FILTERS_COND]) : 0
		for (i = 0, size = ArraySize(g_DataSources); i < size; i++) {
			new source_data[DataSourceStruct]; ArrayGetArray(g_DataSources, i, source_data)
			if (equali(source_data[DS_MENU], section)) {
				new func = get_func_id(source_data[DS_CALLBACK], source_data[DS_PLUGIN])
				if (func != -1) {
					customItems = ArrayCreate(289)
					if (callfunc_begin_i(func, source_data[DS_PLUGIN]) == 1) {
						callfunc_push_int(id); callfunc_push_int(_:customItems)
						if (callfunc_end() == 1) hasDataSource = true
						else { ArrayDestroy(customItems); customItems = Invalid_Array; }
					} else { ArrayDestroy(customItems); customItems = Invalid_Array; }
				}
				break
			}
		}
		hasTemplate = (ArraySize(menu_data[MENU_ITEMS_ARRAY]) > 0)
		if (!hasDataSource && hasTemplate) {
			get_players(players, pNum)
			if (iFilterCount > 0) {
				new filteredNum = 0
				new filteredPlayers[32]
				for (new jIdx = 0; jIdx < pNum; jIdx++) {
					new target = players[jIdx]
					new bool:bPassed = true
					for (new f = 0; f < iFilterCount; f++) {
						new condStr[CONDITION_LENGTH]
						ArrayGetString(menu_data[MENU_FILTERS_COND], f, condStr, charsmax(condStr))
						if (!CheckCondition(target, id, condStr, false)) {
							bPassed = false
							break
						}
					}
					if (bPassed) {
						filteredPlayers[filteredNum++] = target
					}
				}
				pNum = filteredNum
				for (new jIdx = 0; jIdx < pNum; jIdx++) {
					players[jIdx] = filteredPlayers[jIdx]
				}
			}
		}

		if (hasDataSource && customItems != Invalid_Array && iFilterCount > 0) {
			for (new jIdx = ArraySize(customItems) - 1; jIdx >= 0; jIdx--) {
				new item[289]; ArrayGetArray(customItems, jIdx, item)
				if (item[0] != -2) {
					new bool:bPassed = true
					for (new f = 0; f < iFilterCount; f++) {
						new condStr[CONDITION_LENGTH]
						ArrayGetString(menu_data[MENU_FILTERS_COND], f, condStr, charsmax(condStr))
						if (!CheckCondition(item[0], id, condStr, false)) {
							bPassed = false
							break
						}
					}
					if (!bPassed) {
						ArrayDeleteItem(customItems, jIdx)
					}
				}
			}
		}

		fixedItemsCount = (menu_data[MENU_FIXED_ITEMS] != Invalid_Array) ? ArraySize(menu_data[MENU_FIXED_ITEMS]) : 0
		itemsPerPage = MAX_MENU_ITEMS - fixedItemsCount
		if (itemsPerPage <= 0) itemsPerPage = 1

		totalItems = 0
		if (hasDataSource && customItems != Invalid_Array) {
			for (i = 0, size = ArraySize(customItems); i < size; i++) {
				new item[289]; ArrayGetArray(customItems, i, item)
				if (item[0] != -2) totalItems++
			}
		} else if (!hasDataSource) {
			totalItems = pNum
		}

		totalPages = (totalItems + itemsPerPage - 1) / itemsPerPage
		if (totalPages <= 0) totalPages = 1
	} else {
		fixedItemsCount = (menu_data[MENU_FIXED_ITEMS] != Invalid_Array) ? ArraySize(menu_data[MENU_FIXED_ITEMS]) : 0
		itemsPerPage = MAX_MENU_ITEMS - fixedItemsCount
		if (itemsPerPage <= 0) itemsPerPage = 1

		totalItems = ArraySize(menu_data[MENU_ITEMS_ARRAY])
		totalPages = (totalItems + itemsPerPage - 1) / itemsPerPage
	}

	if (totalPages < 1) totalPages = 1
	if (totalPages > 1) {
		if (currentPage >= totalPages) currentPage = g_MenuPage[id] = max(0, totalPages - 1)
	}
	g_MenuTotalItems[id] = totalItems

	if (timerDuration > 0) {
		if (menu_data[MENU_GLOBAL_TIMER]) {
			if (ArrayGetCell(g_MenuActiveTimers, menuIdx) == 0 && time != -1) {
				ArraySetCell(g_MenuActiveTimers, menuIdx, timerDuration)
				if (!task_exists(menuIdx)) set_task(1.0, "GlobalMenuTimerTask", menuIdx, _, _, "b")
			}
		} else {
			if (time >= 0) {
				g_PlayerMenuTimer[id] = timerDuration
				if (!task_exists(id + TASK_PLAYER_TIMEOUT)) set_task(1.0, "PlayerMenuTimerTask", id + TASK_PLAYER_TIMEOUT, _, _, "b")
			}
		}
	}

	static szTitle[256]; copy(szTitle, 255, menu_data[MENU_TITLE])
	if (IsMLKey(szTitle)) { SetGlobalTransTarget(id); LookupLangKey(szTitle, 255, szTitle, id); }

	hasTimePlaceholder = (strfind(szTitle, "%time%", true) != -1 || strfind(szTitle, "%TIME%", true) != -1)
	ReplacePlaceholders(id, g_MenuTargetId[id], szTitle, 255, szTitle, .menuIdx = menuIdx)

	static pageInfo[64]; pageInfo[0] = 0
	if (totalPages > 1) {
		static pageFormat[64]
		ResolveUiKey(id, g_LangKeyPage, DEF_KEY_PAGE, pageFormat, 63)
		replace(pageFormat, 63, "%d", fmt("%d", currentPage + 1)); replace(pageFormat, 63, "%d", fmt("%d", totalPages))
		formatex(pageInfo, 63, " %s", pageFormat)
	}

	if (timerDuration > 0) {
		if (hasTimePlaceholder) {
			iLen = formatex(g_szMenu[id], MENU_BUF_SIZE - 1, "%s%s^n^n", szTitle, pageInfo)
		} else {
			static timerText[128]
			ResolveUiKey(id, g_LangKeyTimer, DEF_KEY_TIMER, timerText, 127)
			replace(timerText, 127, "%d", fmt("%d", timerDuration))
			iLen = formatex(g_szMenu[id], MENU_BUF_SIZE - 1, "%s%s^n%s^n^n", szTitle, pageInfo, timerText)
		}
	} else {
		iLen = formatex(g_szMenu[id], MENU_BUF_SIZE - 1, "%s%s^n^n", szTitle, pageInfo)
	}

	if (menu_data[MENU_TYPE] == MENU_TYPE_LIST) {
		if (hasDataSource && customItems == Invalid_Array) {
			#if DEBUG
				log_amx("[MenuSystem] Error: Data source handle is invalid")
			#endif
			g_ShowMenuDepth[id]--
			return 0
		}

		startIndex = currentPage * itemsPerPage
		dynRenderCount = 0

		hasTemplate = (ArraySize(menu_data[MENU_ITEMS_ARRAY]) > 0)
		static item_templ[MenuItemStruct];
		variantCount = 0
		if (hasTemplate) {
			ArrayGetArray(menu_data[MENU_ITEMS_ARRAY], 0, item_templ)
			variantCount = ArraySize(item_templ[ITEM_VARIANTS])
		}

		fixedItemsCount = (menu_data[MENU_FIXED_ITEMS] != Invalid_Array) ? ArraySize(menu_data[MENU_FIXED_ITEMS]) : 0
		new iFilterCount = (menu_data[MENU_FILTERS_COND] != Invalid_Array) ? ArraySize(menu_data[MENU_FILTERS_COND]) : 0

		for (slot = 0; slot < MAX_MENU_ITEMS; slot++) {
			fixedIdx = -1
			if (fixedItemsCount > 0) {
				for (f = 0; f < fixedItemsCount; f++) {
					new fItem[FixedItemStruct]; ArrayGetArray(menu_data[MENU_FIXED_ITEMS], f, fItem)
					if (fItem[FIXED_SLOT] == slot) { fixedIdx = f; break; }
				}
			}

			if (fixedIdx != -1) {
				new fItem[FixedItemStruct]; ArrayGetArray(menu_data[MENU_FIXED_ITEMS], fixedIdx, fItem)

				// Empty lines BEFORE
				for (e = 0; e < fItem[FIXED_DATA][ITEM_EMPTY_BEFORE]; e++) {
					maxLen = MENU_BUF_SIZE - 1 - iLen
					iLen += formatex(g_szMenu[id][iLen], maxLen, "^n")
				}

				fVarCount = ArraySize(fItem[FIXED_DATA][ITEM_VARIANTS])
				selectedVariant = -1
				for (j = 0; j < fVarCount; j++) {
					ArrayGetArray(fItem[FIXED_DATA][ITEM_VARIANTS], j, var)
					if (!var[VAR_CONDITION][0] || CheckCondition(id, id, var[VAR_CONDITION], false)) { selectedVariant = j; break; }
				}

				showItem = (selectedVariant != -1)
				if (!showItem) selectedVariant = 0
				ArrayGetArray(fItem[FIXED_DATA][ITEM_VARIANTS], selectedVariant, var)

				static itemName[NAME_LENGTH]
				if (IsMLKey(var[VAR_NAME])) {
					SetGlobalTransTarget(id); LookupLangKey(itemName, charsmax(itemName), var[VAR_NAME], id)
				} else copy(itemName, charsmax(itemName), var[VAR_NAME])

				formatex(g_DisplayStrBuffer, ITEM_BUF_SIZE - 1, "%s%s%s", itemName, fItem[FIXED_DATA][ITEM_PLACEHOLDER][0] ? " " : "", fItem[FIXED_DATA][ITEM_PLACEHOLDER])
				ReplacePlaceholders(id, g_MenuTargetId[id], g_DisplayStrBuffer, ITEM_BUF_SIZE - 1, g_DisplayStrBuffer, .menuIdx = menuIdx)

				restrictionMet = true
				failedRestrict[0] = 0
				if (fItem[FIXED_DATA][ITEM_RESTRICTION][0]) {
					new tokens[8][RESTRICT_LENGTH]
					count = ParseTokens(fItem[FIXED_DATA][ITEM_RESTRICTION], tokens, 8, RESTRICT_LENGTH)
					for (j = 0; j < count; j++) {
						if (!CheckCondition(id, id, tokens[j], true)) { restrictionMet = false; copy(failedRestrict, 31, tokens[j]); break; }
					}
				}

				if (showItem && restrictionMet) {
					if (!CheckActionConditions(id, menu_data[MENU_SECTION], var[VAR_ACTION])) {
						restrictionMet = false;
						copy(failedRestrict, 31, "ACTION_CONDITION");
					}
				}

				if (showItem && restrictionMet) {
					FormatMenuItem(id, slot + 1, g_DisplayStrBuffer, formatted, ITEM_BUF_SIZE - 1, false)
					maxLen = MENU_BUF_SIZE - 1 - iLen
					iLen += formatex(g_szMenu[id][iLen], maxLen, "%s^n", formatted)
					iKeys |= (1 << slot); g_MenuItemTargetIds[id][slot] = g_MenuTargetId[id]; g_MenuItemTypes[id][slot] = 1; copy(g_MenuItemActions[id][slot], ACTION_LENGTH - 1, var[VAR_ACTION])
				} else {
					static reason[RESTRICT_MSG_LENGTH]; reason[0] = 0
					if (!restrictionMet && fItem[FIXED_DATA][ITEM_RESTRICT_MSG][0]) {
						static pairs[8][RESTRICT_MSG_LENGTH]
						pCount = ParseRestrictMsg(fItem[FIXED_DATA][ITEM_RESTRICT_MSG], pairs, 8, RESTRICT_MSG_LENGTH)
						for (j = 0; j < pCount; j++) {
							static pref[RESTRICT_LENGTH], msg[RESTRICT_MSG_LENGTH]
							colon = contain(pairs[j], ":")
							if (colon != -1) {
								len = min(colon + 1, 31)
								copy(pref, len, pairs[j]); copy(msg, 127, pairs[j][colon + 1])
								if (pref[strlen(pref)-1] == ':') pref[strlen(pref)-1] = 0
								if (equal(pref, failedRestrict)) { formatex(reason, 127, " %s", msg); break; }
							} else { copy(reason, 127, pairs[j]); break; }
						}
					}
					if (reason[0]) {
						formatex(g_DisplayStrBuffer, ITEM_BUF_SIZE - 1, "%s\y%s", g_DisplayStrBuffer, reason)
						FormatMenuItem(id, slot + 1, g_DisplayStrBuffer, formatted, ITEM_BUF_SIZE - 1, true)
						maxLen = MENU_BUF_SIZE - 1 - iLen
						iLen += formatex(g_szMenu[id][iLen], maxLen, "%s^n", formatted)
					} else {
						FormatMenuItem(id, slot + 1, g_DisplayStrBuffer, formatted, ITEM_BUF_SIZE - 1, true)
						maxLen = MENU_BUF_SIZE - 1 - iLen
						iLen += formatex(g_szMenu[id][iLen], maxLen, "%s^n", formatted)
					}
					g_MenuItemTargetIds[id][slot] = 0; g_MenuItemTypes[id][slot] = 1; g_MenuItemActions[id][slot][0] = 0
				}

				// Empty lines AFTER
				for (e = 0; e < fItem[FIXED_DATA][ITEM_EMPTY_AFTER]; e++) {
					maxLen = MENU_BUF_SIZE - 1 - iLen
					iLen += formatex(g_szMenu[id][iLen], maxLen, "^n")
				}
			} else {
				if (hasDataSource && customItems != Invalid_Array) {
					while (startIndex + dynRenderCount < ArraySize(customItems)) {
						new item[289]; ArrayGetArray(customItems, startIndex + dynRenderCount, item)
						if (item[0] == -2) {
							maxLen = MENU_BUF_SIZE - 1 - iLen
							iLen += formatex(g_szMenu[id][iLen], maxLen, "%s^n", item[65])
							dynRenderCount++
							continue
						}
						break
					}
				}

				i = startIndex + dynRenderCount
				// For data sources, i indexes into customItems (which includes text rows
				// added via mc_add_list_text); totalItems counts only numbered items, so
				// guarding against it would drop the last item(s) when text rows are mixed in.
				if (!hasTemplate || i >= (hasDataSource ? ArraySize(customItems) : totalItems)) {
					// If we have a data source, we want a compact menu, so skip empty lines
					if (!hasDataSource) {
						maxLen = MENU_BUF_SIZE - 1 - iLen
						iLen += formatex(g_szMenu[id][iLen], maxLen, "^n")
					}
					g_MenuItemTargetIds[id][slot] = 0; g_MenuItemTypes[id][slot] = 0; g_MenuItemActions[id][slot][0] = 0
					continue
				}
				dynRenderCount++

				isDisabled = false
				if (hasDataSource) {
					new item[289]; ArrayGetArray(customItems, i, item)
					targetIdVal = item[0];
					copy(langKey, 63, item[65]);
					copy(itemRestrict, 31, item[129]);
					copy(itemRestrictMsg, 127, item[161])

					copy(g_MenuItemActions[id][slot], ACTION_LENGTH - 1, item[1])

					for (new f = 0; f < iFilterCount; f++) {
						new condStr[CONDITION_LENGTH]
						ArrayGetString(menu_data[MENU_FILTERS_COND], f, condStr, charsmax(condStr))
						if (!CheckCondition(targetIdVal, id, condStr, false)) {
							isDisabled = true
							break
						}
					}
				} else {
					targetIdVal = players[i]
					g_MenuItemActions[id][slot][0] = 0
					for (new f = 0; f < iFilterCount; f++) {
						new condStr[CONDITION_LENGTH]
						ArrayGetString(menu_data[MENU_FILTERS_COND], f, condStr, charsmax(condStr))
						if (!CheckCondition(targetIdVal, id, condStr, false)) {
							isDisabled = true
							break
						}
					}
					get_user_name(targetIdVal, langKey, 63)
					itemRestrict[0] = 0
					itemRestrictMsg[0] = 0
				}

				if (targetIdVal == -2) {
					maxLen = MENU_BUF_SIZE - 1 - iLen
					iLen += formatex(g_szMenu[id][iLen], maxLen, "%s^n", langKey)
					g_MenuItemTargetIds[id][slot] = 0; g_MenuItemTypes[id][slot] = 0; g_MenuItemActions[id][slot][0] = 0
					continue
				}

				selectedVariant = -1
				for (j = 0; j < variantCount; j++) {
					ArrayGetArray(item_templ[ITEM_VARIANTS], j, var)
					if (!var[VAR_CONDITION][0] || CheckCondition(targetIdVal, id, var[VAR_CONDITION], false)) { selectedVariant = j; break; }
				}

				if (selectedVariant == -1) {
					isDisabled = true
					selectedVariant = 0
				}
				ArrayGetArray(item_templ[ITEM_VARIANTS], selectedVariant, var)
				ReplacePlaceholders(id, targetIdVal, g_DisplayStrBuffer, ITEM_BUF_SIZE - 1, var[VAR_NAME], langKey, menuIdx)

				restrictionMet = true
				failedRestrict[0] = 0
				if (hasDataSource && itemRestrict[0]) {
					if (!CheckCondition(id, targetIdVal, itemRestrict, true)) { restrictionMet = false; copy(failedRestrict, 31, itemRestrict); }
				}
				if (restrictionMet && item_templ[ITEM_RESTRICTION][0]) {
					new tokens[8][RESTRICT_LENGTH]
					count = ParseTokens(item_templ[ITEM_RESTRICTION], tokens, 8, RESTRICT_LENGTH)
					for (j = 0; j < count; j++) {
						if (!CheckCondition(id, targetIdVal, tokens[j], true)) { restrictionMet = false; copy(failedRestrict, 31, tokens[j]); break; }
					}
				}

				if (restrictionMet && !isDisabled) {
					if (!CheckActionConditions(id, menu_data[MENU_SECTION], var[VAR_ACTION])) {
						restrictionMet = false;
						copy(failedRestrict, 31, "ACTION_CONDITION");
					}
				}

				if (restrictionMet && !isDisabled && !g_IsMenuLocked[id]) {
					FormatMenuItem(id, slot + 1, g_DisplayStrBuffer, formatted, ITEM_BUF_SIZE - 1, false)
					maxLen = MENU_BUF_SIZE - 1 - iLen
					iLen += formatex(g_szMenu[id][iLen], maxLen, "%s^n", formatted)
					iKeys |= (1 << slot); g_MenuItemTargetIds[id][slot] = targetIdVal; g_MenuItemTypes[id][slot] = 0; g_IsItemDisabled[id][slot] = false
				} else {
					static reason[RESTRICT_MSG_LENGTH]; reason[0] = 0
					if (hasDataSource && itemRestrictMsg[0]) formatex(reason, 127, " %s", itemRestrictMsg)
					else if (item_templ[ITEM_RESTRICT_MSG][0]) {
						static pairs[8][RESTRICT_MSG_LENGTH]
						pCount = ParseRestrictMsg(item_templ[ITEM_RESTRICT_MSG], pairs, 8, RESTRICT_MSG_LENGTH)
						for (j = 0; j < pCount; j++) {
							static pref[RESTRICT_LENGTH], msg[RESTRICT_MSG_LENGTH]
							colon = contain(pairs[j], ":")
							if (colon != -1) {
								len = min(colon + 1, 31)
								copy(pref, len, pairs[j]); copy(msg, 127, pairs[j][colon + 1])
								if (pref[strlen(pref)-1] == ':') pref[strlen(pref)-1] = 0
								if (equal(pref, failedRestrict)) { formatex(reason, 127, " %s", msg); break; }
							} else { copy(reason, 127, pairs[j]); break; }
						}
					}
					if (reason[0]) {
						formatex(g_DisplayStrBuffer, ITEM_BUF_SIZE - 1, "%s\y%s", g_DisplayStrBuffer, reason)
						FormatMenuItem(id, slot + 1, g_DisplayStrBuffer, formatted, ITEM_BUF_SIZE - 1, true)
						maxLen = MENU_BUF_SIZE - 1 - iLen
						iLen += formatex(g_szMenu[id][iLen], maxLen, "%s^n", formatted)
					} else {
						FormatMenuItem(id, slot + 1, g_DisplayStrBuffer, formatted, ITEM_BUF_SIZE - 1, true)
						maxLen = MENU_BUF_SIZE - 1 - iLen
						iLen += formatex(g_szMenu[id][iLen], maxLen, "%s^n", formatted)
					}
					g_MenuItemTargetIds[id][slot] = targetIdVal; g_MenuItemTypes[id][slot] = 0; g_MenuItemActions[id][slot][0] = 0; g_IsItemDisabled[id][slot] = true
				}
			}
		}
		if (hasDataSource && customItems != Invalid_Array) ArrayDestroy(customItems)

		new bool:hasFilterMsg = false
		if (menu_data[MENU_FILTERS_MSG] != Invalid_Array && ArraySize(menu_data[MENU_FILTERS_MSG]) > 0) {
			hasFilterMsg = true
		}
		if (totalItems == 0 && hasFilterMsg) {
			ShowEmptyMessage(id, menuIdx)
			g_ShowMenuDepth[id]--
			return 0
		}

		if (totalPages > 1) {
			new nav[128]
			maxLen = MENU_BUF_SIZE - 1 - iLen
			iLen += formatex(g_szMenu[id][iLen], maxLen, "^n")
			if (currentPage < totalPages - 1) {
				new uiNext[64]; ResolveUiKey(id, g_LangKeyNext, DEF_KEY_NEXT, uiNext, charsmax(uiNext)); FormatMenuItem(id, 8, uiNext, nav, 127)
				maxLen = MENU_BUF_SIZE - 1 - iLen
				iLen += formatex(g_szMenu[id][iLen], maxLen, "%s^n", nav)
				iKeys |= MENU_KEY_8
			} else {
				maxLen = MENU_BUF_SIZE - 1 - iLen
				iLen += formatex(g_szMenu[id][iLen], maxLen, "^n")
			}

			if (currentPage > 0 || (g_MenuHistoryDepth[id] > 0 || g_ShouldAddToHistory[id]) && !menu_data[MENU_HIDE_BACK]) {
				new uiBack[64]; ResolveUiKey(id, g_LangKeyBack, DEF_KEY_BACK, uiBack, charsmax(uiBack)); FormatMenuItem(id, 9, uiBack, nav, 127)
				maxLen = MENU_BUF_SIZE - 1 - iLen
				iLen += formatex(g_szMenu[id][iLen], maxLen, "%s^n", nav)
				iKeys |= MENU_KEY_9
			} else {
				maxLen = MENU_BUF_SIZE - 1 - iLen
				iLen += formatex(g_szMenu[id][iLen], maxLen, "^n")
			}
		}
	} else {
		if (totalPages == 0) totalPages = 1

		currentPage = g_MenuPage[id]
		startIndex = currentPage * itemsPerPage
		normalItemAdded = 0

		for (slot = 0; slot < MAX_MENU_ITEMS; slot++) {
			hasFixed = false
			new fixed_item[FixedItemStruct]

			if (menu_data[MENU_FIXED_ITEMS] != Invalid_Array) {
				for (j = 0, size = ArraySize(menu_data[MENU_FIXED_ITEMS]); j < size; j++) {
					ArrayGetArray(menu_data[MENU_FIXED_ITEMS], j, fixed_item)
					if (fixed_item[FIXED_SLOT] == slot) {
						hasFixed = true; break
					}
				}
			}

			new item[MenuItemStruct]
			if (hasFixed) {
				item[ITEM_VARIANTS] = fixed_item[FIXED_DATA][ITEM_VARIANTS]
				copy(item[ITEM_PLACEHOLDER], PLACEHOLDER_LENGTH - 1, fixed_item[FIXED_DATA][ITEM_PLACEHOLDER])
				copy(item[ITEM_RESTRICTION], RESTRICT_LENGTH - 1, fixed_item[FIXED_DATA][ITEM_RESTRICTION])
				copy(item[ITEM_RESTRICT_MSG], RESTRICT_MSG_LENGTH - 1, fixed_item[FIXED_DATA][ITEM_RESTRICT_MSG])
				item[ITEM_EMPTY_BEFORE] = fixed_item[FIXED_DATA][ITEM_EMPTY_BEFORE]
				item[ITEM_EMPTY_AFTER] = fixed_item[FIXED_DATA][ITEM_EMPTY_AFTER]
			} else {
				new realIndex = startIndex + normalItemAdded
				if (realIndex >= totalItems) {
					maxLen = MENU_BUF_SIZE - 1 - iLen
					iLen += formatex(g_szMenu[id][iLen], maxLen, "^n")
					continue
				}
				ArrayGetArray(menu_data[MENU_ITEMS_ARRAY], realIndex, item)
				normalItemAdded++
			}

			// Empty lines BEFORE
			for (j = 0; j < item[ITEM_EMPTY_BEFORE]; j++) {
				if (iLen + 2 < MENU_BUF_SIZE) {
					maxLen = MENU_BUF_SIZE - 1 - iLen
					iLen += formatex(g_szMenu[id][iLen], maxLen, "^n")
				}
			}

			selectedVariant = -1
			vCount = 0
			if (item[ITEM_VARIANTS] != Invalid_Array) {
				vCount = ArraySize(item[ITEM_VARIANTS])
			}

			for (j = 0; j < vCount; j++) {
				ArrayGetArray(item[ITEM_VARIANTS], j, var)
				if (!var[VAR_CONDITION][0] || CheckCondition(id, id, var[VAR_CONDITION], false)) {
					selectedVariant = j; break
				}
			}

			showItem = (selectedVariant != -1)
			if (!showItem) selectedVariant = 0
			restrictionMet = true
			failedRestrict[0] = 0
			if (item[ITEM_RESTRICTION][0]) {
				new tokens[8][RESTRICT_LENGTH]
				count = ParseTokens(item[ITEM_RESTRICTION], tokens, 8, RESTRICT_LENGTH)
				for (j = 0; j < count; j++) {
					if (!CheckCondition(id, id, tokens[j], true)) { restrictionMet = false; copy(failedRestrict, 31, tokens[j]); break; }
				}
				showItem = showItem && restrictionMet
			}

			static itemName[NAME_LENGTH]; itemName[0] = 0
			if (item[ITEM_VARIANTS] != Invalid_Array && ArraySize(item[ITEM_VARIANTS]) > selectedVariant) {
				ArrayGetArray(item[ITEM_VARIANTS], selectedVariant, var)
				if (IsMLKey(var[VAR_NAME])) {
					SetGlobalTransTarget(id); LookupLangKey(itemName, charsmax(itemName), var[VAR_NAME], id)
				} else copy(itemName, charsmax(itemName), var[VAR_NAME])
			}

			formatex(g_DisplayStrBuffer, ITEM_BUF_SIZE - 1, "%s%s%s", itemName, item[ITEM_PLACEHOLDER][0] ? " " : "", item[ITEM_PLACEHOLDER])
			ReplacePlaceholders(id, 0, g_DisplayStrBuffer, ITEM_BUF_SIZE - 1, g_DisplayStrBuffer)

			if (showItem) {
				if (!CheckActionConditions(id, menu_data[MENU_SECTION], var[VAR_ACTION])) {
					showItem = false
					restrictionMet = false
					copy(failedRestrict, 31, "ACTION_CONDITION")
				}
			}

			if (showItem) {
				FormatMenuItem(id, slot + 1, g_DisplayStrBuffer, formatted, ITEM_BUF_SIZE - 1, false)
				maxLen = MENU_BUF_SIZE - 1 - iLen
				iLen += formatex(g_szMenu[id][iLen], maxLen, "%s^n", formatted); iKeys |= (1 << slot); g_IsItemDisabled[id][slot] = false
			} else {
				static reason[RESTRICT_MSG_LENGTH]; reason[0] = 0
				if (!restrictionMet && item[ITEM_RESTRICT_MSG][0]) {
					static pairs[8][RESTRICT_MSG_LENGTH]
					pCount = ParseRestrictMsg(item[ITEM_RESTRICT_MSG], pairs, 8, RESTRICT_MSG_LENGTH)
					for (j = 0; j < pCount; j++) {
						static pref[RESTRICT_LENGTH], msg[RESTRICT_MSG_LENGTH]
						colon = contain(pairs[j], ":")
						if (colon != -1) {
							len = min(colon + 1, 31)
							copy(pref, len, pairs[j]); copy(msg, 127, pairs[j][colon+1])
							if (pref[strlen(pref)-1] == ':') pref[strlen(pref)-1] = 0
							if (equal(pref, failedRestrict)) { formatex(reason, 127, " %s", msg); break; }
						}
					}
				}
				FormatMenuItem(id, slot + 1, g_DisplayStrBuffer, formatted, 511, true)
				maxLen = MENU_BUF_SIZE - 1 - iLen
				iLen += formatex(g_szMenu[id][iLen], maxLen, "%s%s^n", formatted, reason); g_IsItemDisabled[id][slot] = true
			}
			// Empty lines AFTER
			for (j = 0; j < item[ITEM_EMPTY_AFTER]; j++) {
				if (iLen + 2 < MENU_BUF_SIZE) {
					maxLen = MENU_BUF_SIZE - 1 - iLen
					iLen += formatex(g_szMenu[id][iLen], maxLen, "^n")
				}
			}
		}

		if (totalPages > 1) {
			new nav[128]
			maxLen = MENU_BUF_SIZE - 1 - iLen
			iLen += formatex(g_szMenu[id][iLen], maxLen, "^n")
			if (currentPage < totalPages - 1) {
				new uiNext[64]; ResolveUiKey(id, g_LangKeyNext, DEF_KEY_NEXT, uiNext, charsmax(uiNext)); FormatMenuItem(id, 8, uiNext, nav, 127)
				maxLen = MENU_BUF_SIZE - 1 - iLen
				iLen += formatex(g_szMenu[id][iLen], maxLen, "%s^n", nav)
				iKeys |= MENU_KEY_8
			} else {
				maxLen = MENU_BUF_SIZE - 1 - iLen
				iLen += formatex(g_szMenu[id][iLen], maxLen, "^n")
			}

			if (currentPage > 0 || (g_MenuHistoryDepth[id] > 0 || g_ShouldAddToHistory[id]) && !menu_data[MENU_HIDE_BACK]) {
				new uiBack[64]; ResolveUiKey(id, g_LangKeyBack, DEF_KEY_BACK, uiBack, charsmax(uiBack)); FormatMenuItem(id, 9, uiBack, nav, 127)
				maxLen = MENU_BUF_SIZE - 1 - iLen
				iLen += formatex(g_szMenu[id][iLen], maxLen, "%s^n", nav)
				iKeys |= MENU_KEY_9
			} else {
				maxLen = MENU_BUF_SIZE - 1 - iLen
				iLen += formatex(g_szMenu[id][iLen], maxLen, "^n")
			}
		}
	}

	hasPagination = false
	fixedPerPage = 0
	if (menu_data[MENU_FIXED_ITEMS] != Invalid_Array) fixedPerPage = ArraySize(menu_data[MENU_FIXED_ITEMS])
	itemsPerPage = MAX_MENU_ITEMS - fixedPerPage
	if (itemsPerPage <= 0) itemsPerPage = 1

	hasPagination = (g_MenuTotalItems[id] > itemsPerPage)

	if (!hasPagination && (g_MenuHistoryDepth[id] > 0 || g_ShouldAddToHistory[id]) && !menu_data[MENU_HIDE_BACK] && ArrayGetCell(g_MenuActiveTimers, menuIdx) == 0) {
		new back[128], uiBack[64]
		ResolveUiKey(id, g_LangKeyBack, DEF_KEY_BACK, uiBack, charsmax(uiBack))
		FormatMenuItem(id, 9, uiBack, back, 127)
		maxLen = MENU_BUF_SIZE - 1 - iLen
		iLen += formatex(g_szMenu[id][iLen], maxLen, "^n%s^n", back); iKeys |= MENU_KEY_9
	}

	if (ArrayGetCell(g_MenuActiveTimers, menuIdx) == 0 && !menu_data[MENU_HIDE_EXIT]) {
		new exitBtn[128], uiExit[64]
		ResolveUiKey(id, g_LangKeyExit, DEF_KEY_EXIT, uiExit, charsmax(uiExit))
		FormatMenuItem(id, 0, uiExit, exitBtn, 127)
		maxLen = MENU_BUF_SIZE - 1 - iLen
		iLen += formatex(g_szMenu[id][iLen], maxLen, "^n%s", exitBtn); iKeys |= (1 << 9)
	}

	if (g_IsMenuLocked[id] && iKeys == 0) iKeys |= MENU_KEY_0

	if (g_ShouldAddToHistory[id] && g_MenuHistoryDepth[id] < MAX_MENU_HISTORY) {
		g_MenuHistory[id][g_MenuHistoryDepth[id]] = g_ActiveMenu[id]
		g_MenuHistoryPage[id][g_MenuHistoryDepth[id]++] = prevPage
	}

	g_ActiveMenu[id] = menuIdx
	show_menu(id, iKeys, g_szMenu[id], -1, menu_data[MENU_SECTION])

	g_ShowMenuDepth[id]--
	return 1
}

/**
 * Internal function to properly close a player's menu and reset all related state
 * @param id		Player index
 */
stock mc_internal_close_menu(id, bool:isTimeout = false) {
	new menuIdx = g_ActiveMenu[id]
	if (menuIdx == -1) return

	static szSection[NAME_LENGTH]
	new menu_data[MenuDataStruct]; ArrayGetArray(g_Menus, menuIdx, menu_data)
	copy(szSection, charsmax(szSection), menu_data[MENU_SECTION])

	remove_task(id + TASK_PLAYER_TIMEOUT)
	g_PlayerMenuTimer[id] = 0
	g_IsMenuLocked[id] = false
	g_ActiveMenu[id] = -1
	g_MenuPage[id] = 0
	g_MenuTargetId[id] = 0
	g_MenuHistoryDepth[id] = 0

	show_menu(id, 0, "^n", 0)
	InvokeMenuCloseCallbacks(id, isTimeout, szSection)
}

/**
 * Show empty message and navigate back in menu history
 * Consolidates duplicate logic from HandleMenu
 * @param id		Player index
 * @param menuId	Current menu ID
 * @return		  PLUGIN_HANDLED
 */
stock ShowEmptyMessage(id, menuIdx) {
	new menu_data[MenuDataStruct]
	ArrayGetArray(g_Menus, menuIdx, menu_data)

	new iFilterCount = (menu_data[MENU_FILTERS_COND] != Invalid_Array) ? ArraySize(menu_data[MENU_FILTERS_COND]) : 0
	if (iFilterCount > 0) {
		for (new f = 0; f < iFilterCount; f++) {
			new condStr[CONDITION_LENGTH]
			ArrayGetString(menu_data[MENU_FILTERS_COND], f, condStr, charsmax(condStr))
			
			new matchCount = 0
			new players[32], pNum
			get_players(players, pNum)
			for (new j = 0; j < pNum; j++) {
				if (CheckCondition(players[j], id, condStr, false)) {
					matchCount++
				}
			}
			
			if (matchCount == 0) {
				new msgStr[NAME_LENGTH]
				ArrayGetString(menu_data[MENU_FILTERS_MSG], f, msgStr, charsmax(msgStr))
				if (msgStr[0]) {
					static message[RESTRICT_MSG_LENGTH], prefix[128]
					ResolveUiKey(id, g_ChatPrefix, DEF_CHAT_PREFIX, prefix, 127)

					if (IsMLKey(msgStr)) {
						SetGlobalTransTarget(id); LookupLangKey(message, 127, msgStr, id)
					} else copy(message, 127, msgStr)

					PrintColorMessage(id, fmt("%s %s", prefix, message))
					return
				}
			}
		}
		
		new msgStr[NAME_LENGTH]
		ArrayGetString(menu_data[MENU_FILTERS_MSG], 0, msgStr, charsmax(msgStr))
		if (msgStr[0]) {
			static message[RESTRICT_MSG_LENGTH], prefix[128]
			ResolveUiKey(id, g_ChatPrefix, DEF_CHAT_PREFIX, prefix, 127)

			if (IsMLKey(msgStr)) {
				SetGlobalTransTarget(id); LookupLangKey(message, 127, msgStr, id)
			} else copy(message, 127, msgStr)

			PrintColorMessage(id, fmt("%s %s", prefix, message))
		}
	}
}

public HandleMenu(id, iKey) {
	if (!is_user_connected(id) || g_ActiveMenu[id] == -1) return PLUGIN_HANDLED

	new activeMenuIdx = g_ActiveMenu[id]
	new menu_data[MenuDataStruct]; ArrayGetArray(g_Menus, activeMenuIdx, menu_data)
	// log_amx("[HandleMenu] Player: %d, Key: %d, Menu: %s", id, iKey, menu_data[MENU_SECTION])

	new fixedItemsCount = (menu_data[MENU_FIXED_ITEMS] != Invalid_Array) ? ArraySize(menu_data[MENU_FIXED_ITEMS]) : 0
	new itemsPerPage = MAX_MENU_ITEMS - fixedItemsCount
	if (itemsPerPage <= 0) itemsPerPage = 1

	if (iKey == 7) { // Key 8 - Next
		new totalPages = (g_MenuTotalItems[id] + itemsPerPage - 1) / itemsPerPage
		if (totalPages == 0) totalPages = 1

		if (g_MenuPage[id] < totalPages - 1) {
			g_MenuPage[id]++; mc_show_menu(id, menu_data[MENU_SECTION], .ignoreHistory = true, .targetId = g_MenuTargetId[id]);
		}
		return PLUGIN_HANDLED
	}

	if (iKey == 9) { // Key 0 - Exit
		mc_internal_close_menu(id)
		g_MenuHistoryDepth[id] = 0
		return PLUGIN_HANDLED
	}

	if (iKey == 8) { // Key 9 - Back
		if (ArrayGetCell(g_MenuActiveTimers, activeMenuIdx) > 0) return PLUGIN_HANDLED

		if (g_MenuPage[id] > 0) {
			g_MenuPage[id]--; mc_show_menu(id, menu_data[MENU_SECTION], .ignoreHistory = true, .targetId = g_MenuTargetId[id]); return PLUGIN_HANDLED
		}

		if (g_MenuHistoryDepth[id] > 0) {
			g_MenuHistoryDepth[id]--
			new prevMenuIdx = g_MenuHistory[id][g_MenuHistoryDepth[id]]
			new prevPageIdx = g_MenuHistoryPage[id][g_MenuHistoryDepth[id]]
			new prev_data[MenuDataStruct]; ArrayGetArray(g_Menus, prevMenuIdx, prev_data)
			
			g_MenuPage[id] = prevPageIdx
			mc_show_menu(id, prev_data[MENU_SECTION], -1, true)
		} else if (!menu_data[MENU_HIDE_BACK]) {
			 mc_internal_close_menu(id)
		}
		return PLUGIN_HANDLED
	}

	new action[ACTION_LENGTH], targetId = g_MenuTargetId[id], selectedVariant = 0
	if (menu_data[MENU_TYPE] == MENU_TYPE_LIST) {
		if (iKey >= 7) return PLUGIN_HANDLED
		if (g_IsItemDisabled[id][iKey]) return PLUGIN_HANDLED
		targetId = g_MenuItemTargetIds[id][iKey]

		if (g_MenuItemTypes[id][iKey] == 1) { // Fixed item
			copy(action, ACTION_LENGTH - 1, g_MenuItemActions[id][iKey])
		} else {
			new item[MenuItemStruct]; ArrayGetArray(menu_data[MENU_ITEMS_ARRAY], 0, item)
			new selectedVariant = -1
			new vCount = ArraySize(item[ITEM_VARIANTS])
			for (new j = 0; j < vCount; j++) {
				new var[VariantStruct]; ArrayGetArray(item[ITEM_VARIANTS], j, var)
				if (!var[VAR_CONDITION][0] || CheckCondition(targetId, id, var[VAR_CONDITION], false)) { selectedVariant = j; break; }
			}

			if (selectedVariant == -1) return PLUGIN_HANDLED
			new var[VariantStruct]; ArrayGetArray(item[ITEM_VARIANTS], selectedVariant, var)

			if (g_MenuItemActions[id][iKey][0]) {
				new bool:actionExists = TrieKeyExists(g_ActionTrie, g_MenuItemActions[id][iKey])
				if (actionExists || equal(g_MenuItemActions[id][iKey], "CLOSE_MENU") || contain(g_MenuItemActions[id][iKey], "SHOW_") == 0) {
					copy(action, ACTION_LENGTH - 1, g_MenuItemActions[id][iKey]);
				} else {
					copy(action, ACTION_LENGTH - 1, var[VAR_ACTION]);
				}
			} else {
				copy(action, ACTION_LENGTH - 1, var[VAR_ACTION]);
			}
		}
	} else {
		if (iKey >= 7) return PLUGIN_HANDLED
		new bool:hasFixed = false
		new fixed_item[FixedItemStruct]
		if (menu_data[MENU_FIXED_ITEMS] != Invalid_Array) {
			for (new j = 0, size = ArraySize(menu_data[MENU_FIXED_ITEMS]); j < size; j++) {
				ArrayGetArray(menu_data[MENU_FIXED_ITEMS], j, fixed_item)
				if (fixed_item[FIXED_SLOT] == iKey) {
					hasFixed = true; break
				}
			}
		}

		new item[MenuItemStruct]
		if (hasFixed) {
			item[ITEM_VARIANTS] = fixed_item[FIXED_DATA][ITEM_VARIANTS]
			copy(item[ITEM_PLACEHOLDER], PLACEHOLDER_LENGTH - 1, fixed_item[FIXED_DATA][ITEM_PLACEHOLDER])
			copy(item[ITEM_RESTRICTION], RESTRICT_LENGTH - 1, fixed_item[FIXED_DATA][ITEM_RESTRICTION])
			copy(item[ITEM_RESTRICT_MSG], RESTRICT_MSG_LENGTH - 1, fixed_item[FIXED_DATA][ITEM_RESTRICT_MSG])
			item[ITEM_EMPTY_BEFORE] = fixed_item[FIXED_DATA][ITEM_EMPTY_BEFORE]
			item[ITEM_EMPTY_AFTER] = fixed_item[FIXED_DATA][ITEM_EMPTY_AFTER]
		} else {
			// Calculate how many fixed items are BEFORE this key to get correct index in main array
			new fixedBefore = 0
			if (menu_data[MENU_FIXED_ITEMS] != Invalid_Array) {
				for (new j = 0, size = ArraySize(menu_data[MENU_FIXED_ITEMS]); j < size; j++) {
					new temp[FixedItemStruct]; ArrayGetArray(menu_data[MENU_FIXED_ITEMS], j, temp)
					if (temp[FIXED_SLOT] < iKey) fixedBefore++
				}
			}

			new countBefore = 0
			for(new slot = 0; slot < iKey; slot++) {
				new bool:f = false
				if (menu_data[MENU_FIXED_ITEMS] != Invalid_Array) {
					for (new j = 0, size = ArraySize(menu_data[MENU_FIXED_ITEMS]); j < size; j++) {
						new temp[FixedItemStruct]; ArrayGetArray(menu_data[MENU_FIXED_ITEMS], j, temp)
						if (temp[FIXED_SLOT] == slot) { f = true; break; }
					}
				}
				if (!f) countBefore++
			}

			new fixedPerPage = 0;
			if (menu_data[MENU_FIXED_ITEMS] != Invalid_Array) fixedPerPage = ArraySize(menu_data[MENU_FIXED_ITEMS]);
			new itemsPerPage = MAX_MENU_ITEMS - fixedPerPage;
			if (itemsPerPage <= 0) itemsPerPage = 1;

			new realIndex = g_MenuPage[id] * itemsPerPage + countBefore;
			if (realIndex >= ArraySize(menu_data[MENU_ITEMS_ARRAY])) return PLUGIN_HANDLED;
			ArrayGetArray(menu_data[MENU_ITEMS_ARRAY], realIndex, item);
		}

		new vCount = 0
		if (item[ITEM_VARIANTS] != Invalid_Array) {
			vCount = ArraySize(item[ITEM_VARIANTS])
		}

		for (new j = 0; j < vCount; j++) {
			new var[VariantStruct]; ArrayGetArray(item[ITEM_VARIANTS], j, var)
			if (!var[VAR_CONDITION][0] || CheckCondition(id, id, var[VAR_CONDITION], false)) { selectedVariant = j; break; }
		}

		if (item[ITEM_VARIANTS] != Invalid_Array && selectedVariant != -1) {
			new var[VariantStruct]; ArrayGetArray(item[ITEM_VARIANTS], selectedVariant, var)
			copy(action, ACTION_LENGTH-1, var[VAR_ACTION])
		}
	}

	if (action[0]) {
		new previousMenuIdx = g_ActiveMenu[id]
		// log_amx("[HandleMenu] Action: '%s', TargetID: %d", action, targetId)
		ExecuteAction(id, action, targetId)
		if (g_ActiveMenu[id] != -1 && g_ActiveMenu[id] == previousMenuIdx) mc_show_menu(id, menu_data[MENU_SECTION], .targetId = g_MenuTargetId[id])
	}
	return PLUGIN_HANDLED
}

stock mc_refresh_menu(const sections[]) {
	new tokens[8][NAME_LENGTH], count, refreshCount, i, id, menuIdx
	count = ParseTokens(sections, tokens, 8, NAME_LENGTH)
	refreshCount = 0
	for (i = 0; i < count; i++) {
		if (TrieGetCell(g_MenuTrie, tokens[i], menuIdx)) {
			for (id = 1; id <= MaxClients; id++) {
				if (is_user_connected(id) && g_ActiveMenu[id] == menuIdx) {
					if (mc_show_menu(id, tokens[i], -1, .targetId = g_MenuTargetId[id])) refreshCount++
				}
			}
		}
	}
	return refreshCount
}

stock mc_notify_condition_changed(const condition[]) {
	new Array:menuList
	if (!TrieGetCell(g_ConditionMenuMap, condition, menuList) || menuList == Invalid_Array) return
	new section[NAME_LENGTH]
	for (new i = 0, size = ArraySize(menuList); i < size; i++) {
		ArrayGetString(menuList, i, section, NAME_LENGTH-1)
		new menuIdx; if (!TrieGetCell(g_MenuTrie, section, menuIdx)) continue
		for (new id = 1; id <= MaxClients; id++) {
			if (is_user_connected(id) && g_ActiveMenu[id] == menuIdx) mc_show_menu(id, section)
		}
	}
}

stock InternalCancelMenuTimer(menuIdx) {
	if (ArrayGetCell(g_MenuActiveTimers, menuIdx) == 0) return 0

	remove_task(menuIdx)
	ArraySetCell(g_MenuActiveTimers, menuIdx, 0)

	new menu_data[MenuDataStruct]
	ArrayGetArray(g_Menus, menuIdx, menu_data)

	for (new id = 1; id <= MaxClients; id++) {
		if (is_user_connected(id) && g_ActiveMenu[id] == menuIdx) {
			mc_internal_close_menu(id)
		}
	}

	#if DEBUG
		log_amx("[MenuSystem] Timer cancelled for menu %s, closed for all players", menu_data[MENU_SECTION])
	#endif

	return 1
}

/* ============================================================================================== */
/*                                [ CORE - CONDITIONS & ACTIONS ]                                 */
/* ============================================================================================== */

/**
 * Lazily resolve and cache a registry entry's callback func id.
 *
 * Reads the cached id from cell `funcBlock` of item `idx` in `arr`. On the first
 * call (FUNC_UNRESOLVED) it resolves via get_func_id() and writes the result back,
 * so every later call is a single ArrayGetCell instead of a string-based lookup.
 * Func ids are stable for the server's lifetime, so caching (including -1) is safe.
 */
stock ResolveFunc(Array:arr, idx, funcBlock, const callback[], plugin) {
	new func = ArrayGetCell(arr, idx, funcBlock)
	if (func == FUNC_UNRESOLVED) {
		func = get_func_id(callback, plugin)
		ArraySetCell(arr, idx, func, funcBlock)
	}
	return func
}

stock bool:CheckCondition(id, viewerId, const condition[], bool:isRestriction = false) {
	if (!condition[0]) return true

	new tokenCount, bool:result, bool:bVal, i, func
	new bool:negate, conditionName[CONDITION_LENGTH]
	new bool:restrictionFound
	new searchKey[CONDITION_LENGTH], regIdx
	new cond_data[ConditionDataStruct]
	new bool:conditionFound
	static buffer[16][CONDITION_LENGTH]

	result = true
	bVal = false
	tokenCount = ParseTokens(condition, buffer, 16, CONDITION_LENGTH)

	static rest_data[RestrictionDataStruct]
	for (i = 0; i < tokenCount; i++) {
		negate = buffer[i][0] == '!'
		if (negate) copy(conditionName, sizeof(conditionName) - 1, buffer[i][1])
		else copy(conditionName, sizeof(conditionName) - 1, buffer[i])

		if (isRestriction) {
			restrictionFound = false

			// Pass 1: Exact / parameterized ("NAME:param") restriction via Trie.
			// Key is UPPER(name before ':') to preserve the old equali() case-insensitivity.
			copy(searchKey, charsmax(searchKey), conditionName)
			new colonPos = contain(searchKey, ":")
			if (colonPos != -1) searchKey[colonPos] = 0
			strtoupper(searchKey)

			if (TrieGetCell(g_RestrictionTrie, searchKey, regIdx)) {
				ArrayGetArray(g_Restrictions, regIdx, rest_data)
				func = ResolveFunc(g_Restrictions, regIdx, _:RESTRICT_FUNC, rest_data[RESTRICT_CALLBACK], rest_data[RESTRICT_PLUGIN])
				if (func != -1 && callfunc_begin_i(func, rest_data[RESTRICT_PLUGIN]) == 1) {
					callfunc_push_int(id); callfunc_push_str(conditionName); callfunc_push_int(viewerId)
					bVal = bool:callfunc_end()
					restrictionFound = true
				}
			}

			// Pass 2: Fallback to the "*" wildcard handler if no specific handler found
			if (!restrictionFound && g_WildcardRestrictIdx != -1) {
				ArrayGetArray(g_Restrictions, g_WildcardRestrictIdx, rest_data)
				func = ResolveFunc(g_Restrictions, g_WildcardRestrictIdx, _:RESTRICT_FUNC, rest_data[RESTRICT_CALLBACK], rest_data[RESTRICT_PLUGIN])
				if (func != -1 && callfunc_begin_i(func, rest_data[RESTRICT_PLUGIN]) == 1) {
					callfunc_push_int(id); callfunc_push_str(conditionName); callfunc_push_int(viewerId)
					bVal = bool:callfunc_end()
					restrictionFound = true
				}
			}

			// Pass 3: Fallback to a registered Condition with the same name
			if (!restrictionFound) {
				copy(searchKey, charsmax(searchKey), conditionName); strtoupper(searchKey)
				if (TrieGetCell(g_ConditionTrie, searchKey, regIdx)) {
					ArrayGetArray(g_Conditions, regIdx, cond_data)
					func = ResolveFunc(g_Conditions, regIdx, _:COND_FUNC, cond_data[COND_CALLBACK], cond_data[COND_PLUGIN])
					if (func != -1 && callfunc_begin_i(func, cond_data[COND_PLUGIN]) == 1) {
						callfunc_push_int(id); callfunc_push_int(viewerId); callfunc_push_str(conditionName)
						bVal = bool:callfunc_end()
						bVal = ApplyConditionFilters(id, viewerId, conditionName, bVal)
						restrictionFound = true
					}
				}
			}

			if (!restrictionFound) {
				if (equali(conditionName, "ADMIN") || equali(conditionName, "ACCESS_ADMIN")) {
					bVal = bool:(get_user_flags(id) & (ADMIN_BAN|ADMIN_RCON|ADMIN_ADMIN|ADMIN_MENU))
					restrictionFound = true
				} else if (containi(conditionName, "FLAG_") == 0) {
					bVal = bool:(get_user_flags(id) & read_flags(conditionName[5]))
					restrictionFound = true
				} else {
					bVal = false
				}
			}

			result = result && (negate ? !bVal : bVal)
			continue
		}

		conditionFound = false
		copy(searchKey, charsmax(searchKey), conditionName); strtoupper(searchKey)
		if (TrieGetCell(g_ConditionTrie, searchKey, regIdx)) {
			ArrayGetArray(g_Conditions, regIdx, cond_data)
			func = ResolveFunc(g_Conditions, regIdx, _:COND_FUNC, cond_data[COND_CALLBACK], cond_data[COND_PLUGIN])

			if (func != -1 && callfunc_begin_i(func, cond_data[COND_PLUGIN]) == 1) {
				callfunc_push_int(id)
				callfunc_push_int(viewerId)
				callfunc_push_str(conditionName)

				bVal = bool:callfunc_end()
				result = result && (negate ? !bVal : bVal)
				conditionFound = true
			}
		}
		if (!conditionFound) {
			if (equali(conditionName, "ADMIN") || equali(conditionName, "ACCESS_ADMIN")) {
				bVal = bool:(get_user_flags(id) & (ADMIN_BAN|ADMIN_RCON|ADMIN_ADMIN|ADMIN_MENU));
				#if DEBUG
					log_amx("[MenuCore] Condition '%s' evaluated to %d via fallback (Flags: %d)", conditionName, bVal, get_user_flags(id))
				#endif
				result = result && (negate ? !bVal : bVal); conditionFound = true;
			} else if (containi(conditionName, "FLAG_") == 0) {
				bVal = bool:(get_user_flags(id) & read_flags(conditionName[5]));
				#if DEBUG
					log_amx("[MenuCore] Condition '%s' evaluated to %d via FLAG fallback", conditionName, bVal)
				#endif
				result = result && (negate ? !bVal : bVal); conditionFound = true;
			} else {
				#if DEBUG
					log_amx("[MenuCore] Condition '%s' NOT FOUND, assuming FAIL", conditionName)
				#endif
				result = false
			}
		}
	}
	#if DEBUG
		log_amx("[MenuCore] CheckCondition result for '%s': %d", condition, result)
	#endif
	return result
}

stock bool:CheckActionConditions(id, const menuSection[], const action[]) {
	if (!action[0]) return true

	new ac_data[ActionConditionStruct]
	for (new i = 0, size = ArraySize(g_ActionConditions); i < size; i++) {
		ArrayGetArray(g_ActionConditions, i, ac_data)

		// 1. Menu filter (if AC_MENU_SECTION is set, it must match)
		if (ac_data[AC_MENU_SECTION][0] && !equal(ac_data[AC_MENU_SECTION], menuSection)) {
			continue
		}

		// 2. Action filter (if AC_ACTION_NAME is set, it must match)
		if (ac_data[AC_ACTION_NAME][0] && !equal(ac_data[AC_ACTION_NAME], action)) {
			continue
		}

		new func = ResolveFunc(g_ActionConditions, i, _:AC_FUNC, ac_data[AC_CALLBACK], ac_data[AC_PLUGIN])
		if (func != -1 && callfunc_begin_i(func, ac_data[AC_PLUGIN]) == 1) {
			callfunc_push_int(id)
			callfunc_push_str(menuSection)
			callfunc_push_str(action)
			if (!callfunc_end()) {
				return false
			}
		}
	}
	return true
}

stock bool:ApplyConditionFilters(id, viewerId, const conditionName[], bool:currentVal) {
	new cf_data[ConditionFilterStruct]
	new bool:result = currentVal
	for (new i = 0, size = ArraySize(g_ConditionFilters); i < size; i++) {
		ArrayGetArray(g_ConditionFilters, i, cf_data)
		if (equali(cf_data[CF_COND_NAME], conditionName)) {
			new func = ResolveFunc(g_ConditionFilters, i, _:CF_FUNC, cf_data[CF_CALLBACK], cf_data[CF_PLUGIN])
			if (func != -1 && callfunc_begin_i(func, cf_data[CF_PLUGIN]) == 1) {
				callfunc_push_int(id)
				callfunc_push_int(viewerId)
				callfunc_push_str(conditionName)
				callfunc_push_int(result ? 1 : 0)
				result = bool:callfunc_end()
			}
		}
	}
	return result
}

stock ExecuteAction(id, const action[], targetId = 0) {
	static tokens[16][ACTION_LENGTH]
	new count = ParseTokens(action, tokens, 16, ACTION_LENGTH)
	for (new i = 0; i < count; i++) {
		if (equal(tokens[i], "CLOSE_MENU")) {
			mc_internal_close_menu(id); continue
		}
		if (contain(tokens[i], "SHOW_") == 0) {
			mc_show_menu(id, tokens[i][5], 0, false, .forceOpening = true); continue
		}

		// Tokens carry no spaces (ParseTokens splits on them), so the old prefix test
		// reduces to exact name equality -> O(1) Trie lookup by the action name.
		new actIdx
		if (TrieGetCell(g_ActionTrie, tokens[i], actIdx)) {
			new act[ActionDataStruct]; ArrayGetArray(g_Actions, actIdx, act)
			new pluginId = act[ACTION_PLUGIN]
			new func = ResolveFunc(g_Actions, actIdx, _:ACTION_FUNC, act[ACTION_CALLBACK], pluginId)
			if (func != -1 && callfunc_begin_i(func, pluginId) == 1) {
				callfunc_push_int(id)
				new menuIdx = g_ActiveMenu[id]
				if (menuIdx != -1) {
					new menu_data[MenuDataStruct]; ArrayGetArray(g_Menus, menuIdx, menu_data)
					if (menu_data[MENU_TYPE] == MENU_TYPE_STRICT) {
						callfunc_push_str(tokens[i])
					} else {
						callfunc_push_int(targetId)
					}
				} else {
					callfunc_push_int(targetId)
				}
				callfunc_end()
			} else {
				log_amx("[MenuCore] Failed to start callfunc (Func: %d, Plugin: %d)", func, pluginId)
			}
		}
	}
}

stock bool:IsCriticalAction(const action[]) {
	new isCritical
	return TrieGetCell(g_CriticalActions, action, isCritical) && isCritical
}

/* ============================================================================================== */
/*                                     [ HELPERS - PARSING ]                                      */
/* ============================================================================================== */

stock ParseTokens(const input[], output[][], maxTokens, tokenLength) {
	new temp[CONDITION_LENGTH], pos = 0, tokenCount = 0
	copy(temp, sizeof(temp) - 1, input)
	while (temp[pos] && tokenCount < maxTokens) {
		new spacePos = contain(temp[pos], " ")
		if (spacePos < 0) {
			copy(output[tokenCount], tokenLength - 1, temp[pos])
			trim(output[tokenCount])
			if (output[tokenCount][0]) tokenCount++
			break
		}
		new len = min(spacePos, tokenLength - 1)
		copy(output[tokenCount], len, temp[pos])
		pos += spacePos + 1
		trim(output[tokenCount])
		if (output[tokenCount][0]) tokenCount++
	}
	return tokenCount
}

/**
 * Parse pipe-separated values into tokens array
 * @param input		 Input string with pipe-separated values
 * @param output		Output array to store tokens
 * @param maxTokens	 Maximum number of tokens to parse
 * @param tokenLength   Length of each token in output array
 * @param debugName	 Name for debug logging (optional)
 * @return			  Number of parsed tokens
 */
stock ParsePipeSeparated(const input[], output[][], maxTokens, tokenLength, const debugName[] = "") {
	#if !DEBUG
		#pragma unused debugName
	#endif
	static temp[1024]
	new tokenCount = 0
	copy(temp, sizeof(temp) - 1, input)

	for (new pos = 0; temp[pos] && tokenCount < maxTokens;) {
		new pipePos = contain(temp[pos], "|")
		if (pipePos < 0) {
			// Last token (no more pipes)
			copy(output[tokenCount], tokenLength - 1, temp[pos])
			trim(output[tokenCount])
			if (output[tokenCount][0]) {
				#if DEBUG
					if (debugName[0]) {
						log_amx("[MenuSystem] Parsed %s token %d: '%s'", debugName, tokenCount, output[tokenCount])
					}
				#endif
				tokenCount++
			}
			break
		}
		// Extract token before pipe
		copy(output[tokenCount], min(pipePos, tokenLength - 1), temp[pos])
		pos += pipePos + 1
		trim(output[tokenCount])
		if (output[tokenCount][0]) {
			#if DEBUG
				if (debugName[0]) {
					log_amx("[MenuSystem] Parsed %s token %d: '%s'", debugName, tokenCount, output[tokenCount])
				}
			#endif
			tokenCount++
		}
	}

	return tokenCount
}

stock ParseVariantsToPool(const name[], const condition[], const action[], Array:variantsPool) {
	static buffer[16][CONDITION_LENGTH]
	static names[16][NAME_LENGTH]
	static conditions[16][CONDITION_LENGTH]
	static actions[16][ACTION_LENGTH]

	new nameCount, conditionCount, actionCount, variantCount, i
	new var_data[VariantStruct]

	nameCount = ParsePipeSeparated(name, buffer, 16, NAME_LENGTH)
	for(i=0; i<nameCount; i++) copy(names[i], NAME_LENGTH-1, buffer[i])

	conditionCount = ParsePipeSeparated(condition, buffer, 16, CONDITION_LENGTH)
	for(i=0; i<conditionCount; i++) copy(conditions[i], CONDITION_LENGTH-1, buffer[i])

	actionCount = ParsePipeSeparated(action, buffer, 16, ACTION_LENGTH)
	for(i=0; i<actionCount; i++) copy(actions[i], ACTION_LENGTH-1, buffer[i])

	variantCount = 0
	if (actionCount <= 1) variantCount = max(nameCount, conditionCount)
	else if (nameCount == 1) variantCount = actionCount
	else variantCount = min(nameCount, actionCount)

	if (variantCount == 0 && nameCount > 0) variantCount = nameCount
	if (variantCount == 0) return 0

	for (i = 0; i < variantCount; i++) {
		copy(var_data[VAR_NAME], NAME_LENGTH - 1, names[nameCount == 1 ? 0 : i])
		if (i < conditionCount) {
			copy(var_data[VAR_CONDITION], CONDITION_LENGTH - 1, conditions[i])
		} else {
			var_data[VAR_CONDITION][0] = 0
		}
		copy(var_data[VAR_ACTION], ACTION_LENGTH - 1, actions[actionCount == 1 ? 0 : i])
		ArrayPushArray(variantsPool, var_data)
	}

	return variantCount
}

stock ParseRestrictMsg(const input[], output[][RESTRICT_MSG_LENGTH], maxPairs, pairLength) {
	new temp[RESTRICT_MSG_LENGTH]
	new pos = 0, pairCount = 0, copyLen
	copy(temp, RESTRICT_MSG_LENGTH-1, input)
	while (temp[pos] && pairCount < maxPairs) {
		new pipePos = contain(temp[pos], "|")
		if (pipePos < 0) {
			copy(output[pairCount], pairLength - 1, temp[pos]); trim(output[pairCount])
			if (output[pairCount][0]) pairCount++; break
		}
		copyLen = min(pipePos, pairLength - 1)
		copy(output[pairCount], copyLen, temp[pos])
		pos += pipePos + 1
		trim(output[pairCount])
		if (output[pairCount][0]) pairCount++
	}
	return pairCount
}

stock RegisterConditionTokens(const condStr[], const section[]) {
	if (!condStr[0]) return
	static buffer[16][CONDITION_LENGTH]
	new tokenCount = ParseTokens(condStr, buffer, 16, CONDITION_LENGTH)
	for (new j = 0; j < tokenCount; j++) {
		new conditionName[CONDITION_LENGTH]
		if (buffer[j][0] == '!') copy(conditionName, sizeof(conditionName) - 1, buffer[j][1])
		else copy(conditionName, sizeof(conditionName) - 1, buffer[j])
		AddMenuToConditionMap(conditionName, section)
	}
}

stock AddMenuToConditionMap(const conditionName[], const section[]) {
	if (!conditionName[0] || !section[0]) {
		#if DEBUG
			log_amx("[MenuSystem] Invalid condition or section: condition='%s', section='%s'", conditionName, section)
		#endif
		return
	}

	new Array:menuList
	if (!TrieGetCell(g_ConditionMenuMap, conditionName, menuList)) {
		menuList = ArrayCreate(NAME_LENGTH)
		TrieSetCell(g_ConditionMenuMap, conditionName, menuList)
	}

	for (new k = 0, size = ArraySize(menuList); k < size; k++) {
		new temp[NAME_LENGTH]
		ArrayGetString(menuList, k, temp, sizeof(temp) - 1)
		if (equal(temp, section)) {
			#if DEBUG
				log_amx("[MenuSystem] Section %s already mapped to condition %s", section, conditionName)
			#endif
			return
		}
	}

	ArrayPushString(menuList, section)
	#if DEBUG
		log_amx("[MenuSystem] Added menu %s to condition %s", section, conditionName)
	#endif
}

stock bool:ParseBoolFlag(const value[]) {
	return (str_to_num(value) != 0 || equali(value, "true") || equali(value, "yes"))
}

/* ============================================================================================== */
/*                                  [ HELPERS - TEXT & DISPLAY ]                                  */
/* ============================================================================================== */

stock ReplacePlaceholders(id, targetId, output[], outputLen, const input[], const defaultName[] = "", menuIdx = -1) {
	if (!is_user_connected(id)) return

	static buffer[1024], value[256]
	if (IsMLKey(input)) {
		SetGlobalTransTarget(id);
		if (!LookupLangKey(buffer, sizeof(buffer) - 1, input, id)) {
			copy(buffer, sizeof(buffer) - 1, input);
		}
	} else copy(buffer, sizeof(buffer) - 1, input)

	if (strfind(buffer, "%") == -1) {
		copy(output, outputLen - 1, buffer)
		return
	}

	if (defaultName[0]) {
		if (strfind(buffer, "%name%", true) != -1) {
			if (IsMLKey(defaultName)) {
				SetGlobalTransTarget(id); LookupLangKey(value, charsmax(value), defaultName, id)
			} else copy(value, charsmax(value), defaultName)
			replace_all(buffer, sizeof(buffer) - 1, "%name%", value)
		}
	}

	for (new i = 0, size = ArraySize(g_Placeholders); i < size; i++) {
		new place_data[PlaceholderDataStruct]
		ArrayGetArray(g_Placeholders, i, place_data)

		static placeholder[64]; formatex(placeholder, 63, "%%%s%%", place_data[PLACE_NAME])
		if (strfind(buffer, placeholder, true) == -1) continue

		value[0] = 0
		new funcId = ResolveFunc(g_Placeholders, i, _:PLACE_FUNC, place_data[PLACE_CALLBACK], place_data[PLACE_PLUGIN])
		if (funcId != -1 && callfunc_begin_i(funcId, place_data[PLACE_PLUGIN]) == 1) {
			callfunc_push_int(id); callfunc_push_int(targetId)
			callfunc_push_array(value, sizeof(value)); callfunc_push_int(sizeof(value))
			callfunc_end()
		}
		replace_all(buffer, sizeof(buffer) - 1, placeholder, value)
	}

	if (strfind(buffer, "%time%", true) != -1 || strfind(buffer, "%TIME%", true) != -1) {
		new timeVal = 0
		new activeIdx = (menuIdx != -1) ? menuIdx : g_ActiveMenu[id]
		if (activeIdx != -1) {
			timeVal = g_PlayerMenuTimer[id] > 0 ? g_PlayerMenuTimer[id] : ArrayGetCell(g_MenuActiveTimers, activeIdx)
		}
		static szTime[12]; num_to_str(timeVal, szTime, 11)
		replace_all(buffer, sizeof(buffer) - 1, "%time%", szTime)
		replace_all(buffer, sizeof(buffer) - 1, "%TIME%", szTime)
	}

	if (targetId > 0 && targetId <= get_maxplayers() && (strfind(buffer, "%target%", true) != -1 || strfind(buffer, "%s", true) != -1)) {
		static szTargetName[32]; get_user_name(targetId, szTargetName, charsmax(szTargetName))
		replace_all(buffer, sizeof(buffer) - 1, "%target%", szTargetName)
		replace_all(buffer, sizeof(buffer) - 1, "%s", szTargetName)
	}

	copy(output, outputLen - 1, buffer)
}

stock bool:LooksLikeLangKey(const s[]) {
	if (!s[0]) return false
	for (new i = 0; s[i]; i++) {
		new c = s[i]
		if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) return false
	}
	return true
}

// Resolve a UI lang key to display text: registered ML key -> translation;
// dead ML-key-looking string -> built-in default; anything else -> as-is.
stock ResolveUiKey(id, const key[], const def[], out[], len) {
	if (IsMLKey(key)) {
		SetGlobalTransTarget(id)
		if (!LookupLangKey(out, len, key, id)) copy(out, len, def)
	} else if (LooksLikeLangKey(key)) {
		copy(out, len, def)
	} else {
		copy(out, len, key)
	}
}

stock FormatMenuItem(id, key, const langKey[], output[], len, bool:isDisabled = false) {
	static formatBuffer[64], textBuffer[ITEM_BUF_SIZE], numStr[8]
	ResolveUiKey(id, isDisabled ? g_LangKeyDisabled : g_LangKeyNumber, isDisabled ? DEF_KEY_DISABLED : DEF_KEY_NUMBER, formatBuffer, 63)
	num_to_str(key, numStr, 7); replace(formatBuffer, 63, "%d", numStr)
	if (IsMLKey(langKey)) { SetGlobalTransTarget(id); LookupLangKey(textBuffer, ITEM_BUF_SIZE - 1, langKey, id); }
	else copy(textBuffer, ITEM_BUF_SIZE - 1, langKey)
	formatex(output, len, "%s %s", formatBuffer, textBuffer)
}

/**
 * Checks if a string is a multilanguage key or direct text
 * Uses GetLangTransKey to check if key exists in language files
 *
 * @param str		   String to check
 * @return			  True if string is ML key (exists in lang files), false if direct text
 */
stock bool:IsMLKey(const str[]) {
	if (!str[0]) return false

	if (GetLangTransKey(str) == TransKey:-1) {
		return false
	}
	return true
}

/**
 * Print colored message to player using SayText with color tags
 * Supports: !g (green/0x04), !t (team/0x03), !y (default/0x01)
 *
 * @param id			Player index (0 for all players)
 * @param message	   Message with color tags
 */
stock PrintColorMessage(id, const message[], sender_id = 0) {
	if (!sender_id) sender_id = id;

	static szBuffer[256];
	new szTeamToSet[16];

	// Process tags and detect if we need a color swap
	replace_color_tags_ex(message, szBuffer, charsmax(szBuffer), szTeamToSet, charsmax(szTeamToSet), sender_id);

	static iSayText; if (!iSayText) iSayText = get_user_msgid("SayText");
	static iTeamInfo; if (!iTeamInfo) iTeamInfo = get_user_msgid("TeamInfo");

	if (id) {
		if (is_user_connected(id)) {
			_RawSendColorMessage(id, sender_id, szBuffer, szTeamToSet, iSayText, iTeamInfo);
		}
	} else {
		new maxPlayers = get_maxplayers();
		for (new i = 1; i <= maxPlayers; i++) {
			if (is_user_connected(i)) {
				_RawSendColorMessage(i, sender_id ? sender_id : i, szBuffer, szTeamToSet, iSayText, iTeamInfo);
			}
		}
	}
}

/**
 * Optimized raw message sender
 */
stock _RawSendColorMessage(id, sender_id, const szMessage[], const szTeamToSet[], iSayText, iTeamInfo) {
	if (szTeamToSet[0]) {
		static szSenderOldTeam[16];
		get_user_team(sender_id, szSenderOldTeam, charsmax(szSenderOldTeam));

		// Swap sender's team in recipient's cache
		message_begin(MSG_ONE, iTeamInfo, _, id);
		write_byte(sender_id);
		write_string(szTeamToSet);
		message_end();

		// Send message
		message_begin(MSG_ONE, iSayText, _, id);
		write_byte(sender_id);
		write_string(szMessage);
		message_end();

		// Restore sender's team in recipient's cache
		message_begin(MSG_ONE, iTeamInfo, _, id);
		write_byte(sender_id);
		write_string(szSenderOldTeam);
		message_end();
	} else {
		message_begin(MSG_ONE, iSayText, _, id);
		write_byte(sender_id);
		write_string(szMessage);
		message_end();
	}
}

/**
 * Extended color tag replacer (Internal)
 * Processes !tags and detect which TeamInfo swap is required.
 */
stock replace_color_tags_ex(const szInput[], szOutput[], iLen, szTeamToSet[], iTeamLen, sender_id = 0) {
	szTeamToSet[0] = 0;

	// Determine the sender's team once if it's potentially needed
	static szSenderTeamColor[16];
	szSenderTeamColor[0] = 0;

	if (sender_id > 0 && sender_id <= get_maxplayers() && is_user_connected(sender_id)) {
		new TeamName:iTeam = TeamName:get_member(sender_id, m_iTeam);
		if (iTeam == TEAM_TERRORIST) copy(szSenderTeamColor, charsmax(szSenderTeamColor), TEAM_FOR_RED);
		else if (iTeam == TEAM_CT) copy(szSenderTeamColor, charsmax(szSenderTeamColor), TEAM_FOR_BLUE);
		else if (iTeam == TEAM_SPECTATOR) copy(szSenderTeamColor, charsmax(szSenderTeamColor), TEAM_FOR_GREY);
	}

	new i = 0, j = 0;
	while (szInput[i] && j < iLen) {
		if (szInput[i] == '!') {
			new ch = szInput[i + 1];
			if (!ch) break;

			i += 2;
			switch (ch) {
				case 'G', 'g': szOutput[j++] = 0x04;
				case 'T', 't': {
					szOutput[j++] = 0x03;
					if (!szTeamToSet[0] && szSenderTeamColor[0]) copy(szTeamToSet, iTeamLen, szSenderTeamColor);
				}
				case 'Y', 'y': szOutput[j++] = 0x01;
				case 'R', 'r': {
					szOutput[j++] = 0x03;
					if (!szTeamToSet[0]) copy(szTeamToSet, iTeamLen, TEAM_FOR_RED);
				}
				case 'B', 'b': {
					szOutput[j++] = 0x03;
					if (!szTeamToSet[0]) copy(szTeamToSet, iTeamLen, TEAM_FOR_BLUE);
				}
				case 'W', 'w': {
					szOutput[j++] = 0x03;
					if (!szTeamToSet[0]) copy(szTeamToSet, iTeamLen, TEAM_FOR_GREY);
				}
				default: {
					szOutput[j++] = '!';
					i--; // Backtrack for the character after '!'
				}
			}
		} else if (szInput[i] == '&' && szInput[i + 1] == 'x' && _is_hex(szInput[i+2]) && _is_hex(szInput[i+3])) {
			new iColor = (_hex_dec(szInput[i+2]) << 4) | _hex_dec(szInput[i+3]);
			szOutput[j++] = iColor;
			i += 4;

			// Fixed color mapping for TeamInfo hack
			if (!szTeamToSet[0]) {
				if (iColor == 0x07) { szOutput[j-1] = 0x03; copy(szTeamToSet, iTeamLen, TEAM_FOR_RED); }
				else if (iColor == 0x06) { szOutput[j-1] = 0x03; copy(szTeamToSet, iTeamLen, TEAM_FOR_BLUE); }
				else if (iColor == 0x05) { szOutput[j-1] = 0x03; copy(szTeamToSet, iTeamLen, TEAM_FOR_GREY); }
			}
		} else {
			szOutput[j++] = szInput[i++];
		}
	}
	szOutput[j] = 0;
}

stock _hex_dec(ch) {
	if ('0' <= ch <= '9') return ch - '0';
	if ('a' <= ch <= 'f') return ch - 'a' + 10;
	if ('A' <= ch <= 'F') return ch - 'A' + 10;
	return 0;
}

stock bool:_is_hex(ch) {
	return (('0' <= ch <= '9') || ('a' <= ch <= 'f') || ('A' <= ch <= 'F'));
}

/* ============================================================================================== */
/*                                     [ CALLBACKS & TIMERS ]                                     */
/* ============================================================================================== */

stock InvokeMenuOpenCallbacks(id, const section[]) {
	for (new i = 0, size = ArraySize(g_MenuOpenCallbacks); i < size; i++) {
		new lc_data[LifecycleCallbackStruct]
		ArrayGetArray(g_MenuOpenCallbacks, i, lc_data)

		new func = ResolveFunc(g_MenuOpenCallbacks, i, _:LC_FUNC, lc_data[LC_CALLBACK], lc_data[LC_PLUGIN])
		if (func != -1 && callfunc_begin_i(func, lc_data[LC_PLUGIN]) == 1) {
			callfunc_push_int(id);
			callfunc_push_str(section);
			callfunc_end()
		}
	}
}

// Returns false if any registered filter vetoes opening this menu (its callback returns 0), so
// mc_show_menu aborts before rendering. The filter callback is where the plugin shows its own
// "why" message. Signature: public bool:callback(id, const section[]) — return true to allow.
stock bool:InvokeShowFilters(id, const section[]) {
	for (new i = 0, size = ArraySize(g_ShowFilters); i < size; i++) {
		new lc_data[LifecycleCallbackStruct]
		ArrayGetArray(g_ShowFilters, i, lc_data)

		new func = ResolveFunc(g_ShowFilters, i, _:LC_FUNC, lc_data[LC_CALLBACK], lc_data[LC_PLUGIN])
		if (func != -1 && callfunc_begin_i(func, lc_data[LC_PLUGIN]) == 1) {
			callfunc_push_int(id)
			callfunc_push_str(section)
			if (!callfunc_end()) return false
		}
	}
	return true
}

stock InvokeMenuCloseCallbacks(id, bool:isTimeout = false, const section[] = "") {
	for (new i = 0, size = ArraySize(g_MenuCloseCallbacks); i < size; i++) {
		new lc_data[LifecycleCallbackStruct]
		ArrayGetArray(g_MenuCloseCallbacks, i, lc_data)

		new func = ResolveFunc(g_MenuCloseCallbacks, i, _:LC_FUNC, lc_data[LC_CALLBACK], lc_data[LC_PLUGIN])
		if (func != -1 && callfunc_begin_i(func, lc_data[LC_PLUGIN]) == 1) {
			callfunc_push_int(id)
			callfunc_push_str(section)
			callfunc_push_int(isTimeout)
			callfunc_end()
		}
	}
}

public GlobalMenuTimerTask(menuIdx) {
	new duration = ArrayGetCell(g_MenuActiveTimers, menuIdx)
	if (duration <= 0) { remove_task(menuIdx); return 0; }
	duration--; ArraySetCell(g_MenuActiveTimers, menuIdx, duration)
	new menu_data[MenuDataStruct]; ArrayGetArray(g_Menus, menuIdx, menu_data)
	if (duration == 0) {
		remove_task(menuIdx); ExecuteMenuTimerExpired(menuIdx)
		for (new id = 1; id <= MaxClients; id++) {
			if (is_user_connected(id) && g_ActiveMenu[id] == menuIdx) {
				if (menu_data[MENU_ON_TIMEOUT][0]) {
					ExecuteAction(id, menu_data[MENU_ON_TIMEOUT], g_MenuTargetId[id])
				} else {
					mc_internal_close_menu(id, true)
				}
			}
		}
	} else mc_refresh_menu(menu_data[MENU_SECTION])

	return 0
}

public PlayerMenuTimerTask(idKey) {
	new id = idKey - TASK_PLAYER_TIMEOUT
	new menuIdx
	new menu_data[MenuDataStruct]

	if (!is_user_connected(id)) { remove_task(idKey); return 0; }

	if (g_PlayerMenuTimer[id] <= 0) {
		remove_task(idKey); return 0;
	}

	g_PlayerMenuTimer[id]--

	if (g_PlayerMenuTimer[id] == 0) {
		remove_task(idKey)
		menuIdx = g_ActiveMenu[id]
		if (menuIdx != -1) {
			ArrayGetArray(g_Menus, menuIdx, menu_data)
			if (menu_data[MENU_ON_TIMEOUT][0]) {
				ExecuteAction(id, menu_data[MENU_ON_TIMEOUT], g_MenuTargetId[id])
				// If action didn't result in a menu change or close, close it now
				if (is_user_connected(id) && g_ActiveMenu[id] == menuIdx) {
					mc_internal_close_menu(id, true)
				}
			} else {
				mc_internal_close_menu(id, true)
			}
		}
	} else {
		menuIdx = g_ActiveMenu[id]
		if (menuIdx != -1) {
			ArrayGetArray(g_Menus, menuIdx, menu_data)
			// Re-show menu to update timer in title
			mc_show_menu(id, menu_data[MENU_SECTION], .targetId = g_MenuTargetId[id], .ignoreHistory = true)
		}
	}
	return 0
}

stock ExecuteMenuTimerExpired(menuIdx) {
	new ret, menu_data[MenuDataStruct]; ArrayGetArray(g_Menus, menuIdx, menu_data)
	ExecuteForward(g_ForwardMenuTimerExpired, ret, menu_data[MENU_SECTION])
}
