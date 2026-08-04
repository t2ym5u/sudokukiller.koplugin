local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local grid_utils       = lrequire_common("sudoku_grid_utils")
local puzzle_generator = lrequire_common("puzzle_generator")
local BaseBoard        = lrequire_common("base_board")

local emptyGrid       = grid_utils.emptyGrid
local emptyNotes      = grid_utils.emptyNotes
local emptyMarkerGrid = grid_utils.emptyMarkerGrid
local copyGrid        = grid_utils.copyGrid
local copyNotes       = grid_utils.copyNotes

local generateSolvedBoard = puzzle_generator.generateSolvedBoard

local bit    = require("bit")
local band   = bit.band
local bor    = bit.bor
local bnot   = bit.bnot
local lshift = bit.lshift

-- ---------------------------------------------------------------------------
-- Difficulty configurations
-- ---------------------------------------------------------------------------

local DEFAULT_DIFFICULTY = "medium"

local CAGE_COUNT_RANGES = {
    easy   = { min = 28, max = 32 },
    medium = { min = 22, max = 27 },
    hard   = { min = 16, max = 21 },
    expert = { min = 12, max = 16 },
}

local CAGE_MAX_SIZE = {
    easy   = 3,
    medium = 5,
    hard   = 6,
    expert = 7,
}

-- A "true" Killer Sudoku (0 given digits, purely random cage growth) is only
-- solvable by deduction when the cage geometry happens to enable techniques
-- like the 45-rule -- random growth rarely produces that by luck (empirically
-- near 0% of the time). Easy and Medium therefore get a handful of deliberate
-- single-cell "given" cages to bootstrap deduction; Hard/Expert stay
-- genre-pure (0 givens, guessing expected) with unchanged behavior.
local GIVEN_COUNT_RANGES = {
    easy   = { min = 10, max = 14 },
    medium = { min = 12, max = 16 },
}

-- Generation of a cage layout is not guaranteed to yield a puzzle with a
-- unique solution (cage sums alone are a weak constraint). We retry a bounded
-- number of times and verify with a budgeted solver, preferring a proven-
-- unique layout, falling back to an unproven-but-not-disproven one, and
-- finally to whatever the last attempt produced.
local CAGE_GEN_MAX_ATTEMPTS = 5
local CAGE_SOLVER_NODE_BUDGET = 6000

-- Easy/Medium additionally require the layout to be fully solvable with
-- beginner/intermediate techniques (no backtracking) -- see isHumanSolvable.
-- Per-attempt hit rate for that is well under 100%, so these tiers get a
-- larger retry budget; Hard/Expert don't use this gate at all.
local HUMAN_SOLVABLE_DIFFICULTIES = { easy = true, medium = true }
local HUMAN_SOLVABLE_MAX_ATTEMPTS = 30

-- ---------------------------------------------------------------------------
-- Cage generator
-- ---------------------------------------------------------------------------

