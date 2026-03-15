-- patches.lua — Simple UI
-- Monkey-patches applied to KOReader on plugin load:
--   FileManager.setupLayout  — navbar injection, title bar, homescreen boot
--   FileChooser.init         — corrected content height
--   BookList.new             — corrected content height
--   Menu.new + FMColl        — collections with corrected height
--   SortWidget.new + PathChooser.new — fullscreen widget height + title padding
--   UIManager.show           — navbar injection for fullscreen widgets
--   UIManager.close          — tab restore + homescreen re-open
--   Menu.init                — pagination bar removal

local UIManager  = require("ui/uimanager")
local Screen     = require("device").screen
local logger     = require("logger")
local _          = require("gettext")

local Config    = require("config")
local UI        = require("ui")
local Bottombar = require("bottombar")

-- Cached zero-size Geom used to hide the right title bar button on injected widgets.
-- Allocated once at module load; never mutated.
local _Geom     = require("ui/geometry")
local _ZERO_DIMEN = _Geom:new{ w = 0, h = 0 }

local M = {}

-- Reused for UIManager.show calls that pass no extra args (avoids table allocation).
local _EMPTY = {}

-- Survives plugin re-instantiation (new instance per FM rebuild) because
-- patches.lua stays in package.loaded for the whole session.
-- Prevents the homescreen auto-open from firing on every FM rebuild after
-- closing the reader — only fires once, on the initial boot FM.
-- Cleared in teardownAll so a disable/re-enable starts fresh.
local _hs_boot_done = false

-- Linear search over tabs (typically 3–6 entries). Avoids allocating a hash
-- table on every UIManager.show injection path.
local function tabInTabs(id, tabs)
    for _, v in ipairs(tabs) do
        if v == id then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- FileManager.setupLayout
-- Injects the navbar, fixes the title bar, and wires up onShow / onPathChanged.
-- ---------------------------------------------------------------------------

