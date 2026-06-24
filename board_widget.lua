local Blitbuffer  = require("ffi/blitbuffer")
local Font        = require("ui/font")
local Geom        = require("ui/geometry")
local RenderText  = require("ui/rendertext")
local Size        = require("ui/size")

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local common           = lrequire_common("base_board_widget")
local BaseBoardWidget  = common.BaseBoardWidget
local drawLine         = common.drawLine
local drawDiagonalLine = common.drawDiagonalLine
local drawDashedLine   = common.drawDashedLine

local CAGE_BORDER_COLOR = Blitbuffer.COLOR_GRAY_E

-- ---------------------------------------------------------------------------
-- KillerSudokuBoardWidget
-- ---------------------------------------------------------------------------

local KillerSudokuBoardWidget = BaseBoardWidget:extend{
    board = nil,
}

-- Extend base init to add cage sum label font and re-fit number font
function KillerSudokuBoardWidget:init()
    BaseBoardWidget.init(self)

    -- Save full-cell number font for single-cell cage ("given") display
    self.given_face = self.number_face

    local cell = self.size / self.n

    -- Cage sum label: small font in top-left corner of each cage cell
    local sum_font_size   = math.max(6, math.floor(cell * 0.18))
    self.cage_sum_face    = Font:getFace("smallinfofont", sum_font_size)
    self.cage_sum_padding = math.max(1, math.floor(cell / 14))
    local sum_reserve     = self.cage_sum_padding + self.cage_sum_face.size

    -- Re-fit number font into the reduced height below the cage sum label
    local padding = self.number_cell_padding
    local safety  = math.max(1, math.floor(cell / 20))
    local max_w   = math.max(1, math.floor(cell - 2 * padding - safety))
    -- 65% of available height: leaves visible margin between number and cage sum
    local max_h   = math.max(1, math.floor((cell - sum_reserve) * 0.65))
    local size    = math.max(28, math.floor(self.size / 14))
    while size > 10 do
        local face = Font:getFace("cfont", size)
        local m    = RenderText:sizeUtf8Text(0, max_w, face, "8", true, false)
        local h    = m.y_top + m.y_bottom  -- ascender + descender = total glyph height
        if m.x <= max_w and h <= max_h then
            local final_size = math.max(10, size - 3)
            self.number_face      = Font:getFace("cfont", final_size)
            self.number_face_size = final_size
            break
        end
        size = size - 1
    end
end

function KillerSudokuBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    local n        = self.n
    local box_rows = self.box_rows
    local box_cols = self.box_cols
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }
    local cell = self.dimen.w / n

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)

    local sel_row, sel_col = self.board:getSelection()
    bb:paintRect(x + (sel_col - 1) * cell, y, cell, self.dimen.h, Blitbuffer.COLOR_GRAY_D)
    bb:paintRect(x, y + (sel_row - 1) * cell, self.dimen.w, cell, Blitbuffer.COLOR_GRAY_D)
    bb:paintRect(x + (sel_col - 1) * cell, y + (sel_row - 1) * cell, cell, cell, Blitbuffer.COLOR_GRAY)

    -- Interior horizontal lines: gray within a cage, black between cages
    for row = 1, n - 1 do
        if row % box_rows ~= 0 then
            for col = 1, n do
                local x0    = math.floor(x + (col - 1) * cell)
                local x1    = math.floor(x + col * cell)
                local color = self.board:isCageBoundary(row, col, row + 1, col)
                    and Blitbuffer.COLOR_BLACK or CAGE_BORDER_COLOR
                drawLine(bb, x0, math.floor(y + row * cell), x1 - x0, Size.line.thin, color)
            end
        end
    end

    -- Interior vertical lines: gray within a cage, black between cages
    for col = 1, n - 1 do
        if col % box_cols ~= 0 then
            for row = 1, n do
                local y0    = math.floor(y + (row - 1) * cell)
                local y1    = math.floor(y + row * cell)
                local color = self.board:isCageBoundary(row, col, row, col + 1)
                    and Blitbuffer.COLOR_BLACK or CAGE_BORDER_COLOR
                drawLine(bb, math.floor(x + col * cell), y0, Size.line.thin, y1 - y0, color)
            end
        end
    end

    -- Box boundaries: outer border solid thick, inner separators dashed gray
    local dash = math.max(3, math.floor(cell * 0.15))
    local gap  = math.max(2, math.floor(cell * 0.10))
    for i = 0, n do
        if i % box_cols == 0 then
            local lx = x + math.floor(i * cell)
            if i == 0 or i == n then
                drawLine(bb, lx, y, Size.line.thick, self.dimen.h, Blitbuffer.COLOR_BLACK)
            else
                drawDashedLine(bb, lx, y, Size.line.thin, self.dimen.h, Blitbuffer.COLOR_GRAY_9, dash, gap)
            end
        end
        if i % box_rows == 0 then
            local ly = y + math.floor(i * cell)
            if i == 0 or i == n then
                drawLine(bb, x, ly, self.dimen.w, Size.line.thick, Blitbuffer.COLOR_BLACK)
            else
                drawDashedLine(bb, x, ly, self.dimen.w, Size.line.thin, Blitbuffer.COLOR_GRAY_9, dash, gap)
            end
        end
    end

    -- Cage boundaries that coincide with box edges: draw solid black on top of dashes
    for row = 1, n - 1 do
        if row % box_rows == 0 then
            local ly = math.floor(y + row * cell)
            for col = 1, n do
                local id1 = self.board.cell_cage[row][col]
                local id2 = self.board.cell_cage[row + 1][col]
                if id1 ~= id2 then
                    local x0 = math.floor(x + (col - 1) * cell)
                    local x1 = math.floor(x + col * cell)
                    drawLine(bb, x0, ly, x1 - x0, Size.line.thin, Blitbuffer.COLOR_BLACK)
                end
            end
        end
    end
    for col = 1, n - 1 do
        if col % box_cols == 0 then
            local lx = math.floor(x + col * cell)
            for row = 1, n do
                local id1 = self.board.cell_cage[row][col]
                local id2 = self.board.cell_cage[row][col + 1]
                if id1 ~= id2 then
                    local y0 = math.floor(y + (row - 1) * cell)
                    local y1 = math.floor(y + row * cell)
                    drawLine(bb, lx, y0, Size.line.thin, y1 - y0, Blitbuffer.COLOR_BLACK)
                end
            end
        end
    end

    local sum_reserve  = self.cage_sum_padding + self.cage_sum_face.size
    local cell_padding = self.number_cell_padding or 0

    for row = 1, n do
        for col = 1, n do
            local value = self.board:getDisplayValue(row, col)
            if value then
                local cell_x   = x + (col - 1) * cell
                local cell_y   = y + (row - 1) * cell
                local is_given = self.board:isGiven(row, col)
                local text     = tostring(value)

                local color
                if self.board:isConflict(row, col) then
                    color = Blitbuffer.COLOR_RED
                elseif is_given then
                    color = Blitbuffer.COLOR_BLACK
                elseif self.board:isShowingSolution() then
                    color = Blitbuffer.COLOR_GRAY_4
                else
                    color = Blitbuffer.COLOR_GRAY_2
                end

                local face         = is_given and self.given_face or self.number_face
                local cell_inner_w = math.max(1, math.floor(cell - 2 * cell_padding))
                local metrics      = RenderText:sizeUtf8Text(0, cell_inner_w, face, text, true, false)
                local avail_h, baseline
                if is_given then
                    avail_h  = math.max(1, cell - 2 * cell_padding)
                    baseline = cell_y + cell_padding + math.floor((avail_h + metrics.y_top - metrics.y_bottom) / 2)
                else
                    avail_h  = math.max(1, cell - sum_reserve - cell_padding)
                    baseline = cell_y + sum_reserve + math.floor((avail_h + metrics.y_top - metrics.y_bottom) / 2)
                end
                local text_x = cell_x + cell_padding + math.floor((cell_inner_w - metrics.x) / 2)
                RenderText:renderUtf8Text(bb, text_x, baseline, face, text, true, false, color)

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

    -- Cage sum labels (single-cell cages show value in full — no label needed)
    if self.board.cages and #self.board.cages > 0 then
        local pad = self.cage_sum_padding or 1
        for _, cage in ipairs(self.board.cages) do
            if #cage.cells > 1 then
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
end

return KillerSudokuBoardWidget
