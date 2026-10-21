--[[--
Rosario plugin: adds a "Rosario" entry at the top of the Tools menu and its own
top-level menu tab, right after Tools, that opens a full-screen, pixel-art guide
to the Holy Rosary. The entry is named in the plugin's language (see i18n.lua).

@module koplugin.Rosario
]]

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

-- Sibling modules are loaded by path instead of `require` so their generic
-- names cannot collide with modules of other plugins in package.loaded.
local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local RosaryWidget = dofile(plugin_dir .. "/rosarywidget.lua")

-- Menu orders of the File Manager and the Reader. KOReader caches them with
-- `require` and reads them when a menu is first built, after plugins init.
local MENU_ORDERS = { "ui/elements/filemanager_menu_order", "ui/elements/reader_menu_order" }

-- Built-in mdlight icon for the tab when the plugin folder cannot be reached
-- from IconWidget's icon folders (an absolute or unknown plugin path).
local FALLBACK_ICON = "star.full"

local function indexOf(list, value)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
end

-- The cached order tables outlive File Manager and Reader instances while
-- `init` runs once per instance, so every change here must be idempotent.
local function addToMenuOrder(module_name)
    local ok, order = pcall(require, module_name)
    if not ok or type(order) ~= "table" then return end
    -- A tab needs an order entry, even an empty one, to be shown.
    order.rosario_tab = order.rosario_tab or {}
    local buttons = order["KOMenu:menu_buttons"]
    if type(buttons) == "table" and not indexOf(buttons, "rosario_tab") then
        local tools = indexOf(buttons, "tools")
        table.insert(buttons, tools and tools + 1 or #buttons + 1, "rosario_tab")
    end
    if type(order.tools) == "table" and not indexOf(order.tools, "rosario") then
        table.insert(order.tools, 1, "rosario")
    end
end

local Rosario = WidgetContainer:extend{
    name = "rosario",
    is_doc_only = false,
}

function Rosario:init()
    for _, module_name in ipairs(MENU_ORDERS) do
        addToMenuOrder(module_name)
    end
    self.ui.menu:registerToMainMenu(self)
end

function Rosario:addToMainMenu(menu_items)
    menu_items.rosario = {
        -- Read when the menu is shown, so a language change shows at once.
        -- Without loadable strings (missing or broken l10n files) the entry
        -- keeps its Spanish name instead of breaking the whole menu.
        text_func = function()
            local strings = RosaryWidget.catalog(RosaryWidget.language(G_reader_settings)).strings
            return strings and strings.name or "Rosario"
        end,
        -- Only used when the Tools order has no "rosario" entry.
        sorting_hint = "tools",
        callback = function()
            self:showRosary()
        end,
    }
    -- A tab that acts as a button, like the Reader's File browser tab.
    menu_items.rosario_tab = {
        icon = self:tabIcon(),
        remember = false,
        callback = function()
            self:closeMenu()
            self:showRosary()
        end,
    }
end

-- IconWidget looks icons up by name under folders such as
-- "resources/icons/mdlight", relative to the KOReader folder, so a relative
-- plugin path is reached by climbing out of that folder.
function Rosario:tabIcon()
    local path = self.path
    if type(path) == "string" and path ~= "" and path:sub(1, 1) ~= "/" then
        return "../../../" .. path .. "/rosario"
    end
    return FALLBACK_ICON
end

-- The File Manager and the Reader menus close through different methods.
function Rosario:closeMenu()
    local menu = self.ui.menu
    if menu.onCloseFileManagerMenu then
        menu:onCloseFileManagerMenu()
    elseif menu.onTapCloseMenu then
        menu:onTapCloseMenu()
    end
end

function Rosario:showRosary()
    UIManager:show(RosaryWidget:new{}, "full")
end

return Rosario
