-- Project Golf x A-Life (prototype) - how the partner picks a shot.
--
-- While they line up, they try a fan of shots with Project Golf's own physics (trees, walls, water, roads, rough)
-- and keep the one that leaves them best placed: close to the cup, on the fairway, with a clear look at the flag.
-- On a dogleg the straight line into the trees scores badly, so they play down the fairway; if a drive clears the
-- corner, they take it.
--
-- Performance: the test shots run a few per frame under a time budget (Planner.budgetMs), never all at once, and
-- the plan is capped (Planner.maxMs). A drive is about 75 test shots, a chip about 45, a putt about 11.

require "ProjectGolf/PG_Config"
require "ProjectGolf/PG_Physics"
require "ProjectGolf/PG_World"
require "ProjectGolfALife/PGA_Shared"

local PG = ProjectGolf
local PGA = ProjectGolfALife

PGA.Planner = PGA.Planner or {}
local P = PGA.Planner

P.budgetMs = 2          -- test shots per frame stop once this much time is spent (always at least one): in game that's
                        -- usually one a frame, the same load as Project Golf's own aim preview
P.maxMs = 4000          -- a plan that takes longer than this is finished with the best shot found so far

-- How a spot is judged. Tile names (the map's floor and the objects on the square), lower case, matched anywhere.
PGA.Lies = PGA.Lies or {
    fairway = { "blends_natural_01" },                                   -- mown grass: fairway, green, tee
    rough   = { "blends_grassoverlays", "e_newgrass", "vegetation_foliage", "f_bushes" },
    trees   = { "vegetation_trees" },
}

-- Score = squares left to the cup + these (lower is better).
P.penalty = {
    rough   = 8,      -- landing in the rough
    trees   = 25,     -- landing among trees
    other   = 4,      -- roads, dirt, paths: playable but not ideal
    unknown = 60,     -- a square that isn't loaded: no idea what's there, so don't aim for it
    water   = 1000,   -- in the water (+1 stroke, replay)
    lost    = 1000,   -- out of the world
    perTree = 5,      -- each tree square on the line from the landing spot to the cup (first blockedLook squares)
    treeCap = 30,
    noProgress = 40,  -- ended no closer to the cup than where it started
    cup     = -1000,  -- in!
}
P.blockedLook = 30

P.fan = {
    -- offsets from the flag line (degrees, each side): fine near the line, coarse out wide
    drive = { offsets = { 7.5, 15, 22.5, 30, 45, 60 }, powers = { 0.55, 0.7, 0.8, 0.9 } },
    chip  = { offsets = { 7.5, 15, 22.5, 30, 45 }, scale = { 0.8, 1.0, 1.15 } },
    putt  = nil,      -- greens are open: straight at the hole, power by distance
}

local function dist(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end
local function now() return PG.now() end

-- The world for the distance search: the same, but without cups (a holed test putt would read as "short").
P.noCupWorld = setmetatable({ cups = function() return {} end }, { __index = function(_, k) return PG.GameWorld[k] end })

-- ---- the lie ------------------------------------------------------------------------------------------------------
local function spriteName(obj)
    if obj == nil then return nil end
    local ok, spr = pcall(function() return obj:getSprite() end)
    if not ok or spr == nil then return nil end
    local ok2, name = pcall(function() return spr:getName() end)
    return ok2 and name or nil
end

local function matches(name, list)
    if not name then return false end
    name = string.lower(name)
    for _, p in ipairs(list) do
        if string.find(name, p, 1, true) then return true end
    end
    return false
end

-- "fairway" | "rough" | "trees" | "water" | "other" | "unknown"
function P.lieAt(x, y, z)
    local ix, iy, iz = math.floor(x), math.floor(y), math.floor(z or 0)
    local info = PG.World.info(ix, iy, iz)
    if not info then return "unknown" end
    if info.water then return "water" end
    if info.tree then return "trees" end
    local sq = PG.World.square(ix, iy, iz)
    if not sq then return "unknown" end
    local lies = PGA.Lies
    local floorName
    pcall(function() floorName = spriteName(sq:getFloor()) end)
    local rough = matches(floorName, lies.rough)
    local objs
    pcall(function() objs = sq:getObjects() end)
    if objs then
        for i = 0, objs:size() - 1 do
            local n = spriteName(objs:get(i))
            if matches(n, lies.trees) then return "trees" end
            if matches(n, lies.rough) then rough = true end
        end
    end
    if rough then return "rough" end
    if matches(floorName, lies.fairway) then return "fairway" end
    return "other"
end

-- Tree squares on the line from (x, y) towards the cup, within the first `look` squares.
function P.treesOnLine(x, y, z, cx, cy, look)
    local d = dist(x, y, cx, cy)
    local n = math.min(math.floor(d), look or P.blockedLook)
    if n <= 1 then return 0 end
    local count, lastX, lastY = 0, nil, nil
    for i = 1, n do
        local t = i / d
        local ix, iy = math.floor(x + (cx - x) * t), math.floor(y + (cy - y) * t)
        if ix ~= lastX or iy ~= lastY then
            lastX, lastY = ix, iy
            local info = PG.World.info(ix, iy, z)
            if info and info.tree then count = count + 1 end
        end
    end
    return count
end

-- How good the spot a test shot leaves them in is (lower is better).
function P.score(sim, ball, cup)
    local pen = P.penalty
    if sim.result == "cup" then return pen.cup, "cup", 0 end
    if sim.result == "water" then return pen.water, "water", nil end
    if sim.result == "lost" then return pen.lost, "lost", nil end
    local f = sim.final
    local left = dist(f.x, f.y, cup.x, cup.y)
    local s = left
    local lie = P.lieAt(f.x, f.y, f.z or ball.z)
    if lie == "rough" then s = s + pen.rough
    elseif lie == "trees" then s = s + pen.trees
    elseif lie == "water" then s = s + pen.water
    elseif lie == "unknown" then s = s + pen.unknown
    elseif lie == "other" then s = s + pen.other end
    s = s + math.min(pen.treeCap, pen.perTree * P.treesOnLine(f.x, f.y, f.z or ball.z, cup.x, cup.y))
    if left >= dist(ball.x, ball.y, cup.x, cup.y) - 0.5 then s = s + pen.noProgress end
    return s, lie, left
end

-- ---- the club -----------------------------------------------------------------------------------------------------
function P.clubFor(d)
    if d <= 9 then return "putt" end
    if d <= 18 then return "chip" end
    return "drive"
end

-- ---- a plan, built a few test shots at a time -----------------------------------------------------------------------
-- plan = P.new(ball, cup) ; each frame: P.step(plan, budgetMs) until plan.done ; then plan.best = { shot, yaw, power }
-- Distance multiplier for a club at a Strength level (Project Golf's own rule: PG.Strength).
function P.multFor(shotId, strength)
    if strength == nil then return PG.distanceMult(nil, shotId) end
    if PG.strengthMult then return PG.strengthMult(shotId, strength) end   -- Project Golf's own rule, boost included
    local cfgS = PG.Strength                                                 -- (older Project Golf)
    if not cfgS or not cfgS.affects[shotId] then return 1 end
    return cfgS.minMult + (cfgS.maxMult - cfgS.minMult) * PG.clamp(strength, 0, 10) / 10
end

-- strength (optional): the golfer's Strength level, so the test shots carry as far as their real ones will
function P.new(ball, cup, strength)
    local d = dist(ball.x, ball.y, cup.x, cup.y)
    local shotId = P.clubFor(d)
    local yaw = math.deg(PG.atan2(cup.y - ball.y, cup.x - ball.x))
    local plan = {
        ball = { x = ball.x, y = ball.y, z = ball.z or 0 }, cup = cup, shot = shotId, aimYaw = yaw, d = d,
        mult = P.multFor(shotId, strength), strength = strength, startedAt = now(),
        stage = "search", lo = 0, hi = PG.Gameplay.overswingAt - 0.02, searchStep = 0,
        target = shotId == "putt" and d + 0.3 or d,      -- putts: never up, never in
        queue = {}, qi = 1, tried = 0, best = nil, bestScore = nil, done = false,
    }
    return plan
end

function P.sim(plan, yaw, power, world)
    plan.tried = plan.tried + 1
    local b = plan.ball
    return PG.simulate({ x = b.x, y = b.y, z = b.z, shot = plan.shot, power = power, yaw = yaw,
        distanceMult = plan.mult, seed = 7, maxTime = 12 }, world or PG.GameWorld)
end

function P.consider(plan, yaw, power, sim)
    local s, lie, left = P.score(sim, plan.ball, plan.cup)
    if plan.bestScore == nil or s < plan.bestScore then
        plan.best = { shot = plan.shot, yaw = yaw, power = power, lie = lie, left = left, result = sim.result,
            final = sim.final }
        plan.bestScore = s
    end
end

-- After the straight-at-the-flag power is known (p): the fan to try, nearest the flag line first.
function P.buildFan(plan, p)
    local fan = P.fan[plan.shot]
    if not fan then return end
    local yaws = { 0 }
    for _, k in ipairs(fan.offsets) do
        yaws[#yaws + 1] = k
        yaws[#yaws + 1] = -k
    end
    local powers = {}
    if fan.powers then
        for _, v in ipairs(fan.powers) do powers[#powers + 1] = v end
        powers[#powers + 1] = p                     -- the flag distance, for drives that can reach
    else
        for _, f in ipairs(fan.scale) do powers[#powers + 1] = PG.clamp(p * f, 0.05, PG.Gameplay.overswingAt - 0.02) end
    end
    for _, off in ipairs(yaws) do
        for _, pw in ipairs(powers) do
            if not (off == 0 and math.abs(pw - p) < 0.001) then
                plan.queue[#plan.queue + 1] = { yaw = plan.aimYaw + off, power = pw }
            end
        end
    end
end

-- One test shot. Returns true when the plan is done.
function P.stepOne(plan)
    if plan.done then return true end
    if plan.stage == "search" then
        -- binary search on power for the flag distance along the flag line (no cups: a holed test reads as short)
        local cap = PG.Gameplay.overswingAt - 0.02
        local power = plan.searchStep == 0 and cap or (plan.lo + plan.hi) / 2
        local sim = P.sim(plan, plan.aimYaw, power, P.noCupWorld)
        local rest = dist(sim.final.x, sim.final.y, plan.ball.x, plan.ball.y)
        if plan.searchStep == 0 then
            if rest < plan.target then plan.lo = cap; plan.searchStep = 99 end   -- can't reach: full (sensible) power
        elseif rest < plan.target then plan.lo = power else plan.hi = power end
        plan.searchStep = plan.searchStep + 1
        if plan.searchStep > 10 then
            plan.flagPower = plan.searchStep >= 99 and cap or (plan.lo + plan.hi) / 2
            plan.stage = "direct"
        end
        return false
    elseif plan.stage == "direct" then
        local sim = P.sim(plan, plan.aimYaw, plan.flagPower)
        P.consider(plan, plan.aimYaw, plan.flagPower, sim)
        P.buildFan(plan, plan.flagPower)
        plan.stage = "fan"
        if #plan.queue == 0 then plan.done = true end
        return plan.done
    elseif plan.stage == "fan" then
        local c = plan.queue[plan.qi]
        if c then
            local sim = P.sim(plan, c.yaw, c.power)
            P.consider(plan, c.yaw, c.power, sim)
            plan.qi = plan.qi + 1
        end
        if plan.qi > #plan.queue then plan.done = true end
        return plan.done
    end
    plan.done = true
    return true
end

-- Test shots until the frame's budget is spent. Returns true when the plan is done.
function P.step(plan, budgetMs)
    local start = now()
    local budget = budgetMs or P.budgetMs
    repeat
        if P.stepOne(plan) then break end
    until now() - start >= budget
    if not plan.done and now() - plan.startedAt > P.maxMs and plan.best then
        plan.done, plan.cut = true, true                 -- taking too long: the best so far
    end
    if plan.done and not plan.best then
        plan.best = { shot = plan.shot, yaw = plan.aimYaw, power = plan.flagPower or 0.5 }
    end
    plan.frames = (plan.frames or 0) + 1
    plan.workMs = (plan.workMs or 0) + (now() - start)
    if plan.done and not plan.ms then plan.ms = now() - plan.startedAt end
    return plan.done
end

-- The whole plan at once (tests).
function P.solve(ball, cup, strength)
    local plan = P.new(ball, cup, strength)
    while not P.stepOne(plan) do end
    return plan
end