function M.patchFileManagerClass(plugin)
    local FileManager      = require("apps/filemanager/filemanager")
    local orig_setupLayout = FileManager.setupLayout
    plugin._orig_fm_setup  = orig_setupLayout

    FileManager.setupLayout = function(fm_self)
        local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
        fm_self._navbar_height = Bottombar.TOTAL_H() + (topbar_on and require("topbar").TOTAL_TOP_H() or 0)

        -- FileChooser.init: reduce height to content area. Patched once on the
        -- class (guarded by _navbar_patched) so repeated FM rebuilds don't re-wrap.
        local FileChooser = require("ui/widget/filechooser")
        if not FileChooser._navbar_patched then
            local orig_fc_init   = FileChooser.init
            plugin._orig_fc_init = orig_fc_init
            FileChooser._navbar_patched = true
            FileChooser.init = function(fc_self)
                if fc_self.height == nil and fc_self.width == nil then
                    fc_self.height = UI.getContentHeight()
                    fc_self.y      = UI.getContentTop()
                end
                orig_fc_init(fc_self)
            end
        end

        orig_setupLayout(fm_self)

        -- Title bar: swap right button icon and intercept setRightIcon so the
        -- custom icon is preserved whenever KOReader resets it to "plus".
        local PLUS_ALT_ICON = Config.ICON.plus_alt
        local tb = fm_self.title_bar
        if tb and tb.right_button then
            local function setPlusAltIcon(btn)
                if btn.image then
                    btn.image.file = PLUS_ALT_ICON
                    btn.image:free(); btn.image:init()
                end
            end
            setPlusAltIcon(tb.right_button)
            local orig_setRightIcon = tb.setRightIcon
            tb.setRightIcon = function(tb_self, icon, ...)
                local result = orig_setRightIcon(tb_self, icon, ...)
                if icon == "plus" then
                    setPlusAltIcon(tb_self.right_button)
                    UIManager:setDirty(tb_self.show_parent, "ui", tb_self.dimen)
                end
                return result
            end
        end

        -- Title bar: reposition right button as the menu trigger; hide left button.
        if tb and tb.left_button and tb.right_button then
            local rb = tb.right_button
            if rb.image then
                rb.image.file = Config.ICON.ko_menu
                rb.image:free(); rb.image:init()
            end
            rb.overlap_align  = nil
            rb.overlap_offset = { Screen:scaleBySize(18), 0 }
            rb.padding_left   = 0
            rb:update()
            tb.left_button.overlap_align  = nil
            tb.left_button.overlap_offset = { Screen:getWidth() + 100, 0 }
            tb.left_button.callback       = function() end
            tb.left_button.hold_callback  = function() end
        end
        if tb and tb.setTitle then tb:setTitle(_("Library")) end

        -- Preserve the original inner widget reference so re-wrapping on
        -- subsequent setupLayout calls wraps the same widget, not the wrapper.
        local inner_widget
        if fm_self._navbar_inner then
            inner_widget = fm_self._navbar_inner
        else
            inner_widget          = fm_self[1]
            fm_self._navbar_inner = inner_widget
        end

        local tabs = Config.loadTabConfig()

        local navbar_container, wrapped, bar, topbar, bar_idx, topbar_on2, topbar_idx =
            UI.wrapWithNavbar(inner_widget, plugin.active_action, tabs)
        UI.applyNavbarState(fm_self, navbar_container, bar, topbar, bar_idx, topbar_on2, topbar_idx, tabs)
        fm_self[1] = wrapped

        plugin:_updateFMHomeIcon()

        -- Boot-time homescreen auto-open: only fires on the first FM instance
        -- (boot). Subsequent FMs (after closing the reader) skip this block
        -- because _hs_boot_done is a module-level local that persists across
        -- plugin re-instantiation.
        if not _hs_boot_done then
            _hs_boot_done = true
            if G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
                    and tabInTabs("homescreen", tabs) then
                plugin.active_action = "homescreen"
                fm_self._hs_autoopen_pending = true
            end
        end

        -- onShow fires once the FM is on the UIManager stack.
        -- Handles both the boot homescreen open and the normal bar refresh.
        local orig_onShow = fm_self.onShow
        fm_self.onShow = function(this)
            if orig_onShow then orig_onShow(this) end
            Bottombar.resizePaginationButtons(this.file_chooser or this, Bottombar.getPaginationIconSize())

            -- Homescreen must be opened after the FM is on the stack;
            -- _hs_autoopen_pending is the deferred signal from setupLayout above.
            if this._hs_autoopen_pending then
                this._hs_autoopen_pending = nil
                UIManager:scheduleIn(0, function()
                    local HS = package.loaded["homescreen"] or (function()
                        local ok, m = pcall(require, "homescreen"); return ok and m
                    end)()
                    if HS then
                        if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
                        HS.show(function(aid) plugin:_onTabTap(aid, this) end, plugin._goalTapCallback)
                    end
                end)
                return
            end

            -- Normal FM show: reset active tab to "home" and refresh the bar.
            if this._navbar_container then
                local t = Config.loadTabConfig()
                plugin.active_action = "home"
                Bottombar.replaceBar(this, Bottombar.buildBarWidget("home", t), t)
                UIManager:setDirty(this, "ui")
            end
        end

        plugin:_registerTouchZones(fm_self)

        -- onPathChanged: update the active tab when the user navigates directories.
        fm_self.onPathChanged = function(this, new_path)
            local t          = Config.loadTabConfig()
            local new_active = M._resolveTabForPath(new_path, t)
            plugin.active_action = new_active
            if this._navbar_container then
                Bottombar.replaceBar(this, Bottombar.buildBarWidget(new_active, t), t)
                UIManager:setDirty(this, "ui")
            end
            plugin:_updateFMHomeIcon()
        end
    end
end

-- Returns the tab id whose configured path matches the given filesystem path,
-- or nil if no tab matches. Strips trailing slashes before comparing.
function M._resolveTabForPath(path, tabs)
    if not path then return nil end
    path = path:gsub("/$", "")
    local home_dir = G_reader_settings:readSetting("home_dir")
    if home_dir then home_dir = home_dir:gsub("/$", "") end
    for _i, tab_id in ipairs(tabs) do
        if tab_id == "home" then
            if home_dir and path == home_dir then return "home" end
        elseif tab_id:match("^custom_qa_%d+$") then
            local cfg = Config.getCustomQAConfig(tab_id)
            if cfg.path then
                local cfg_path = cfg.path:gsub("/$", "")
                if path == cfg_path then return tab_id end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- FileManagerMenu.getStartWithMenuTable
-- Injects "Home Screen" into KOReader's Start With submenu.
-- Guarded: only patches once per session (flag on the class itself).
-- ---------------------------------------------------------------------------

