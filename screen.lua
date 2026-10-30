local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local Device         = require("device")
local Menu           = require("ui/widget/menu")
local UIManager      = require("ui/uimanager")
local _              = require("i18n")
local T              = require("ffi/util").template

local KillerSudokuBoardWidget = lrequire("board_widget")

local common          = lrequire_common("base_screen")
local BaseScreen      = common.BaseScreen
local DIFFICULTY_ORDER  = common.DIFFICULTY_ORDER
local DIFFICULTY_LABELS = common.DIFFICULTY_LABELS
local generateWithProgress = common.generateWithProgress

local DeviceScreen = Device.screen

local DIFFICULTY_CAGE_HINT = {
    easy   = "28-32",
    medium = "22-27",
    hard   = "16-21",
    expert = "12-16",
}

-- ---------------------------------------------------------------------------
-- KillerSudokuScreen
-- ---------------------------------------------------------------------------

local GAME_RULES_EN = _([[
Killer Sudoku — Rules

Standard Sudoku rules apply:
• Fill the 9×9 grid with 1–9; each row, column, and 3×3 box must contain each digit exactly once.

Cage constraint:
• Cells are grouped into "cages" outlined with dashed borders, each labelled with a target sum.
• The digits in each cage must sum exactly to that value.
• No digit may be repeated within a cage.]])

local GAME_RULES_FR = [[
Sudoku Meurtrier — Règles

Les règles du Sudoku classique s'appliquent :
• Remplissez la grille avec les chiffres 1 à 9 ; chaque ligne, colonne et carré 3×3 doit contenir chaque chiffre exactement une fois.

Contrainte des cages :
• Les cases sont regroupées en "cages" délimitées par des pointillés, chacune portant une somme cible.
• Les chiffres de chaque cage doivent sommer exactement à cette valeur.
• Un chiffre ne peut pas être répété au sein d'une même cage.
]]

local KillerSudokuScreen = BaseScreen:extend{}

function KillerSudokuScreen:buildLayout()
    local title_bar = self:buildTitleBar(_("Killer Sudoku"), function()
        return {
            { text = _("New game"),                  callback = function() self:onNewGame() end },
            { text = self:getDifficultyButtonText(), callback = function() self:openDifficultyMenu() end },
            { text = self.board:isShowingSolution() and _("Hide solution") or _("Show solution"),
              callback = function() self:toggleSolution() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)
    local controls = self:buildKeypadControls()
    self.board_widget = KillerSudokuBoardWidget:new{
        board              = self.board,
        max_size           = self:getBoardMaxSize(title_bar, controls),
        onSelectionChanged = function() self:updateStatus() end,
    }
    self:placeBoard(title_bar, self.board_widget, controls)
    self:ensureShowButtonState()
    self:updateNoteButton()
    self:updateUndoButton()
    self:updateDigitButtons()
    self:updateDifficultyButton()
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Killer-specific overrides
-- ---------------------------------------------------------------------------

function KillerSudokuScreen:getDifficultyButtonText()
    local diff  = self.board.difficulty
    local label = DIFFICULTY_LABELS[diff] or diff
    local hint  = DIFFICULTY_CAGE_HINT[diff] or ""
    return T(_("Difficulty: %1"), T("%1 (%2)", label, hint))
end

-- Status extra: progress of the cage under the selection.
function KillerSudokuScreen:getStatusExtra()
    local row, col = self.board:getSelection()
    local cage = self.board:getCage(row, col)
    if not cage then return nil end
    local cage_filled, cage_partial = 0, 0
    for _, cell in ipairs(cage.cells) do
        local v = self.board:getWorkingValue(cell.r, cell.c)
        if v ~= 0 then
            cage_filled  = cage_filled + 1
            cage_partial = cage_partial + v
        end
    end
    return T(_("Cage: %1/%2, sum %3/%4"), cage_filled, #cage.cells, cage_partial, cage.sum)
end

function KillerSudokuScreen:openDifficultyMenu()
    local menu
    local function selectDifficulty(level)
        if level ~= self.board.difficulty then
            generateWithProgress(self.board, level)
            self.plugin:saveState()
            self.board_widget:refresh()
            self:ensureShowButtonState()
            self:updateDigitButtons()
            self:updateStatus(T(_("Started a %1 game."), DIFFICULTY_LABELS[level] or level))
        else
            self:updateStatus()
        end
        self:updateDifficultyButton()
        if menu then UIManager:close(menu) end
        return true
    end
    local items = {}
    for __, level in ipairs(DIFFICULTY_ORDER) do
        local hint = DIFFICULTY_CAGE_HINT[level] or ""
        items[#items + 1] = {
            text     = T(_("%1 (%2 cages)"), DIFFICULTY_LABELS[level] or level, hint),
            checked  = (level == self.board.difficulty),
            callback = function() return selectDifficulty(level) end,
        }
    end
    menu = Menu:new{
        title    = _("Select difficulty"),
        item_table = items,
        width    = math.floor(DeviceScreen:getWidth() * 0.7),
        height   = math.floor(DeviceScreen:getHeight() * 0.9),
        disable_footer_padding = true,
        show_parent = self,
    }
    UIManager:show(menu)
end

return KillerSudokuScreen
