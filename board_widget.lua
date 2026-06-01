local Blitbuffer  = require("ffi/blitbuffer")
local Font        = require("ui/font")
local RenderText  = require("ui/rendertext")
local Size        = require("ui/size")

local common           = require("base_board_widget")
local BaseBoardWidget  = common.BaseBoardWidget
local drawLine         = common.drawLine
local drawDiagonalLine = common.drawDiagonalLine

local DASH_ON  = 3
local DASH_OFF = 3

local function drawDashedLine(bb, x, y, length, horizontal, color)
    color = color or Blitbuffer.COLOR_BLACK
    local pos = 0
    while pos < length do
        local seg = math.min(DASH_ON, length - pos)
        if seg > 0 then
            if horizontal then
                bb:paintRect(x + pos, y, seg, 1, color)
            else
                bb:paintRect(x, y + pos, 1, seg, color)
            end
        end
        pos = pos + DASH_ON + DASH_OFF
    end
end

-- ---------------------------------------------------------------------------
-- KillerSudokuBoardWidget
-- ---------------------------------------------------------------------------

local KillerSudokuBoardWidget = BaseBoardWidget:extend{
    board = nil,
}

-- Extend base init to add cage sum label font
function KillerSudokuBoardWidget:init()
    BaseBoardWidget.init(self)
    local cell_size    = self.size / self.n
    local sum_font_size = math.max(8, math.floor(cell_size * 0.28))
    self.cage_sum_face    = Font:getFace("smallinfofont", sum_font_size)
    self.cage_sum_padding = math.max(1, math.floor(cell_size / 12))
end

function KillerSudokuBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    local n        = self.n
    local box_rows = self.box_rows
    local box_cols = self.box_cols
    self.paint_rect = require("ui/geometry"):new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }
    local cell = self.dimen.w / n

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)

    local sel_row, sel_col = self.board:getSelection()
    bb:paintRect(x + (sel_col - 1) * cell, y, cell, self.dimen.h, Blitbuffer.COLOR_GRAY_D)
    bb:paintRect(x, y + (sel_row - 1) * cell, self.dimen.w, cell, Blitbuffer.COLOR_GRAY_D)
    bb:paintRect(x + (sel_col - 1) * cell, y + (sel_row - 1) * cell, cell, cell, Blitbuffer.COLOR_GRAY)

    for i = 0, n do
        local v_thick = (i % box_cols == 0) and Size.line.thick or Size.line.thin
        local h_thick = (i % box_rows == 0) and Size.line.thick or Size.line.thin
        drawLine(bb, x + math.floor(i * cell), y, v_thick, self.dimen.h, Blitbuffer.COLOR_BLACK)
        drawLine(bb, x, y + math.floor(i * cell), self.dimen.w, h_thick, Blitbuffer.COLOR_BLACK)
    end

    if self.board.cages and #self.board.cages > 0 then
        local border_color = Blitbuffer.COLOR_BLACK
        for row = 1, n - 1 do
            for col = 1, n do
                if self.board:isCageBoundary(row, col, row + 1, col) then
                    drawDashedLine(bb,
                        math.floor(x + (col - 1) * cell),
                        math.floor(y + row * cell),
                        math.floor(cell), true, border_color)
                end
            end
        end
        for row = 1, n do
            for col = 1, n - 1 do
                if self.board:isCageBoundary(row, col, row, col + 1) then
                    drawDashedLine(bb,
                        math.floor(x + col * cell),
                        math.floor(y + (row - 1) * cell),
                        math.floor(cell), false, border_color)
                end
            end
        end
    end

    for row = 1, n do
        for col = 1, n do
            local value = self.board:getDisplayValue(row, col)
            if value then
                local cell_x = x + (col - 1) * cell
                local cell_y = y + (row - 1) * cell
                local color  = self.board:isShowingSolution() and Blitbuffer.COLOR_GRAY_4 or Blitbuffer.COLOR_GRAY_2
                if self.board:isConflict(row, col) then color = Blitbuffer.COLOR_RED end
                local text         = tostring(value)
                local cell_padding = self.number_cell_padding or 0
                local sum_reserve  = self.cage_sum_padding + self.cage_sum_face.size
                local cell_inner_w = math.max(1, math.floor(cell - 2 * cell_padding))
                local metrics      = RenderText:sizeUtf8Text(0, cell_inner_w, self.number_face, text, true, false)
                local avail_h      = math.max(1, cell - sum_reserve - cell_padding)
                local baseline     = cell_y + sum_reserve + math.floor((avail_h + metrics.y_top - metrics.y_bottom) / 2)
                local text_x       = cell_x + cell_padding + math.floor((cell_inner_w - metrics.x) / 2)
                RenderText:renderUtf8Text(bb, text_x, baseline, self.number_face, text, true, false, color)
                if self.board:hasWrongMark(row, col) then
                    local padding   = math.max(1, math.floor(cell / 12))
                    local diag_len  = math.max(0, math.floor(cell - padding * 2))
                    local thickness = math.max(2, math.floor(cell / 18))
                    drawDiagonalLine(bb, cell_x + padding, cell_y + padding,        diag_len, 1,  1, Blitbuffer.COLOR_BLACK, thickness)
                    drawDiagonalLine(bb, cell_x + padding, cell_y + cell - padding, diag_len, 1, -1, Blitbuffer.COLOR_BLACK, thickness)
                end
            else
                local notes = self.board:getCellNotes(row, col)
                if notes then
                    local mini_w       = cell / box_cols
                    local mini_h       = cell / box_rows
                    local mini_padding = self.note_mini_padding or 0
                    local mini_inner_w = math.max(1, math.floor(mini_w - 2 * mini_padding))
                    local mini_inner_h = math.max(1, math.floor(mini_h - 2 * mini_padding))
                    for digit = 1, n do
                        if notes[digit] then
                            local mini_col  = (digit - 1) % box_cols
                            local mini_row  = math.floor((digit - 1) / box_cols)
                            local mini_x    = x + (col - 1) * cell + mini_col * mini_w
                            local mini_y    = y + (row - 1) * cell + mini_row * mini_h
                            local note_text = tostring(digit)
                            local note_m    = RenderText:sizeUtf8Text(0, mini_inner_w, self.note_face, note_text, true, false)
                            local note_baseline = mini_y + mini_padding + math.floor((mini_inner_h + note_m.y_top - note_m.y_bottom) / 2)
                            local note_x    = mini_x + mini_padding + math.floor((mini_inner_w - note_m.x) / 2)
                            RenderText:renderUtf8Text(bb, note_x, note_baseline, self.note_face, note_text, true, false, Blitbuffer.COLOR_GRAY_4)
                        end
                    end
                end
            end
        end
    end

    if self.board.cages and #self.board.cages > 0 then
        local pad = self.cage_sum_padding or 1
        for _, cage in ipairs(self.board.cages) do
            local label_cell = self.board:getCageLabelCell(cage)
            if label_cell then
                local label_text = tostring(cage.sum)
                local cell_x     = math.floor(x + (label_cell.c - 1) * cell)
                local cell_y     = math.floor(y + (label_cell.r - 1) * cell)
                local baseline   = cell_y + pad + self.cage_sum_face.size
                RenderText:renderUtf8Text(bb, cell_x + pad, baseline, self.cage_sum_face, label_text, true, false, Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

return KillerSudokuBoardWidget
