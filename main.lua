local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. _dir .. "common/?.lua;" .. package.path

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

-- The game screen, the board and its puzzle generator / solver load the
-- first time the game is opened (or Dashboard asks about the daily
-- challenge), not when KOReader starts:
-- KOReader loads every plugin at startup and keeps it all session, so a
-- top-level require here costs memory even if the game is never played.
-- KOReader has put package.path back by then, so our directories are added
-- again while the module loads (common/ stays as a fallback for the shared
-- modules the game requires later on).
local function lazyrequire(name)
    local saved = package.path
    package.path = _dir .. "?.lua;" .. _dir .. "common/?.lua;" .. saved
    local ok, mod = pcall(lrequire, name)
    package.path = saved
    if not package.path:find(_dir .. "common/?.lua", 1, true) then
        package.path = package.path .. ";" .. _dir .. "common/?.lua"
    end
    if not ok then error(mod, 0) end
    return mod
end

-- sudoku-common's puzzle generation with a progress bar (base_screen.lua).
local function generateWithProgress(...)
    return lazyrequire("common/base_screen").generateWithProgress(...)
end

local DataStorage     = require("datastorage")
local LuaSettings     = require("luasettings")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _               = require("i18n")

-- Play-session stats, shared with every other game through
-- game_stats.lua (Dashboard reads it). pcall'd: an install whose
-- common/ predates sudoku-common 1.4.0 has no stats_exporter.lua,
-- and a bare require would take the whole plugin down with it.
local ok_stats, StatsExporter = pcall(require, "stats_exporter")

require("i18n").extend(lrequire("i18n_fr"))

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

-- `name` must match the directory basename: since KOReader 2026.03 (PR
-- #15096) PluginLoader overwrites it with the directory name regardless of
-- what is declared here.
-- Spelled out rather than read off self.name: ReaderUI/FileManager
-- rewrite an instance's name to "reader<id>"/"filemanager<id>" right
-- after it is built, so self.name is not the plugin id after :init().
local PLUGIN_ID = "sudokukiller"

local KillerSudoku = WidgetContainer:extend{
    name        = "sudokukiller",
    is_doc_only = false,
}

function KillerSudoku:ensureSettings(path_only)
    if not self.settings_file then
        local dir = DataStorage:getSettingsDir()
        self.settings_file = dir .. "/sudokukiller.lua"
        -- The settings file used to be named after the old "killer_sudoku"
        -- plugin id. Carry a player's saved grid over rather than silently
        -- starting them on an empty board.
        local legacy = dir .. "/killer_sudoku.lua"
        if not file_exists(self.settings_file) and file_exists(legacy) then
            os.rename(legacy, self.settings_file)
            os.remove(legacy .. ".old")
        end
    end
    if not self.settings and not path_only then
        self.settings = LuaSettings:open(self.settings_file)
    end
end

function KillerSudoku:init()
    -- Only the settings file's path is needed now (KOReader reads
    -- settings_file to offer "Delete plugin settings"): the file itself,
    -- saved grid included, is read when the game is first opened.
    self:ensureSettings(true)
    self.ui.menu:registerToMainMenu(self)
end

-- Listed under Tools → Games with the rest of the fleet. games_menu comes
-- from game-common, which this plugin does not ship: any other game's
-- common/ provides it. Installed on its own, the game keeps its own entry.
function KillerSudoku:addToMainMenu(menu_items)
    local ok, GamesMenu = pcall(require, "games_menu")
    if ok and type(GamesMenu) == "table" and GamesMenu.add then
        GamesMenu.add(menu_items, {
            id     = "sudokukiller",
            label  = _("Killer Sudoku"),
            launch = function() self:showGame() end,
        })
        return
    end
    menu_items.sudokukiller = {
        text         = _("Killer Sudoku"),
        sorting_hint = "tools",
        callback     = function() self:showGame() end,
    }
end

function KillerSudoku:getBoard()
    if not self.board then
        self:ensureSettings()
        self.board = lazyrequire("board").KillerSudokuBoard:new()
        local state = self.settings:readSetting("state")
        if not self.board:load(state) then
            generateWithProgress(self.board, lazyrequire("board").DEFAULT_DIFFICULTY)
        end
    end
    return self.board
end

function KillerSudoku:saveState()
    if not self.board then return end
    self:ensureSettings()
    self.settings:saveSetting("state", self.board:serialize())
    self.settings:flush()
end

function KillerSudoku:showGame()
    if self.screen then return end
    self._session_start = os.time()
    self.screen = lazyrequire("screen"):new{
        board  = self:getBoard(),
        plugin = self,
    }
    UIManager:show(self.screen)
end

function KillerSudoku:onScreenClosed()
    local elapsed = self._session_start and (os.time() - self._session_start) or 0
    self._session_start = nil
    if ok_stats then
        local cur = StatsExporter:get(PLUGIN_ID) or {}
        StatsExporter:record(PLUGIN_ID, {
            sessions    = (cur.sessions or 0) + 1,
            last_played = os.time(),
            time_played = (cur.time_played or 0) + elapsed,
        })
    end
    self.screen = nil
end

-- KOReader >= 2026.07 plugin management (PluginLoader, PR #15240).
-- PluginLoader removes self.settings_file itself; what is left is the
-- open game screen and this game's row in the shared game_stats.lua.
function KillerSudoku:stopPlugin()
    if self.screen then
        UIManager:close(self.screen)
        self.screen = nil
    end
end

function KillerSudoku:deletePluginSettings()
    if ok_stats then StatsExporter:remove(PLUGIN_ID) end
end

return KillerSudoku