function M.patchStartWithMenu()
    local FileManagerMenu = package.loaded["apps/filemanager/filemanagermenu"]
        or (function()
            local ok, m = pcall(require, "apps/filemanager/filemanagermenu")
            return ok and m
        end)()
    if not FileManagerMenu then return end
    if FileManagerMenu._simpleui_startwith_patched then return end
    local orig_fn = FileManagerMenu.getStartWithMenuTable
    if not orig_fn then return end
    FileManagerMenu._simpleui_startwith_patched = true
    FileManagerMenu._simpleui_startwith_orig    = orig_fn
    FileManagerMenu.getStartWithMenuTable = function(fmm_self)
        local result = orig_fn(fmm_self)
        local sub = result.sub_item_table
        if type(sub) ~= "table" then return result end
        -- Guard against the entry already being present (re-entrancy safety).
        local has_homescreen = false
        for _i, item in ipairs(sub) do
            if item.text == _("Home Screen") and item.radio then has_homescreen = true end
        end
        if not has_homescreen then
            table.insert(sub, math.max(1, #sub), {
                text         = _("Home Screen"),
                checked_func = function()
                    return G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
                end,
                callback = function()
                    G_reader_settings:saveSetting("start_with", "homescreen_simpleui")
                end,
                radio = true,
            })
        end
        -- Update the parent item's display text to reflect "Home Screen" when selected.
        local orig_text_func = result.text_func
        result.text_func = function()
            if G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui" then
                return _("Start with") .. ": " .. _("Home Screen")
            end
            return orig_text_func and orig_text_func() or _("Start with")
        end
        return result
    end
end

-- ---------------------------------------------------------------------------
-- BookList.new
-- Reduces BookList height to the content area (excludes navbar + topbar).
-- ---------------------------------------------------------------------------

function M.patchBookList(plugin)
    local BookList    = require("ui/widget/booklist")
    local orig_bl_new = BookList.new
    plugin._orig_booklist_new = orig_bl_new
    BookList.new = function(class, attrs, ...)
        attrs = attrs or {}
        if not attrs.height and not attrs._navbar_height_reduced then
            attrs.height                 = UI.getContentHeight()
            attrs.y                      = UI.getContentTop()
            attrs._navbar_height_reduced = true
        end
        return orig_bl_new(class, attrs, ...)
    end
end

-- ---------------------------------------------------------------------------
-- FMColl.onShowCollList + Menu.new + ReadCollection
-- Reduces the coll_list Menu height. patch_depth gates Menu.new so only
-- menus created during onShowCollList are affected.
-- Also syncs the SimpleUI collections pool when KOReader renames/deletes.
-- ---------------------------------------------------------------------------

function M.patchCollections(plugin)
    local ok, FMColl = pcall(require, "apps/filemanager/filemanagercollection")
    if not (ok and FMColl) then return end
    local Menu          = require("ui/widget/menu")
    local orig_menu_new = Menu.new
    plugin._orig_menu_new    = orig_menu_new
    plugin._orig_fmcoll_show = FMColl.onShowCollList
    local patch_depth = 0

    local orig_onShowCollList = FMColl.onShowCollList
    FMColl.onShowCollList = function(fmc_self, ...)
        patch_depth = patch_depth + 1
        local ok2, result = pcall(orig_onShowCollList, fmc_self, ...)
        patch_depth = patch_depth - 1
        if not ok2 then error(result) end
        return result
    end

    Menu.new = function(class, attrs, ...)
        attrs = attrs or {}
        if patch_depth > 0
                and attrs.covers_fullscreen and attrs.is_borderless
                and attrs.is_popout == false
                and not attrs.height and not attrs._navbar_height_reduced then
            attrs.height                 = UI.getContentHeight()
            attrs.y                      = UI.getContentTop()
            attrs._navbar_height_reduced = true
            attrs.name                   = attrs.name or "coll_list"
        end
        return orig_menu_new(class, attrs, ...)
    end

    local ok_rc, RC = pcall(require, "readcollection")
    if not (ok_rc and RC) then return end

    -- Removes a collection from the SimpleUI selected list and cover-override table.
    local function _removeFromPool(name)
        local CW = package.loaded["collectionswidget"]
        if not CW then return end
        local selected = CW.getSelected()
        local changed  = false
        for i = #selected, 1, -1 do
            if selected[i] == name then
                table.remove(selected, i)
                changed = true
            end
        end
        if changed then CW.saveSelected(selected) end
        local overrides = CW.getCoverOverrides()
        if overrides[name] then
            overrides[name] = nil
            CW.saveCoverOverrides(overrides)
        end
    end

    -- Renames a collection in the SimpleUI selected list and cover-override table.
    local function _renameInPool(old_name, new_name)
        local CW = package.loaded["collectionswidget"]
        if not CW then return end
        local selected = CW.getSelected()
        local changed  = false
        for i, name in ipairs(selected) do
            if name == old_name then
                selected[i] = new_name
                changed = true
            end
        end
        if changed then CW.saveSelected(selected) end
        local overrides = CW.getCoverOverrides()
        if overrides[old_name] then
            overrides[new_name] = overrides[old_name]
            overrides[old_name] = nil
            CW.saveCoverOverrides(overrides)
        end
    end

    if type(RC.removeCollection) == "function" then
        local orig_remove = RC.removeCollection
        plugin._orig_rc_remove = orig_remove
        RC.removeCollection = function(rc_self, coll_name, ...)
            local result = orig_remove(rc_self, coll_name, ...)
            pcall(function()
                _removeFromPool(coll_name)
                Config.purgeQACollection(coll_name)
                Config.invalidateTabsCache()
                plugin:_scheduleRebuild()
            end)
            return result
        end
    end

    if type(RC.renameCollection) == "function" then
        local orig_rename = RC.renameCollection
        plugin._orig_rc_rename = orig_rename
        RC.renameCollection = function(rc_self, old_name, new_name, ...)
            local result = orig_rename(rc_self, old_name, new_name, ...)
            pcall(function()
                _renameInPool(old_name, new_name)
                Config.renameQACollection(old_name, new_name)
                plugin:_scheduleRebuild()
            end)
            return result
        end
    end