-- The no-duplicate-digit growth constraint (below) frequently strands cells
-- that end up as their own 1-cell cage (an incidental given digit). These
-- accidental givens are unpredictable in count and placement, so fold each
-- one into an adjacent cage when that doesn't introduce a duplicate digit or
-- exceed max_size -- deliberate givens placed by generateCages (cage.is_given)
-- are exempt: those are load-bearing for Easy/Medium human-solvability.
local function mergeStraySingletons(cages, solution, n, max_size)
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

    local dirs = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
    for _, cage in ipairs(cages) do
        if #cage.cells == 1 and not cage.merged_away and not cage.is_given then
            local cell = cage.cells[1]
            local candidates = {}
            for _, d in ipairs(dirs) do
                local nr, nc = cell.r + d[1], cell.c + d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n then
                    local ncage = cages[cell_cage[nr][nc]]
                    if ncage and ncage ~= cage and not ncage.merged_away and not ncage.is_given
                        and #ncage.cells < max_size then
                        local v, dup = solution[cell.r][cell.c], false
                        for _, c2 in ipairs(ncage.cells) do
                            if solution[c2.r][c2.c] == v then dup = true; break end
                        end
                        if not dup then candidates[#candidates + 1] = ncage end
                    end
                end
            end
            if #candidates > 0 then
                local target = candidates[math.random(#candidates)]
                target.cells[#target.cells + 1] = cell
                target.sum = target.sum + solution[cell.r][cell.c]
                cage.merged_away = true
            end
        end
    end

    local final_cages = {}
    for _, cage in ipairs(cages) do
        if not cage.merged_away then
            cage.id = #final_cages + 1
            final_cages[cage.id] = cage
        end
    end
    for r = 1, n do
        for c = 1, n do cell_cage[r][c] = 0 end
    end
    for _, cage in ipairs(final_cages) do
        for _, cell in ipairs(cage.cells) do
            cell_cage[cell.r][cell.c] = cage.id
        end
    end
    return final_cages, cell_cage
end

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

    -- Deliberate single-cell "given" cages, placed first (cell_list is already
    -- shuffled, so the first N cells are a random sample). Marked is_given so
    -- mergeStraySingletons never folds them away -- Easy/Medium need these as
    -- anchor points for human-solvable deduction (see GIVEN_COUNT_RANGES).
    -- given_target cages are ADDITIONAL to target_count: they're bumped onto
    -- target_count below so the growth loop still gets its full nominal cage
    -- budget for the remaining cells (otherwise, at max_size == 3, easy's
    -- growth cages couldn't cover the cells left over after ~12 givens, and
    -- cells would spill into unplanned forced singletons/oversized cages).
    local given_range  = GIVEN_COUNT_RANGES[difficulty]
    local given_target = given_range and math.random(given_range.min, given_range.max) or 0
    given_target = math.min(given_target, n * n - 1)
    target_count = target_count + given_target
    for i = 1, given_target do
        local cell = cell_list[i]
        if not assigned[cell.r][cell.c] then
            local cage_id = #cages + 1
            cages[cage_id] = {
                id       = cage_id,
                cells    = { { r = cell.r, c = cell.c } },
                sum      = solution[cell.r][cell.c],
                is_given = true,
            }
            assigned[cell.r][cell.c] = true
            unassigned_count = unassigned_count - 1
        end
    end

    for _, seed in ipairs(cell_list) do
        if #cages >= target_count then break end
        if not assigned[seed.r][seed.c] then
            local cage_id = #cages + 1
            local cage = {
                id    = cage_id,
                cells = { { r = seed.r, c = seed.c } },
                sum   = solution[seed.r][seed.c],
            }
            -- Killer-sudoku cages must not contain the same digit twice.
            local used_digits = { [solution[seed.r][seed.c]] = true }
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
                -- Only grow into a frontier cell whose digit isn't already in the cage.
                local valid_idxs = {}
                for fi, f in ipairs(frontier) do
                    if not used_digits[solution[f.r][f.c]] then valid_idxs[#valid_idxs + 1] = fi end
                end
                if #valid_idxs == 0 then break end
                local idx       = valid_idxs[math.random(#valid_idxs)]
                local candidate = frontier[idx]
                table.remove(frontier, idx)
                if not assigned[candidate.r][candidate.c] then
                    cage.cells[#cage.cells + 1] = candidate
                    cage.sum = cage.sum + solution[candidate.r][candidate.c]
                    used_digits[solution[candidate.r][candidate.c]] = true
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

    return mergeStraySingletons(cages, solution, n, max_size)
end

-- ---------------------------------------------------------------------------
-- Cage-sum solver: counts solutions (up to `limit`) of the sudoku+cage-sum
-- instance, using MRV cell ordering and cage-sum feasibility pruning to keep
-- the search tractable. Returns (solutions_found, exhausted, nodes_visited);
-- exhausted = true means node_budget was hit before the search concluded, so
-- the solutions count is not a proof (fewer solutions may remain unexplored).
-- ---------------------------------------------------------------------------

local FULL_DIGIT_MASK = 0x3FE -- bits 1..9

local function minMaxSum(avail_mask, k)
    if k == 0 then return 0, 0 end
    local avail = {}
    for v = 1, 9 do
        if band(avail_mask, lshift(1, v)) ~= 0 then avail[#avail + 1] = v end
    end
    if #avail < k then return nil, nil end
    table.sort(avail)
    local mn, mx = 0, 0
    for i = 1, k do mn = mn + avail[i] end
    for i = #avail - k + 1, #avail do mx = mx + avail[i] end
    return mn, mx
end

local function countCageSolutions(cell_cage, cages, n, box_rows, box_cols, limit, node_budget)
    local row_used, col_used, box_used = {}, {}, {}
    for i = 1, n do row_used[i] = 0; col_used[i] = 0 end
    local num_box_cols = n / box_cols
    for i = 1, (n / box_rows) * num_box_cols do box_used[i] = 0 end
    local grid = {}
    for r = 1, n do grid[r] = {}; for c = 1, n do grid[r][c] = 0 end end
    local cage_filled_sum, cage_filled_count, cage_used_mask = {}, {}, {}
    for _, cage in ipairs(cages) do
        cage_filled_sum[cage.id]   = 0
        cage_filled_count[cage.id] = 0
        cage_used_mask[cage.id]    = 0
    end

    local function boxIndex(r, c)
        return math.floor((r - 1) / box_rows) * num_box_cols + math.floor((c - 1) / box_cols) + 1
    end

    local empties = {}
    for r = 1, n do for c = 1, n do empties[#empties + 1] = { r = r, c = c } end end
    local num_empty = #empties

    local solutions, nodes, exhausted = 0, 0, false

    local function candidatesFor(r, c)
        local used = bor(bor(row_used[r], col_used[c]), box_used[boxIndex(r, c)])
        local cage_id = cell_cage[r][c]
        local cage = cages[cage_id]
        local remaining_after = #cage.cells - cage_filled_count[cage_id] - 1
        local target_remaining = cage.sum - cage_filled_sum[cage_id]
        local cage_used = cage_used_mask[cage_id]
        local cands = {}
        for v = 1, 9 do
            local vbit = lshift(1, v)
            if band(used, vbit) == 0 and band(cage_used, vbit) == 0 then
                local rem_sum = target_remaining - v
                if rem_sum >= 0 then
                    if remaining_after == 0 then
                        if rem_sum == 0 then cands[#cands + 1] = v end
                    else
                        local avail_mask = band(bnot(bor(cage_used, vbit)), FULL_DIGIT_MASK)
                        local mn, mx = minMaxSum(avail_mask, remaining_after)
                        if mn and rem_sum >= mn and rem_sum <= mx then
                            cands[#cands + 1] = v
                        end
                    end
                end
            end
        end
        return cands
    end

    local function search(depth)
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        if depth > num_empty then solutions = solutions + 1; return end
        local best_idx, best_cands, best_len = nil, nil, 1000
        for i, cell in ipairs(empties) do
            if grid[cell.r][cell.c] == 0 then
                local cands = candidatesFor(cell.r, cell.c)
                if #cands < best_len then
                    best_len   = #cands
                    best_cands = cands
                    best_idx   = i
                    if best_len <= 1 then break end
                end
            end
        end
        if best_idx == nil then solutions = solutions + 1; return end
        if best_len == 0 then return end
        local cell = empties[best_idx]
        local r, c = cell.r, cell.c
        local b = boxIndex(r, c)
        local cage_id = cell_cage[r][c]
        for _, v in ipairs(best_cands) do
            local vbit = lshift(1, v)
            grid[r][c] = v
            row_used[r] = bor(row_used[r], vbit)
            col_used[c] = bor(col_used[c], vbit)
            box_used[b] = bor(box_used[b], vbit)
            cage_filled_sum[cage_id]   = cage_filled_sum[cage_id] + v
            cage_filled_count[cage_id] = cage_filled_count[cage_id] + 1
            cage_used_mask[cage_id]    = bor(cage_used_mask[cage_id], vbit)
            search(depth + 1)
            grid[r][c] = 0
            row_used[r] = band(row_used[r], bnot(vbit))
            col_used[c] = band(col_used[c], bnot(vbit))
            box_used[b] = band(box_used[b], bnot(vbit))
            cage_filled_sum[cage_id]   = cage_filled_sum[cage_id] - v
            cage_filled_count[cage_id] = cage_filled_count[cage_id] - 1
            cage_used_mask[cage_id]    = band(cage_used_mask[cage_id], bnot(vbit))
            if solutions >= limit or exhausted then return end
        end
    end
    search(1)
    return solutions, exhausted, nodes
end

-- ---------------------------------------------------------------------------
-- Human-solvability check
-- ---------------------------------------------------------------------------
-- Verifies a cage layout (plus its deliberate given digits) can be fully
-- deduced with beginner/intermediate killer-sudoku techniques -- naked/hidden
-- singles, cage-sum combo elimination, and the "45 rule" (every row/col/box
-- sums to 45, so a single cell that's the only overhang of an otherwise fully
-- contained cage can be read off directly) -- with NO backtracking/guessing.
-- Used to gate Easy/Medium generation: countCageSolutions above only proves a
-- unique solution *exists*, not that a human can reach it without guessing.

local function combosForCage(k, target, forbidden_mask)
    local combos = {}
    local chosen = {}
    local function rec(start, remaining_sum, remaining_slots)
        if remaining_slots == 0 then
            if remaining_sum == 0 then
                local copy = {}
                for i = 1, #chosen do copy[i] = chosen[i] end
                combos[#combos + 1] = copy
            end
            return
        end
        for v = start, 9 do
            if band(forbidden_mask, lshift(1, v)) == 0 and remaining_sum - v >= 0 then
                chosen[#chosen + 1] = v
                rec(v + 1, remaining_sum - v, remaining_slots - 1)
                chosen[#chosen] = nil
            end
        end
    end
    rec(1, target, k)
    return combos
end

-- Calls cb(order) for every permutation of `digits` (k <= 5 for the gated
-- difficulties, so k! is always small).
local function permsForDigits(digits, cb)
    local k = digits and #digits or 0
    local used, order = {}, {}
    local function rec(idx)
        if idx > k then cb(order); return end
        for i = 1, k do
            if not used[i] then
                used[i] = true
                order[idx] = digits[i]
                rec(idx + 1)
                used[i] = nil
            end
        end
    end
    rec(1)
end

local function isHumanSolvable(cages, cell_cage, seed_grid, n, box_rows, box_cols)
    local num_box_cols = n / box_cols
    local function boxIndex(r, c)
        return math.floor((r - 1) / box_rows) * num_box_cols + math.floor((c - 1) / box_cols) + 1
    end

    local grid, filled = {}, 0
    for r = 1, n do
        grid[r] = {}
        for c = 1, n do
            grid[r][c] = seed_grid[r][c]
            if grid[r][c] ~= 0 then filled = filled + 1 end
        end
    end

    -- Precompute the 27 units (9 rows, 9 cols, 9 boxes) once.
    local units = {}
    for r = 1, n do
        local u = {}
        for c = 1, n do u[#u + 1] = { r = r, c = c } end
        units[#units + 1] = u
    end
    for c = 1, n do
        local u = {}
        for r = 1, n do u[#u + 1] = { r = r, c = c } end
        units[#units + 1] = u
    end
    for br = 0, (n / box_rows) - 1 do
        for bc = 0, num_box_cols - 1 do
            local u = {}
            for r = br * box_rows + 1, br * box_rows + box_rows do
                for c = bc * box_cols + 1, bc * box_cols + box_cols do
                    u[#u + 1] = { r = r, c = c }
                end
            end
            units[#units + 1] = u
        end
    end

    local passes, progress = 0, true
    while progress and filled < n * n do
        progress = false
        passes = passes + 1
        if passes > 60 then break end

        local row_mask, col_mask, box_mask = {}, {}, {}
        for i = 1, n do row_mask[i] = 0; col_mask[i] = 0 end
        for i = 1, (n / box_rows) * num_box_cols do box_mask[i] = 0 end
        for r = 1, n do
            for c = 1, n do
                local v = grid[r][c]
                if v ~= 0 then
                    local vbit = lshift(1, v)
                    row_mask[r] = bor(row_mask[r], vbit)
                    col_mask[c] = bor(col_mask[c], vbit)
                    local b = boxIndex(r, c)
                    box_mask[b] = bor(box_mask[b], vbit)
                end
            end
        end

        local cand = {}
        for r = 1, n do
            cand[r] = {}
            for c = 1, n do
                if grid[r][c] == 0 then
                    local used = bor(bor(row_mask[r], col_mask[c]), box_mask[boxIndex(r, c)])
                    cand[r][c] = band(bnot(used), FULL_DIGIT_MASK)
                end
            end
        end

        -- Cage-sum combo elimination: narrow each empty cage cell's candidate
        -- mask to digits reachable by *some* combo+permutation consistent
        -- with every cell's current candidate mask.
        for _, cage in ipairs(cages) do
            local empties, filled_sum, filled_mask = {}, 0, 0
            for _, cell in ipairs(cage.cells) do
                local v = grid[cell.r][cell.c]
                if v ~= 0 then
                    filled_sum = filled_sum + v
                    filled_mask = bor(filled_mask, lshift(1, v))
                else
                    empties[#empties + 1] = cell
                end
            end
            local k = #empties
            if k > 0 then
                local target = cage.sum - filled_sum
                local combos = combosForCage(k, target, filled_mask)
                if #combos == 0 then return false end -- contradiction: unsolvable layout
                local possible = {}
                for i = 1, k do possible[i] = 0 end
                for _, combo in ipairs(combos) do
                    permsForDigits(combo, function(order)
                        for i = 1, k do
                            local cell = empties[i]
                            if band(cand[cell.r][cell.c], lshift(1, order[i])) == 0 then return end
                        end
                        for i = 1, k do
                            possible[i] = bor(possible[i], lshift(1, order[i]))
                        end
                    end)
                end
                for i, cell in ipairs(empties) do
                    cand[cell.r][cell.c] = band(cand[cell.r][cell.c], possible[i])
                end
            end
        end

        -- 45-rule: if a unit (row/col/box) is covered by cages fully inside it
        -- plus exactly one cage crossing its boundary with a single-cell
        -- overhang, that overhang cell's value is 45 minus the fully-inside
        -- cages' sums (or, symmetrically, cage.sum minus that for a single
        -- cell sticking *out* of the unit).
        for _, unit in ipairs(units) do
            local inside_count, full_sum, crossing, ambiguous = {}, 0, nil, false
            for _, cell in ipairs(unit) do
                local cid = cell_cage[cell.r][cell.c]
                inside_count[cid] = (inside_count[cid] or 0) + 1
            end
            for cid, cnt in pairs(inside_count) do
                local cage = cages[cid]
                if cnt == #cage.cells then
                    full_sum = full_sum + cage.sum
                elseif crossing == nil then
                    crossing = { cage = cage, inside = cnt }
                else
                    ambiguous = true
                end
            end
            if not ambiguous and crossing then
                local cage, inside = crossing.cage, crossing.inside
                if inside == 1 then
                    local v = 45 - full_sum
                    if v >= 1 and v <= 9 then
                        for _, cell in ipairs(unit) do
                            if cell_cage[cell.r][cell.c] == cage.id and grid[cell.r][cell.c] == 0
                                and band(cand[cell.r][cell.c], lshift(1, v)) ~= 0 then
                                cand[cell.r][cell.c] = lshift(1, v)
                            end
                        end
                    end
                elseif #cage.cells - inside == 1 then
                    local v = cage.sum - (45 - full_sum)
                    if v >= 1 and v <= 9 then
                        for _, cell in ipairs(cage.cells) do
                            local in_unit = false
                            for _, u in ipairs(unit) do
                                if u.r == cell.r and u.c == cell.c then in_unit = true; break end
                            end
                            if not in_unit and grid[cell.r][cell.c] == 0
                                and band(cand[cell.r][cell.c], lshift(1, v)) ~= 0 then
                                cand[cell.r][cell.c] = lshift(1, v)
                            end
                        end
                    end
                end
            end
        end

        -- naked singles
        for r = 1, n do
            for c = 1, n do
                if grid[r][c] == 0 then
                    local mask = cand[r][c]
                    if mask == 0 then return false end -- contradiction
                    if band(mask, mask - 1) == 0 then
                        for v = 1, 9 do
                            if band(mask, lshift(1, v)) ~= 0 then
                                grid[r][c] = v
                                filled = filled + 1
                                progress = true
                                break
                            end
                        end
                    end
                end
            end
        end

        -- hidden singles per unit
        if not progress then
            for _, unit in ipairs(units) do
                for v = 1, 9 do
                    local vbit = lshift(1, v)
                    local spot, cnt = nil, 0
                    for _, cell in ipairs(unit) do
                        if grid[cell.r][cell.c] == 0 and band(cand[cell.r][cell.c], vbit) ~= 0 then
                            cnt = cnt + 1
                            spot = cell
                        end
                    end
                    if cnt == 1 then
                        grid[spot.r][spot.c] = v
                        filled = filled + 1
                        progress = true
                    end
                end
            end
        end
    end

    return filled == n * n
end

-- Generate a cage layout for `solution`, retrying up to a bounded number of
-- attempts to find one with a provably unique solution (and, for Easy/Medium,
-- one that's also fully solvable by isHumanSolvable). Cage-sum constraints
-- alone are weak, so most random layouts are ambiguous; we prefer, in order:
-- (3) proven-unique AND human-solvable (only tier that returns immediately),
-- (2) proven-unique, (1) unproven-but-not-disproven (solver ran out of budget
-- before finding a 2nd solution), (0) whatever the last attempt produced.
local function generateVerifiedCages(solution, difficulty, n, box_rows, box_cols, on_progress)
    local require_human_solvable = HUMAN_SOLVABLE_DIFFICULTIES[difficulty] or false
    local max_attempts = require_human_solvable and HUMAN_SOLVABLE_MAX_ATTEMPTS or CAGE_GEN_MAX_ATTEMPTS

    local fallback_cages, fallback_cell_cage
    local fallback_tier = -1
    for attempt = 1, max_attempts do
        local cages, cell_cage = generateCages(solution, difficulty, n)
        local solutions, exhausted = countCageSolutions(
            cell_cage, cages, n, box_rows, box_cols, 2, CAGE_SOLVER_NODE_BUDGET)
        local proven_unique = not exhausted and solutions == 1

        if proven_unique then
            local solved = true
            if require_human_solvable then
                local seed_grid = emptyGrid(n)
                for _, cage in ipairs(cages) do
                    if #cage.cells == 1 then
                        local cell = cage.cells[1]
                        seed_grid[cell.r][cell.c] = solution[cell.r][cell.c]
                    end
                end
                solved = isHumanSolvable(cages, cell_cage, seed_grid, n, box_rows, box_cols)
            end
            if solved then
                if on_progress then on_progress(max_attempts, max_attempts) end
                return cages, cell_cage
            end
            if fallback_tier < 2 then
                fallback_cages, fallback_cell_cage = cages, cell_cage
                fallback_tier = 2
            end
        elseif exhausted then
            if fallback_tier < 1 then
                fallback_cages, fallback_cell_cage = cages, cell_cage
                fallback_tier = 1
            end
        elseif fallback_tier < 0 then
            fallback_cages, fallback_cell_cage = cages, cell_cage
            fallback_tier = 0
        end
        if on_progress then on_progress(attempt, max_attempts) end
    end
    return fallback_cages, fallback_cell_cage
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

function KillerSudokuBoard:generate(difficulty, randInt, on_progress)
    self.difficulty = difficulty or self.difficulty or DEFAULT_DIFFICULTY
    local n, box_rows, box_cols = self.n, self.box_rows, self.box_cols
    local solution = generateSolvedBoard(n, box_rows, box_cols, nil, randInt)
    local cages, cell_cage = generateVerifiedCages(solution, self.difficulty, n, box_rows, box_cols, on_progress)
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
