local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local grid_utils       = lrequire_common("grid_utils")
local puzzle_generator = lrequire_common("puzzle_generator")
local BaseBoard        = lrequire_common("base_board")

local emptyGrid       = grid_utils.emptyGrid
local emptyNotes      = grid_utils.emptyNotes
local emptyMarkerGrid = grid_utils.emptyMarkerGrid
local copyGrid        = grid_utils.copyGrid
local copyNotes       = grid_utils.copyNotes

local generateSolvedBoard = puzzle_generator.generateSolvedBoard

-- ---------------------------------------------------------------------------
-- Difficulty configurations
-- ---------------------------------------------------------------------------

local DEFAULT_DIFFICULTY = "medium"

local CAGE_COUNT_RANGES = {
    easy   = { min = 28, max = 32 },
    medium = { min = 22, max = 27 },
    hard   = { min = 16, max = 21 },
}

local CAGE_MAX_SIZE = {
    easy   = 3,
    medium = 5,
    hard   = 6,
}

-- ---------------------------------------------------------------------------
-- Cage generator
-- ---------------------------------------------------------------------------

local function generateCages(solution, difficulty, n)
    local range        = CAGE_COUNT_RANGES[difficulty] or CAGE_COUNT_RANGES.medium
    local target_count = math.random(range.min, range.max)
    local max_size     = CAGE_MAX_SIZE[difficulty] or CAGE_MAX_SIZE.medium

    local assigned = {}
    for r = 1, n do
        assigned[r] = {}
        for c = 1, n do assigned[r][c] = false end
    end
    local unassigned_count = n * n

    local dirs = { {-1, 0}, {1, 0}, {0, -1}, {0, 1} }
    local function unassignedNeighbors(r, c)
        local nb = {}
        for _, d in ipairs(dirs) do
            local nr, nc = r + d[1], c + d[2]
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n and not assigned[nr][nc] then
                nb[#nb + 1] = { r = nr, c = nc }
            end
        end
        return nb
    end

    local cell_list = {}
    for r = 1, n do
        for c = 1, n do cell_list[#cell_list + 1] = { r = r, c = c } end
    end
    for i = #cell_list, 2, -1 do
        local j = math.random(i)
        cell_list[i], cell_list[j] = cell_list[j], cell_list[i]
    end

    local cages = {}
    for _, seed in ipairs(cell_list) do
        if #cages >= target_count then break end
        if not assigned[seed.r][seed.c] then
            local cage_id = #cages + 1
            local cage = {
                id    = cage_id,
                cells = { { r = seed.r, c = seed.c } },
                sum   = solution[seed.r][seed.c],
            }
            assigned[seed.r][seed.c] = true
            unassigned_count = unassigned_count - 1

            local remaining_cages = target_count - cage_id
            local safe_max
            if remaining_cages > 0 then
                safe_max = math.max(1, unassigned_count - remaining_cages)
            else
                safe_max = unassigned_count
            end
            local target_size = safe_max < 2 and 1 or math.random(2, math.min(max_size, safe_max))

            local frontier = unassignedNeighbors(seed.r, seed.c)
            while #cage.cells < target_size and #frontier > 0 do
                local idx       = math.random(#frontier)
                local candidate = frontier[idx]
                table.remove(frontier, idx)
                if not assigned[candidate.r][candidate.c] then
                    cage.cells[#cage.cells + 1] = candidate
                    cage.sum = cage.sum + solution[candidate.r][candidate.c]
                    assigned[candidate.r][candidate.c] = true
                    unassigned_count = unassigned_count - 1
                    for _, nb in ipairs(unassignedNeighbors(candidate.r, candidate.c)) do
                        local dup = false
                        for _, f in ipairs(frontier) do
                            if f.r == nb.r and f.c == nb.c then dup = true; break end
                        end
                        if not dup then frontier[#frontier + 1] = nb end
                    end
                end
            end
            cages[#cages + 1] = cage
        end
    end

    for r = 1, n do
        for c = 1, n do
            if not assigned[r][c] then
                local cage_id = #cages + 1
                cages[cage_id] = {
                    id    = cage_id,
                    cells = { { r = r, c = c } },
                    sum   = solution[r][c],
                }
                assigned[r][c] = true
            end
        end
    end

    local cell_cage = {}
    for r = 1, n do
        cell_cage[r] = {}
        for c = 1, n do cell_cage[r][c] = 0 end
    end
    for _, cage in ipairs(cages) do
        for _, cell in ipairs(cage.cells) do
            cell_cage[cell.r][cell.c] = cage.id
        end
    end
    return cages, cell_cage
end

-- ---------------------------------------------------------------------------
-- KillerSudokuBoard
-- ---------------------------------------------------------------------------

local KillerSudokuBoard = setmetatable({}, { __index = BaseBoard })
KillerSudokuBoard.__index = KillerSudokuBoard

function KillerSudokuBoard:new()
    local n = 9
    local board = {
        n               = n,
        box_rows        = 3,
        box_cols        = 3,
        grid_id         = "9x9",
        solution        = emptyGrid(n),
        user            = emptyGrid(n),
        conflicts       = emptyGrid(n),
        notes           = emptyNotes(n),
        wrong_marks     = emptyMarkerGrid(n),
        selected        = { row = 1, col = 1 },
        difficulty      = DEFAULT_DIFFICULTY,
        reveal_solution = false,
        undo_stack      = {},
        cages           = {},
        cell_cage       = emptyGrid(n),
    }
    setmetatable(board, self)
    board:recalcConflicts()
    return board
end

function KillerSudokuBoard:serialize()
    local n = self.n
    return {
        n               = n,
        box_rows        = self.box_rows,
        box_cols        = self.box_cols,
        grid_id         = self.grid_id,
        solution        = copyGrid(self.solution, n),
        user            = copyGrid(self.user, n),
        notes           = copyNotes(self.notes, n),
        wrong_marks     = copyGrid(self.wrong_marks, n),
        selected        = { row = self.selected.row, col = self.selected.col },
        difficulty      = self.difficulty,
        reveal_solution = self.reveal_solution,
        cages           = self.cages,
        cell_cage       = copyGrid(self.cell_cage, n),
    }
end

function KillerSudokuBoard:load(state)
    if not state or not state.solution or not state.user or not state.cages then
        return false
    end
    local n         = state.n or 9
    self.n          = n
    self.box_rows   = state.box_rows or 3
    self.box_cols   = state.box_cols or 3
    self.grid_id    = state.grid_id  or "9x9"
    self.solution   = copyGrid(state.solution, n)
    self.user       = copyGrid(state.user, n)
    self.notes      = copyNotes(state.notes, n)
    self.wrong_marks = state.wrong_marks and copyGrid(state.wrong_marks, n) or emptyMarkerGrid(n)
    self.conflicts  = emptyGrid(n)
    self.difficulty = state.difficulty or DEFAULT_DIFFICULTY
    self.undo_stack = {}
    self.reveal_solution = state.reveal_solution or false
    self.cages      = state.cages or {}
    self.cell_cage  = state.cell_cage and copyGrid(state.cell_cage, n) or emptyGrid(n)
    if state.selected then
        self.selected = {
            row = math.max(1, math.min(n, state.selected.row or 1)),
            col = math.max(1, math.min(n, state.selected.col or 1)),
        }
    else
        self.selected = { row = 1, col = 1 }
    end
    self:recalcConflicts()
    return true
end

function KillerSudokuBoard:generate(difficulty)
    self.difficulty = difficulty or self.difficulty or DEFAULT_DIFFICULTY
    local n, box_rows, box_cols = self.n, self.box_rows, self.box_cols
    local solution = generateSolvedBoard(n, box_rows, box_cols)
    local cages, cell_cage = generateCages(solution, self.difficulty, n)
    self.solution        = solution
    self.cages           = cages
    self.cell_cage       = cell_cage
    self.user            = emptyGrid(n)
    for _, cage in ipairs(cages) do
        if #cage.cells == 1 then
            local cell = cage.cells[1]
            self.user[cell.r][cell.c] = solution[cell.r][cell.c]
        end
    end
    self.notes           = emptyNotes(n)
    self.wrong_marks     = emptyMarkerGrid(n)
    self.selected        = { row = 1, col = 1 }
    self.reveal_solution = false
    self.undo_stack      = {}
    self:recalcConflicts()
end

-- ---------------------------------------------------------------------------
-- Killer-specific: cage helpers
-- ---------------------------------------------------------------------------

function KillerSudokuBoard:getCage(row, col)
    local cage_id = self.cell_cage[row] and self.cell_cage[row][col] or 0
    if cage_id == 0 then return nil end
    return self.cages[cage_id]
end

function KillerSudokuBoard:getCageLabelCell(cage)
    local best     = nil
    local best_idx = math.huge
    for _, cell in ipairs(cage.cells) do
        local idx = (cell.r - 1) * self.n + (cell.c - 1)
        if idx < best_idx then
            best_idx = idx
            best     = cell
        end
    end
    return best
end

function KillerSudokuBoard:isCageBoundary(r1, c1, r2, c2)
    local id1 = self.cell_cage[r1] and self.cell_cage[r1][c1] or 0
    local id2 = self.cell_cage[r2] and self.cell_cage[r2][c2] or 0
    if id1 == id2 then return false end
    if r1 ~= r2 then
        return (r1 % self.box_rows) ~= 0
    else
        return (c1 % self.box_cols) ~= 0
    end
end

-- ---------------------------------------------------------------------------
-- Overrides
-- ---------------------------------------------------------------------------

function KillerSudokuBoard:isGiven(row, col)
    local cage_id = self.cell_cage[row] and self.cell_cage[row][col] or 0
    if cage_id == 0 then return false end
    local cage = self.cages[cage_id]
    return cage ~= nil and #cage.cells == 1
end

function KillerSudokuBoard:getWorkingValue(row, col)
    return self.user[row][col]
end

function KillerSudokuBoard:getDisplayValue(row, col)
    if self.reveal_solution then
        return self.solution[row][col], false
    end
    local value = self.user[row][col]
    if value == 0 then return nil end
    return value, false
end

function KillerSudokuBoard:isConflict(row, col)
    return self.conflicts[row][col]
end

-- Extends base row/col/box detection with cage duplicate detection
function KillerSudokuBoard:recalcConflicts()
    BaseBoard.recalcConflicts(self)
    for _, cage in ipairs(self.cages) do
        local seen = {}
        for _, cell in ipairs(cage.cells) do
            local v = self:getWorkingValue(cell.r, cell.c)
            if v ~= 0 then
                if seen[v] then
                    self.conflicts[cell.r][cell.c] = true
                    if type(seen[v]) == "table" then
                        self.conflicts[seen[v].r][seen[v].c] = true
                        seen[v] = true
                    end
                else
                    seen[v] = cell
                end
            end
        end
    end
end

return {
    KillerSudokuBoard  = KillerSudokuBoard,
    DEFAULT_DIFFICULTY = DEFAULT_DIFFICULTY,
    CAGE_COUNT_RANGES  = CAGE_COUNT_RANGES,
}