end

-- ---------------------------------------------------------------------------
-- SortWidget.new + PathChooser.new
-- Reduces height to content area. SortWidget also gets title padding and a
-- _populateItems hook to force a repaint after each sort operation.
-- ---------------------------------------------------------------------------

function M.patchFullscreenWidgets(plugin)
    local ok_sw, SortWidget  = pcall(require, "ui/widget/sortwidget")
    local ok_pc, PathChooser = pcall(require, "ui/widget/pathchooser")

    if ok_sw and SortWidget then
        local ok_tb, TitleBar = pcall(require, "ui/widget/titlebar")
        local orig_sw_new     = SortWidget.new
        plugin._orig_sortwidget_new = orig_sw_new
        SortWidget.new = function(class, attrs, ...)
            attrs = attrs or {}
            if attrs.covers_fullscreen and not attrs._navbar_height_reduced then
                attrs.height                 = UI.getContentHeight()
                attrs.y                      = UI.getContentTop()
                attrs._navbar_height_reduced = true
            end
            -- Temporarily override TitleBar.new to inject horizontal padding,
            -- then restore it immediately after SortWidget is constructed.
            local orig_tb_new
            if ok_tb and TitleBar and attrs.covers_fullscreen then
                orig_tb_new = TitleBar.new
                TitleBar.new = function(tb_class, tb_attrs, ...)
                    tb_attrs = tb_attrs or {}
                    tb_attrs.title_h_padding = Screen:scaleBySize(24)
                    return orig_tb_new(tb_class, tb_attrs, ...)
                end
            end
            local ok_sw2, sw_or_err = pcall(orig_sw_new, class, attrs, ...)
            if orig_tb_new then TitleBar.new = orig_tb_new end
            if not ok_sw2 then error(sw_or_err, 2) end
            local sw = sw_or_err
            if not attrs.covers_fullscreen then return sw end
            -- Zero the footer height to remove the pagination bar space.
            local vfooter = sw[1] and sw[1][1] and sw[1][1][2] and sw[1][1][2][1]
            if vfooter and vfooter[3] and vfooter[3].dimen then
                vfooter[3].dimen.h = 0
            end
            -- Force a full repaint after each sort list update.
            local orig_populate = sw._populateItems
            if type(orig_populate) == "function" then
                sw._populateItems = function(self_sw, ...)
                    local result = orig_populate(self_sw, ...)
                    UIManager:setDirty(nil, "ui")
                    return result
                end
            end
            return sw
        end
    end

    if ok_pc and PathChooser then
        local orig_pc_new = PathChooser.new
        plugin._orig_pathchooser_new = orig_pc_new
        PathChooser.new = function(class, attrs, ...)
            attrs = attrs or {}
            if attrs.covers_fullscreen and not attrs._navbar_height_reduced then
                attrs.height                 = UI.getContentHeight()
                attrs.y                      = UI.getContentTop()
                attrs._navbar_height_reduced = true
            end
            return orig_pc_new(class, attrs, ...)
        end
    end
end

-- ---------------------------------------------------------------------------
-- UIManager.show
-- Injects the navbar into qualifying fullscreen widgets. Also closes the
-- homescreen when any other fullscreen widget is shown on top of it.
-- _show_depth prevents re-entrant injection when orig_show itself calls show.
-- ---------------------------------------------------------------------------

