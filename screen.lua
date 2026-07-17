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

local ButtonTable    = require("ui/widget/buttontable")
local Device         = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Menu           = require("ui/widget/menu")
local Size           = require("ui/size")
local UIManager      = require("ui/uimanager")
local VerticalGroup  = require("ui/widget/verticalgroup")
local VerticalSpan   = require("ui/widget/verticalspan")
local _              = require("gettext")
local T              = require("ffi/util").template

local KillerSudokuBoardWidget = lrequire("board_widget")

local common          = lrequire_common("base_screen")
local BaseScreen      = common.BaseScreen
local DIFFICULTY_ORDER  = common.DIFFICULTY_ORDER
local DIFFICULTY_LABELS = common.DIFFICULTY_LABELS

local DeviceScreen = Device.screen

local DIFFICULTY_CAGE_HINT = {
    easy   = "28-32",
    medium = "22-27",
    hard   = "16-21",
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
    self.board_widget = KillerSudokuBoardWidget:new{
        board              = self.board,
        onSelectionChanged = function() self:updateStatus() end,
    }

    local is_landscape = DeviceScreen:getWidth() > DeviceScreen:getHeight()
    local sw = DeviceScreen:getWidth()

    local board_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size  = self.board_widget.size + (Size.padding.large + Size.margin.default) * 2
    local right_panel_width = sw - board_frame_size - Size.span.horizontal_default
    local button_width = is_landscape
        and math.max(right_panel_width - Size.span.horizontal_default, 100)
        or  math.floor(sw * 0.9)
    local keypad_width = is_landscape and button_width or math.floor(sw * 0.75)

    -- Title bar with Options menu
    local title_bar = self:buildTitleBar(_("Killer Sudoku"), function()
        return {
            { text = _("New game"),                  callback = function() self:onNewGame() end },
            { text = self:getDifficultyButtonText(), callback = function() self:openDifficultyMenu() end },
            { text = self.board:isShowingSolution() and _("Hide result") or _("Show result"),
              callback = function() self:toggleSolution() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Digit keypad (9×9 only)
    local n        = self.board.n
    local box_rows = self.board.box_rows
    local box_cols = self.board.box_cols
    local keypad_rows = {}
    local digit = 1
    for _ = 1, box_rows do
        local row = {}
        for _ = 1, box_cols do
            local d = digit
            row[#row + 1] = {
                id = "digit_" .. d, text = tostring(d),
                callback = function() self:onDigit(d) end,
            }
            digit = digit + 1
        end
        keypad_rows[#keypad_rows + 1] = row
    end
    keypad_rows[#keypad_rows + 1] = {
        { id = "note_button", text = self:getNoteButtonText(),
          callback = function() self:toggleNoteMode() end },
        { text = _("Erase"),  callback = function() self:onErase() end },
        { text = _("Check"),  callback = function() self:checkProgress() end },
        { id = "undo_button", text = _("Undo"),
          callback = function() self:onUndo() end },
    }
    local keypad = ButtonTable:new{
        width = keypad_width, shrink_unneeded_width = true, buttons = keypad_rows,
    }
    self.note_button  = keypad:getButtonById("note_button")
    self.undo_button  = keypad:getButtonById("undo_button")
    self.digit_buttons = {}
    for d = 1, n do
        self.digit_buttons[d] = keypad:getButtonById("digit_" .. d)
    end

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            keypad,
        }
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        local content = VerticalGroup:new{
            align = "center",
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
        }
        self:buildPortraitLayout(title_bar, content, keypad)
    end
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
    return T(_("Diff: %1 (%2)"), label, hint)
end

function KillerSudokuScreen:openDifficultyMenu()
    local menu
    local function selectDifficulty(level)
        if level ~= self.board.difficulty then
            self.board:generate(level)
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

function KillerSudokuScreen:updateStatus(message)
    local status
    if message then
        status = message
    else
        local remaining = self.board:getRemainingCells()
        local row, col  = self.board:getSelection()
        local cage_info = ""
        local cage = self.board:getCage(row, col)
        if cage then
            local cage_filled, cage_partial = 0, 0
            for _, cell in ipairs(cage.cells) do
                local v = self.board:getWorkingValue(cell.r, cell.c)
                if v ~= 0 then
                    cage_filled  = cage_filled + 1
                    cage_partial = cage_partial + v
                end
            end
            cage_info = T(_("  ·  Cage: %1/%2 cells, sum %3/%4"),
                cage_filled, #cage.cells, cage_partial, cage.sum)
        end
        status = T(_("Selected: %1,%2  ·  Empty: %3%4"), row, col, remaining, cage_info)
        if self.board:isShowingSolution() then
            status = status .. "\n" .. _("Result is being shown; editing is disabled.")
        elseif self.board:isSolved() then
            status = _("Congratulations! Puzzle solved.")
        elseif self.note_mode then
            status = status .. "\n" .. _("Note mode is ON.")
        end
    end
    self.status_text:setText(status)
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

return KillerSudokuScreen