function M.patchUIManagerShow(plugin)
    local orig_show  = UIManager.show
    plugin._orig_uimanager_show = orig_show
    local _show_depth = 0

    local INJECT_NAMES = { collections = true, history = true, coll_list = true, homescreen = true }

    UIManager.show = function(um_self, widget, ...)
        -- Capture varargs before the pcall closure (Lua does not propagate '...' into nested functions).
        -- Reuse _EMPTY when there are no extra args to avoid a table allocation on every call.
        local n_extra    = select("#", ...)
        local extra_args = n_extra > 0 and { ... } or _EMPTY
        _show_depth = _show_depth + 1

        -- Wrap body in pcall so _show_depth is always decremented even on error.
        local ok, result = pcall(function()

        -- Injection criteria: top-level show, fullscreen, not already injected,
        -- has a title bar (excludes ReaderUI), and is either pre-sized or in INJECT_NAMES.
        local should_inject = _show_depth == 1
            and widget
            and not widget._navbar_injected
            and not widget._navbar_skip_inject
            and widget ~= plugin.ui
            and widget.covers_fullscreen
            and widget.title_bar ~= nil
            and (widget._navbar_height_reduced or (widget.name and INJECT_NAMES[widget.name]))

        if not should_inject then
            if n_extra > 0 then
                return orig_show(um_self, widget, table.unpack(extra_args))
            else
                return orig_show(um_self, widget)
            end
        end

        widget._navbar_injected = true

        -- Resize widget and its first child to the content area when not already sized.
        if not widget._navbar_height_reduced then
            local content_h   = UI.getContentHeight()
            local content_top = UI.getContentTop()
            if widget.dimen then
                widget.dimen.h = content_h
                widget.dimen.y = content_top
            end
            if widget[1] and widget[1].dimen then
                widget[1].dimen.h = content_h
                widget[1].dimen.y = content_top
            end
            widget._navbar_height_reduced = true
        end

        -- Reposition left button inside content area; hide right button.
        local tb = widget.title_bar
        if tb then
            if tb.left_button then
                tb.left_button.overlap_align  = nil
                tb.left_button.overlap_offset = { Screen:scaleBySize(13), 0 }
            end
            local rb = tb.right_button
            if rb then
                rb.dimen         = _ZERO_DIMEN
                rb.callback      = function() end
                rb.hold_callback = function() end
            end
        end

        local tabs          = Config.loadTabConfig()
        local action_before = plugin.active_action
        local effective_action = nil

        -- Set the active tab to match the widget being shown.
        if widget.name == "collections" and Config.isFavoritesWidget(widget) and tabInTabs("favorites", tabs) then
            effective_action = Bottombar.setActiveAndRefreshFM(plugin, "favorites", tabs)
            local orig_onReturn = widget.onReturn
            if orig_onReturn then
                widget.onReturn = function(w_self, ...)
                    plugin:_restoreTabInFM(w_self._navbar_tabs, action_before)
                    return orig_onReturn(w_self, ...)
                end
            end
        elseif widget.name == "history" and tabInTabs("history", tabs) then
            effective_action = Bottombar.setActiveAndRefreshFM(plugin, "history", tabs)
        elseif widget.name == "homescreen" and tabInTabs("homescreen", tabs) then
            effective_action = Bottombar.setActiveAndRefreshFM(plugin, "homescreen", tabs)
        elseif widget.name == "coll_list"
               or (widget.name == "collections" and not Config.isFavoritesWidget(widget)) then
            if tabInTabs("collections", tabs) then
                effective_action = Bottombar.setActiveAndRefreshFM(plugin, "collections", tabs)
            end
        end

        local display_action = effective_action or action_before
        if not widget._navbar_inner then widget._navbar_inner = widget[1] end

        local navbar_container, wrapped, bar, topbar, bar_idx, topbar_on, topbar_idx =
            UI.wrapWithNavbar(widget._navbar_inner, display_action, tabs)
        UI.applyNavbarState(widget, navbar_container, bar, topbar, bar_idx, topbar_on, topbar_idx, tabs)
        widget._navbar_prev_action = action_before
        widget[1]                  = wrapped
        plugin:_registerTouchZones(widget)

        -- Register top-of-screen tap/swipe zones to open the KOReader main menu,
        -- mirroring FileManagerMenu:initGesListener for all injected pages.
        if widget.registerTouchZones then
            local DTAP_ZONE_MENU     = G_defaults:readSetting("DTAP_ZONE_MENU")
            local DTAP_ZONE_MENU_EXT = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
            if DTAP_ZONE_MENU and DTAP_ZONE_MENU_EXT then
                local fm = plugin.ui
                widget:registerTouchZones({
                    {
                        id          = "simpleui_menu_tap",
                        ges         = "tap",
                        screen_zone = {
                            ratio_x = DTAP_ZONE_MENU.x, ratio_y = DTAP_ZONE_MENU.y,
                            ratio_w = DTAP_ZONE_MENU.w, ratio_h = DTAP_ZONE_MENU.h,
                        },
                        handler = function(ges)
                            if fm and fm.menu then return fm.menu:onTapShowMenu(ges) end
                        end,
                    },
                    {
                        id          = "simpleui_menu_ext_tap",
                        ges         = "tap",
                        screen_zone = {
                            ratio_x = DTAP_ZONE_MENU_EXT.x, ratio_y = DTAP_ZONE_MENU_EXT.y,
                            ratio_w = DTAP_ZONE_MENU_EXT.w, ratio_h = DTAP_ZONE_MENU_EXT.h,
                        },
                        overrides = { "simpleui_menu_tap" },
                        handler = function(ges)
                            if fm and fm.menu then return fm.menu:onTapShowMenu(ges) end
                        end,
                    },
                    {
                        id          = "simpleui_menu_swipe",
                        ges         = "swipe",
                        screen_zone = {
                            ratio_x = DTAP_ZONE_MENU.x, ratio_y = DTAP_ZONE_MENU.y,
                            ratio_w = DTAP_ZONE_MENU.w, ratio_h = DTAP_ZONE_MENU.h,
                        },
                        handler = function(ges)
                            if fm and fm.menu then return fm.menu:onSwipeShowMenu(ges) end
                        end,
                    },
                    {
                        id          = "simpleui_menu_ext_swipe",
                        ges         = "swipe",
                        screen_zone = {
                            ratio_x = DTAP_ZONE_MENU_EXT.x, ratio_y = DTAP_ZONE_MENU_EXT.y,
                            ratio_w = DTAP_ZONE_MENU_EXT.w, ratio_h = DTAP_ZONE_MENU_EXT.h,
                        },
                        overrides = { "simpleui_menu_swipe" },
                        handler = function(ges)
                            if fm and fm.menu then return fm.menu:onSwipeShowMenu(ges) end
                        end,
                    },
                })
            end
        end

        -- Resize the return button to match the side margin.
        local rb = widget.return_button
        if rb and rb[1] then rb[1].width = UI.SIDE_M() end

        Bottombar.resizePaginationButtons(widget, Bottombar.getPaginationIconSize())

        if n_extra > 0 then
            orig_show(um_self, widget, table.unpack(extra_args))
        else
            orig_show(um_self, widget)
        end
        UIManager:setDirty(widget[1], "ui")

        end) -- end pcall
        _show_depth = _show_depth - 1
        if not ok then
            logger.warn("simpleui: UIManager.show patch error:", tostring(result))
        end

        -- Close the homescreen if another fullscreen widget just appeared on top.
        -- Runs regardless of whether injection happened (covers ReaderUI too).
        if _show_depth == 0 and widget and widget.covers_fullscreen
                and widget.name ~= "homescreen" then
            local stack = UI.getWindowStack()
            for _i, entry in ipairs(stack) do
                local w = entry.widget
                if w and w.name == "homescreen" then
                    UIManager:close(w)
                    break
                end
            end
        end
        return result
    end
end

-- ---------------------------------------------------------------------------
-- UIManager.close
-- On close of a SimpleUI-injected widget: restores the active tab and,
-- when "Start with Homescreen" is set, re-opens the homescreen.
-- Non-fullscreen widgets are passed straight through (fast path).
-- ReaderUI and other native KOReader widgets are never injected, so they
-- bypass both the tab-restore and homescreen re-open logic automatically.
-- ---------------------------------------------------------------------------

function M.patchUIManagerClose(plugin)
    local orig_close = UIManager.close
    plugin._orig_uimanager_close = orig_close

    -- Defined once at patch-install time, not on every close() call.
    -- Closes orphaned non-fullscreen widgets, then shows the homescreen.
    local function _doShowHS(fm, plugin_ref)
        local HS = package.loaded["homescreen"]
        if not HS or HS._instance then return end
        local stack = UI.getWindowStack()
        local to_close = {}
        for _i, entry in ipairs(stack) do
            local w = entry.widget
            if w and w ~= fm and not w.covers_fullscreen then
                to_close[#to_close + 1] = w
            end
        end
        for _, w in ipairs(to_close) do UIManager:close(w) end
        local tabs = Config.loadTabConfig()
        Bottombar.setActiveAndRefreshFM(plugin_ref, "homescreen", tabs)
        if not plugin_ref._goalTapCallback then plugin_ref:addToMainMenu({}) end
        HS.show(
            function(aid) plugin_ref:_onTabTap(aid, fm) end,
            plugin_ref._goalTapCallback
        )
    end

    UIManager.close = function(um_self, widget, ...)
        -- Fast path: non-fullscreen widgets (dialogs, menus, InfoMessage, etc.)
        -- skip all SimpleUI logic — they are the vast majority of close() calls.
        if not (widget and widget.covers_fullscreen) then
            return orig_close(um_self, widget, ...)
        end

        -- Tab restore: only for SimpleUI-injected widgets not being closed
        -- intentionally (e.g. by the user tapping a different tab).
        if widget._navbar_injected and not widget._navbar_closing_intentionally then
            -- coll_list sits on top of the collections widget; restoreTabInFM
            -- would skip it because another injected widget is still on the stack.
            -- Find the prev_action saved on the underlying collections widget instead.
            if widget.name == "coll_list" then
                local FM2 = package.loaded["apps/filemanager/filemanager"]
                local fm = FM2 and FM2.instance
                if fm and fm._navbar_container then
                    local t = Config.loadTabConfig()
                    local restored = nil
                    for _i, entry in ipairs(UI.getWindowStack()) do
                        local w = entry.widget
                        if w and w ~= widget and w._navbar_injected
                                and (w.name == "collections" or w.name == "coll_list") then
                            restored = w._navbar_prev_action
                            break
                        end
                    end
                    if not restored then
                        restored = (fm.file_chooser
                                    and M._resolveTabForPath(fm.file_chooser.path, t))
                                or t[1] or "home"
                    end
                    plugin.active_action = restored
                    Bottombar.replaceBar(fm, Bottombar.buildBarWidget(restored, t), t)
                    UIManager:setDirty(fm, "ui")
                end
            else
                plugin:_restoreTabInFM(widget._navbar_tabs, widget._navbar_prev_action)
            end
        end

        local result = orig_close(um_self, widget, ...)

        -- Re-open homescreen after a SimpleUI-injected widget closes, when
        -- "Start with Homescreen" is configured. Non-injected widgets (ReaderUI,
        -- native KOReader pages) never have _navbar_injected so they skip this.
        -- The homescreen itself is excluded: patchUIManagerShow closes it when
        -- another fullscreen widget appears; that close must not re-open it.
        if G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
                and widget._navbar_injected
                and widget.name ~= "homescreen"
                and not widget._navbar_closing_intentionally then
            local FM2 = package.loaded["apps/filemanager/filemanager"]
            local fm  = FM2 and FM2.instance
            local other_open = false
            local has_modal  = false
            -- Single stack pass: detect a blocking fullscreen widget or a lingering modal.
            for _i, entry in ipairs(UI.getWindowStack()) do
                local w = entry.widget
                if w and w ~= fm and w ~= widget then
                    if w.covers_fullscreen then
                        other_open = true; break
                    else
                        has_modal = true
                    end
                end
            end
            if not other_open and fm then
                if has_modal then
                    -- Defer to let KOReader finish closing any modal widgets first.
                    UIManager:scheduleIn(0, function() _doShowHS(fm, plugin) end)
                else
                    _doShowHS(fm, plugin)
                end
            end
        end

        return result
    end
end

-- ---------------------------------------------------------------------------
-- Menu.init
-- Removes the pagination bar from fullscreen FM-style menus when the
-- "navbar_pagination_visible" setting is off.
-- ---------------------------------------------------------------------------

function M.patchMenuInitForPagination(plugin)
    local Menu = require("ui/widget/menu")
    local TARGET_NAMES = {
        filemanager = true, history = true, collections = true, coll_list = true,
    }
    local orig_menu_init = Menu.init
    plugin._orig_menu_init = orig_menu_init

    Menu.init = function(menu_self, ...)
        orig_menu_init(menu_self, ...)
        if G_reader_settings:nilOrTrue("navbar_pagination_visible") then return end
        if not TARGET_NAMES[menu_self.name]
           and not (menu_self.covers_fullscreen
                    and menu_self.is_borderless
                    and menu_self.title_bar_fm_style) then
            return
        end
        -- Remove all children except content_group to eliminate the pagination row.
        local content = menu_self[1] and menu_self[1][1]
        if content then
            for i = #content, 1, -1 do
                if content[i] ~= menu_self.content_group then
                    table.remove(content, i)
                end
            end
        end
        -- Override _recalculateDimen to suppress pagination widget updates.
        menu_self._recalculateDimen = function(self_inner, no_recalculate_dimen)
            local saved_arrow = self_inner.page_return_arrow
            local saved_text  = self_inner.page_info_text
            local saved_info  = self_inner.page_info
            self_inner.page_return_arrow = nil
            self_inner.page_info_text    = nil
            self_inner.page_info         = nil
            local instance_fn = self_inner._recalculateDimen
            self_inner._recalculateDimen = nil
            local ok, err = pcall(function()
                self_inner:_recalculateDimen(no_recalculate_dimen)
            end)
            self_inner._recalculateDimen = instance_fn
            self_inner.page_return_arrow = saved_arrow
            self_inner.page_info_text    = saved_text
            self_inner.page_info         = saved_info
            if not ok then error(err, 2) end
        end
        menu_self:_recalculateDimen()
    end
end

-- ---------------------------------------------------------------------------
-- installAll / teardownAll
-- ---------------------------------------------------------------------------

function M.installAll(plugin)
    M.patchFileManagerClass(plugin)
    M.patchStartWithMenu()
    M.patchBookList(plugin)
    M.patchCollections(plugin)
    M.patchFullscreenWidgets(plugin)
    M.patchUIManagerShow(plugin)
    M.patchUIManagerClose(plugin)
    M.patchMenuInitForPagination(plugin)
end

function M.teardownAll(plugin)
    -- Restore UIManager patches first (highest call frequency).
    if plugin._orig_uimanager_show then
        UIManager.show  = plugin._orig_uimanager_show
        plugin._orig_uimanager_show = nil
    end
    if plugin._orig_uimanager_close then
        UIManager.close = plugin._orig_uimanager_close
        plugin._orig_uimanager_close = nil
    end
    -- Restore class patches via package.loaded (all modules already loaded; no pcall needed).
    local BookList = package.loaded["ui/widget/booklist"]
    if BookList and plugin._orig_booklist_new then
        BookList.new = plugin._orig_booklist_new; plugin._orig_booklist_new = nil
    end
    local Menu = package.loaded["ui/widget/menu"]
    if Menu then
        if plugin._orig_menu_new  then Menu.new  = plugin._orig_menu_new;  plugin._orig_menu_new  = nil end
        if plugin._orig_menu_init then Menu.init = plugin._orig_menu_init; plugin._orig_menu_init = nil end
    end
    local FMColl = package.loaded["apps/filemanager/filemanagercollection"]
    if FMColl and plugin._orig_fmcoll_show then
        FMColl.onShowCollList = plugin._orig_fmcoll_show; plugin._orig_fmcoll_show = nil
    end
    local RC = package.loaded["readcollection"]
    if RC then
        if plugin._orig_rc_remove then RC.removeCollection = plugin._orig_rc_remove; plugin._orig_rc_remove = nil end
        if plugin._orig_rc_rename then RC.renameCollection = plugin._orig_rc_rename; plugin._orig_rc_rename = nil end
    end
    local SortWidget = package.loaded["ui/widget/sortwidget"]
    if SortWidget and plugin._orig_sortwidget_new then
        SortWidget.new = plugin._orig_sortwidget_new; plugin._orig_sortwidget_new = nil
    end
    local PathChooser = package.loaded["ui/widget/pathchooser"]
    if PathChooser and plugin._orig_pathchooser_new then
        PathChooser.new = plugin._orig_pathchooser_new; plugin._orig_pathchooser_new = nil
    end
    local FileChooser = package.loaded["ui/widget/filechooser"]
    if FileChooser and plugin._orig_fc_init then
        FileChooser.init            = plugin._orig_fc_init
        FileChooser._navbar_patched = nil
        plugin._orig_fc_init        = nil
    end
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    if FileManager and plugin._orig_fm_setup then
        FileManager.setupLayout = plugin._orig_fm_setup; plugin._orig_fm_setup = nil
    end
    local FileManagerMenu = package.loaded["apps/filemanager/filemanagermenu"]
    if FileManagerMenu and FileManagerMenu._simpleui_startwith_patched then
        FileManagerMenu.getStartWithMenuTable       = FileManagerMenu._simpleui_startwith_orig
        FileManagerMenu._simpleui_startwith_orig    = nil
        FileManagerMenu._simpleui_startwith_patched = nil
    end
    -- Reset module-level state so a re-enable starts clean.
    _hs_boot_done = false
    Config.reset()
    local Registry = package.loaded["desktop_modules/moduleregistry"]
    if Registry then Registry.invalidate() end
end

return M
