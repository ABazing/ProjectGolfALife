-- Project Golf x A-Life (prototype) - the round, on the server (single player runs the same code).
--
--   Invite      the talk window's Golf tab (Talk.choiceHandlers), or the test spawn: the NPC becomes your partner.
--   Walking     an A-Life behaviour module ("golfPartner", kind orders, runs before every other order): follow you,
--               or walk to the spot beside their ball. A-Life's own movement does the pathing.
--   Turns       you tee off on a West Maple tee box: they tee off after you. After each of your shots they play
--               theirs; once you're in they keep going until they're in (or pick up at par + 4).
--   The shot    picked like a golfer would: club by distance, power by test shots with Project Golf's own physics,
--               then the partner's Aiming skill adds the miss. Flown by the server like any other shot.

require "ProjectGolf/PG_Config"
require "ProjectGolf/PG_Physics"
require "ProjectGolf/PG_World"
require "ProjectGolf/PG_Courses"
require "ProjectGolf/PG_Skill"
require "ProjectGolf/PG_Server"
require "ProjectGolfALife/PGA_Shared"
require "ProjectGolfALife/PGA_Planner"

local PG = ProjectGolf
local PGA = ProjectGolfALife
local cfg = PGA.Config

PGA.Server = PGA.Server or {}
local M = PGA.Server
M.matches = M.matches or {}       -- uid -> match
M.byPlayer = M.byPlayer or {}     -- player key -> uid
M.pendingSpawn = M.pendingSpawn or nil
M.MODULE = "golfPartner"

local function now() return PG.now() end
local function AL() return ProjectALife end

local function try(obj, method, ...)
    if obj == nil then return nil end
    local f = obj[method]
    if type(f) ~= "function" then return nil end
    local ok, r = pcall(f, obj, ...)
    if ok then return r end
    return nil
end

local function posOf(o)
    if o == nil then return nil end
    local x, y, z = try(o, "getX"), try(o, "getY"), try(o, "getZ")
    if tonumber(x) == nil then return nil end
    return tonumber(x), tonumber(y), math.floor(tonumber(z) or 0)
end

local function dist(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

function M.playerKey(player)
    return tostring(try(player, "getUsername") or try(player, "getOnlineID") or "local")
end

-- ---------------------------------------------------------------------------------------------------------------
-- A-Life lookups (all optional: the prototype just stops when A-Life isn't there)
-- ---------------------------------------------------------------------------------------------------------------
function M.shellOf(uid)
    local talk = AL() and AL().Talk
    if talk and type(talk.shellFor) == "function" then
        local ok, shell = pcall(talk.shellFor, uid)
        if ok then return shell end
    end
    return nil
end

function M.say(m, text, face)
    local shell = M.shellOf(m.uid)
    local speech = AL() and AL().Speech
    if shell and speech and type(speech.say) == "function" then
        pcall(speech.say, shell, text, { face = face })
    end
end

function M.face(shell, x, y)
    local speech = AL() and AL().Speech
    if shell and speech and type(speech.face) == "function" then pcall(speech.face, shell, { x = x, y = y }) end
end

function M.notice(m, text)
    local player = M.playerOf(m)
    if player then PG.sendToPlayer(player, "Notice", { text = text }) end
end

function M.playerOf(m)
    if m.player and not try(m.player, "isDead") then return m.player end
    local list = getOnlinePlayers and getOnlinePlayers() or nil
    if list then
        for i = 0, list:size() - 1 do
            local p = list:get(i)
            if M.playerKey(p) == m.playerKey then m.player = p return p end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------------------------
-- Matches
-- ---------------------------------------------------------------------------------------------------------------
function M.matchOf(player) local uid = M.byPlayer[M.playerKey(player)] return uid and M.matches[uid] or nil end

-- Partners go by their first name everywhere ("Dave Miller" -> "Dave").
function M.firstName(name)
    if type(name) ~= "string" then return nil end
    return name:match("^%s*(%S+)") or name
end

function M.start(uid, player, name)
    local key = M.playerKey(player)
    local old = M.byPlayer[key]
    if old and old ~= uid then M.stop(old, "replaced") end
    local m = {
        uid = uid, player = player, playerKey = key, name = M.firstName(name) or "Partner",
        phase = "follow", phaseAt = now(), hole = nil, ball = nil, strokes = 0, holed = false,
        pStrokes = 0, pHoled = false, owed = false, nextTurnAt = nil, farSince = nil,
    }
    m.golfer = M.golferOf(uid)
    M.matches[uid] = m
    M.byPlayer[key] = uid
    M.befriend(m, true)
    PGA.log("partner", uid, "golf rating", m.golfer.rating, "- Aiming", m.golfer.aiming, "Strength", m.golfer.strength,
        "overswings", string.format("%.0f%%", m.golfer.overswing * 100))
    PGA.sendToPlayer(player, "Partner", { uid = uid, on = true })
    PG.sendToPlayer(player, "Notice", { text = tostring(m.name) .. " - golf rating " .. m.golfer.rating .. " / 10" })
    PGA.log("partner", uid, "playing with", key)
    return m
end

function M.stop(uid, why)
    local m = M.matches[uid]
    if not m then return false end
    M.removeBall(m)
    M.release(m)
    M.matches[uid] = nil
    if M.byPlayer[m.playerKey] == uid then M.byPlayer[m.playerKey] = nil end
    local player = M.playerOf(m)
    if player then PGA.sendToPlayer(player, "Partner", { uid = uid, on = false }) end
    PGA.log("round over", uid, why or "")
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Friends for the round. A-Life works out how an NPC treats you from (in order): this NPC's own grudges against you,
-- your standing with their whole faction (hit one Ward Survivor and they all turn hostile), then their faction's
-- default. For your partner, for as long as the round lasts:
--   * their own grudges against you are cleared, and they're set friendly (memory.hostileOverride = false,
--     A-Life's "forced friendly")
--   * your hostile standing with their faction is cleared (only the faction entry, nothing else about you)
--   * they tolerate you (no "careful" from bumping into them)
-- Re-applied every few seconds, so a stray club or a bad shot doesn't end the round. Put back when the round ends.
-- ---------------------------------------------------------------------------------------------------------------
M.FRIEND_EVERY_MS = 5000

function M.repKey(player)
    local rep = AL() and AL().Reputation
    if rep and type(rep.playerKey) == "function" then
        local ok, key = pcall(rep.playerKey, player)
        if ok and key then return key end
    end
    local speech = AL() and AL().Speech
    if speech and type(speech.playerKey) == "function" then
        local ok, key = pcall(speech.playerKey, player)
        if ok and key then return key end
    end
    return nil
end

-- Your faction-wide standing with their faction back to its default (only if it had turned hostile or careful).
function M.clearFactionGrudge(player, factionId)
    local rep = AL() and AL().Reputation
    if not rep or not factionId then return false end
    local key = M.repKey(player)
    local state = rep.storage
    if state == nil and ModData and type(ModData.getOrCreate) == "function" and rep.TAG then
        local ok, got = pcall(ModData.getOrCreate, rep.TAG)
        if ok then state = got end
    end
    local players = type(state) == "table" and type(state.players) == "table" and state.players or nil
    local mine = players and key and players[key] or nil
    local entry = type(mine) == "table" and mine[factionId] or nil
    if type(entry) ~= "table" or (entry.status ~= "hostile" and entry.status ~= "careful" and entry.status ~= "suspicious") then
        return false
    end
    mine[factionId] = nil
    rep.dirty = true
    if type(rep.sync) == "function" then pcall(rep.sync, player) end
    PGA.log("cleared", key, "standing with", factionId, "(was", tostring(entry.status) .. ")")
    return true
end

function M.befriend(m, first)
    local player = M.playerOf(m)
    local talk = AL() and AL().Talk
    local reg = AL() and AL().ActorRegistry
    if not player or not talk or type(talk.writeMemory) ~= "function" then return false end
    local key = M.repKey(player)
    local record = reg and type(reg.peek) == "function" and reg.peek(m.uid) or nil
    if record and record.factionId then M.clearFactionGrudge(player, record.factionId) end
    local farFuture = now() + 7 * 24 * 3600 * 1000
    local ok = talk.writeMemory(m.uid, function(memory)
        if first and m.savedOverride == nil then
            m.savedOverride = { value = memory.hostileOverride }
        end
        memory.hostileOverride = false
        memory.hostileAct = nil
        if key then
            if type(memory.hostileToPlayerKeys) == "table" then memory.hostileToPlayerKeys[key] = nil end
            if type(memory.carefulPlayerKeys) == "table" then memory.carefulPlayerKeys[key] = nil end
            memory.tolerateUntil = type(memory.tolerateUntil) == "table" and memory.tolerateUntil or {}
            memory.tolerateUntil[key] = farFuture
        end
        m.squadId = memory.squadId
    end)
    if m.debug then M.fullOpinion(m) end
    m.friendAt = now()
    return ok
end

-- Debug partners (the test spawn): A-Life's own trust score for you (NpcOpinion, -100 "Hates you" .. +100 "Would stand
-- by you") set to the top and held there, so no talk option is refused for lack of trust. Invited NPCs keep theirs.
M.FULL_OPINION = 100

function M.fullOpinion(m)
    local O = AL() and AL().NpcOpinion
    local player = M.playerOf(m)
    if not O or not player or type(O.write) ~= "function" or type(O.keyOf) ~= "function" then return false end
    local key = O.keyOf(player)
    if not key then return false end
    local hours = type(O.hours) == "function" and O.hours() or 0
    return O.write(m.uid, function(memory)
        memory.opinion = type(memory.opinion) == "table" and memory.opinion or {}
        local row = memory.opinion[key]
        if type(row) ~= "table" then row = {} memory.opinion[key] = row end
        row.v, row.at = M.FULL_OPINION, hours
        row.why, row.w = "You play golf together.", M.FULL_OPINION
    end)
end

function M.release(m)
    local talk = AL() and AL().Talk
    if not talk or type(talk.writeMemory) ~= "function" then return end
    local saved = m.savedOverride
    pcall(talk.writeMemory, m.uid, function(memory)
        memory.hostileOverride = saved and saved.value or nil
        local key = M.repKey(M.playerOf(m))
        if key and type(memory.tolerateUntil) == "table" then memory.tolerateUntil[key] = now() + 30 * 60 * 1000 end
    end)
end

-- A-Life's offline director hands groups trips ("rest at Riverside") when their task runs out, and a one-man group
-- made from your partner walked off mid-round. Partners' groups get no new trips while they play.
function M.isPartnerSquad(squad)
    local id = type(squad) == "table" and (squad.id or squad.squadId) or nil
    if id == nil then return false end
    for _, m in pairs(M.matches) do
        if m.squadId ~= nil and m.squadId == id then return true end
    end
    return false
end

function M.protectSquads()
    local render = AL() and AL().RenderProtocol
    if M.squadsProtected or not render or type(render.canRetask) ~= "function" then return M.squadsProtected == true end
    local original = render.canRetask
    render.canRetask = function(squad, ...)
        if M.isPartnerSquad(squad) then return false end
        return original(squad, ...)
    end
    M.squadsProtected = true
    return true
end

-- Why isn't my partner following? Logged once per stretch, so the next test tells us.
function M.noteLagging(m, t, gap)
    if gap <= cfg.followGap + 4 then m.lagSince, m.lagLogged = nil, nil return end
    m.lagSince = m.lagSince or t
    if m.lagLogged or t - m.lagSince < 8000 then return end
    m.lagLogged = true
    local reg = AL() and AL().ActorRegistry
    local record = reg and type(reg.peek) == "function" and reg.peek(m.uid) or nil
    local memory = record and type(record.memory) == "table" and record.memory or {}
    local player = M.playerOf(m)
    local relations = AL() and AL().Relations
    local stance = "?"
    if relations and type(relations.playerStance) == "function" and record then
        local ok, s = pcall(relations.playerStance, record, player)
        if ok then stance = tostring(s) end
    end
    local order = type(memory.orderedTo) == "table" and memory.orderedTo.kind or "-"
    PGA.log(string.format("partner %s not following: %.0f tiles away for 8s, phase=%s activity=%s intent=%s stance=%s squad=%s order=%s lifecycle=%s jog=%d/%d",
        m.uid, gap, m.phase, tostring(record and record.activity), tostring(record and record.intent), stance,
        tostring(memory.squadId), tostring(order), tostring(record and record.lifecycle), m.jogGranted or 0, m.jogAsked or 0))
    m.jogGranted, m.jogAsked = 0, 0
end

-- A new hole: both cards to zero, their ball on their side of the tee box.
-- Their tee spot: between the tee markers, across the line to the cup, on the other half of the box from your
-- ball (yourBall = where you teed off), or a random half when they tee off first.
function M.teeSpot(hole, cup, yourBall)
    local tx, ty = hole.tee.x + 0.5, hole.tee.y + 0.5
    local ax, ay = cup.x - tx, cup.y - ty
    local len = math.max(0.01, math.sqrt(ax * ax + ay * ay))
    local nx, ny = -ay / len, ax / len                -- across the line (the tee markers sit on it)
    local side
    if yourBall and yourBall.x then
        local yours = (yourBall.x - tx) * nx + (yourBall.y - ty) * ny
        side = yours >= 0 and -1 or 1
    else
        side = (ZombRand and ZombRand(2) == 0) and -1 or 1
    end
    return { x = tx + nx * cfg.teeSide * side, y = ty + ny * cfg.teeSide * side, z = hole.cup.z or 0, tee = true }
end

function M.startHole(m, hole, yourBall)
    M.removeBall(m)
    m.hole, m.strokes, m.holed, m.picked = hole, 0, false, false
    m.pStrokes, m.pHoled = 0, false
    m.playOut = false
    m.cup = M.cupOf(hole)
    m.ball = M.teeSpot(hole, m.cup, yourBall)
end

-- Where the cup really is (the map hole's offset inside its square), else the square's centre.
function M.cupOf(hole)
    local z = hole.cup.z or 0
    local ok, list = pcall(PG.World.cups, hole.cup.x, hole.cup.y, z)
    if ok and type(list) == "table" and list[1] then return { x = list[1].x, y = list[1].y, z = z } end
    return { x = hole.cup.x + 0.5, y = hole.cup.y + 0.5, z = z }
end

-- ---- the ball on the ground: a real golf ball item, so it shows in iso and Viewpoint ----------------------------
function M.placeBall(m)
    if not m.ball or m.holed then return end
    local item = m.ballItem
    if not item and type(instanceItem) == "function" then
        local ok, it = pcall(instanceItem, PG.Items.Ball)
        if ok then item = it end
    end
    if not item then return end
    local md = try(item, "getModData")
    if type(md) == "table" then md.ProjectGolfALifeBall = m.uid end
    if PG.Server.nameBall then PG.Server.nameBall(item, m.name) end   -- "Dave's golf ball" (Project Golf's ball names)
    if PG.Server.placeWorldItem(item, m.ball.x, m.ball.y, m.ball.z) then m.ballItem = item end
end

function M.removeBall(m)
    local item = m.ballItem
    m.ballItem = nil
    if not item then return end
    local wo = try(item, "getWorldItem")
    if wo then pcall(PG.Server.removeWorldItem, wo) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Picking the shot
-- ---------------------------------------------------------------------------------------------------------------
M.powerError = { putt = 0.07, chip = 0.08, drive = 0.05 }

-- ---- who they are as a golfer ------------------------------------------------------------------------------------
-- Their golf rating (1-10) and what it makes them: Aiming, Strength and how often they overswing (Config). Random, but
-- worked out from their A-Life id, so the same person is always the same golfer (nothing to save).
local function hashOf(text, salt)
    local h = salt or 7
    text = tostring(text)
    for i = 1, #text do h = (h * 31 + string.byte(text, i)) % 1000003 end
    for _ = 1, 3 do h = (h * 48271) % 2147483647 end
    return h
end

function M.golferOf(uid)
    local lo, hi = math.floor(cfg.ratingMin or 1), math.floor(cfg.ratingMax or 10)
    local span = hi - lo
    local rng = PG.newRng(hashOf(uid, 11))
    -- two dice: most people are middling, 1s and 10s are rare
    local roll = rng:next() + rng:next()                                  -- 0..2, peaked at 1
    local rating = PG.clamp(lo + math.floor(roll / 2 * (span + 1)), lo, hi)
    local t = span > 0 and (rating - lo) / span or 0.5
    local s1, s10 = cfg.strengthAt1 or 3, cfg.strengthAt10 or 8
    local strength = math.floor(s1 + (s10 - s1) * t + 0.5) + math.floor(rng:next() * 3) - 1   -- give or take 1
    local o1, o10 = cfg.overswingAt1 or 0.12, cfg.overswingAt10 or 0.02
    return {
        rating = rating,
        aiming = PG.clamp(rating, 0, 10),
        strength = PG.clamp(strength, 0, 10),
        overswing = o1 + (o10 - o1) * t,
    }
end

M.golferLines = {
    { max = 2, text = "Fair warning, I haven't swung a club in years." },
    { max = 4, text = "I've played a bit. Don't expect miracles." },
    { max = 6, text = "I used to get out on the course most weekends." },
    { max = 8, text = "I play off a decent handicap, if I say so myself." },
    { max = 10, text = "I was club champion, once upon a time." },
}

function M.golferLine(g)
    for _, l in ipairs(M.golferLines) do if g.rating <= l.max then return l.text end end
    return M.golferLines[#M.golferLines].text
end

-- ---- the shot they play --------------------------------------------------------------------------------------------
-- The planned shot, their miss (their Aiming), and now and then an overswing (chips and drives): swung past the red
-- line, with the spray and mishit chance Project Golf gives you (PG.Overswing, PG.Skill), at their Aiming.
function M.planShot(m, rng)
    local g = m.golfer or M.golferOf(m.uid)
    local plan = m.plan
    if not plan or not plan.done then
        plan = PGA.Planner.solve(m.ball, m.cup, g.strength)       -- (only if lining up was cut short)
    end
    local best = plan.best
    local shotId = best.shot
    local level = PG.clamp(g.aiming, 0, 10)
    local spread = PG.Shots[shotId].accuracyDeg * PG.Skill.spreadMult(level)
    local pErr = (M.powerError[shotId] or 0.06) * (1.5 - level / 10)
    local power = PG.clamp(best.power * (1 + rng:gauss() * pErr), 0.02, 1)
    -- swinging too hard: now and then, more often the lower their rating (g.overswing)
    if shotId ~= "putt" and rng:next() < (g.overswing or 0.05) then
        power = rng:range(PG.Gameplay.overswingAt + 0.01, 1)
    end
    local yaw = best.yaw + rng:gauss() * spread
    local overswung, mishit = false, false
    local o = PG.Server.overswingAmount(power)
    if o > 0 and shotId ~= "putt" then
        local ov = PG.Overswing
        overswung = true
        yaw = yaw + rng:gauss() * (ov.spreadMin + (ov.spreadMax - ov.spreadMin) * o) * PG.Skill.spreadMult(level)
        local mishitChance = (ov.mishitMin + (ov.mishitMax - ov.mishitMin) * o) * PG.Skill.mishitMult(level)
        if rng:next() < mishitChance then
            mishit = true
            power = power * rng:range(ov.mishitPowerMin, ov.mishitPowerMax)
            local veer = rng:range(ov.mishitAngleMin, ov.mishitAngleMax)
            yaw = yaw + (rng:next() < 0.5 and -veer or veer)
        end
    end
    return {
        shot = shotId, aimYaw = best.yaw, flagYaw = plan.aimYaw, expect = best.lie, tried = plan.tried,
        frames = plan.frames or 0, workMs = plan.workMs or 0, planMs = plan.ms or 0,
        yaw = yaw, power = power, overswung = overswung, mishit = mishit,
        distanceMult = PGA.Planner.multFor(shotId, g.strength),
    }
end

-- Where they stand: beside the ball, square to the line (right-handed: the line runs from their left to their right).
function M.standSpot(m)
    local b, c = m.ball, m.cup
    local ax, ay = c.x - b.x, c.y - b.y
    local len = math.max(0.01, math.sqrt(ax * ax + ay * ay))
    return { x = b.x - ay / len * cfg.standOff, y = b.y + ax / len * cfg.standOff, z = b.z }
end

-- ---------------------------------------------------------------------------------------------------------------
-- The partner's turn: walk -> address -> swing -> flight -> follow
-- ---------------------------------------------------------------------------------------------------------------
function M.setPhase(m, phase) m.phase, m.phaseAt = phase, now() end

function M.beginTurn(m)
    m.owed, m.nextTurnAt = false, nil
    if not m.ball then return end
    m.stand = M.standSpot(m)
    M.setPhase(m, "walk")
end

local function pick(list) return list[((ZombRand and ZombRand(#list) or 0) % #list) + 1] end

function M.shoot(m)
    local seed = ZombRand and ZombRand(1, 2000000000) or now()
    local rng = PG.newRng(seed)
    local plan = M.planShot(m, rng)
    local b = m.ball
    M.removeBall(m)
    local sim = PG.simulate({ x = b.x, y = b.y, z = b.z, shot = plan.shot, power = plan.power, yaw = plan.yaw,
        seed = seed, distanceMult = plan.distanceMult }, PG.GameWorld)
    m.strokes = m.strokes + 1
    m.plan = nil
    m.lastFrom = { x = b.x, y = b.y, z = b.z }
    m.flight = sim
    if addSound then
        local shell = M.shellOf(m.uid)
        local r = PG.Shots[plan.shot].noiseRadius
        if shell then pcall(addSound, shell, math.floor(b.x), math.floor(b.y), b.z, r, r) end
    end
    local evT, evK = {}, {}
    for i, e in ipairs(sim.events) do evT[i], evK[i] = e.t, e.kind end
    local final = sim.result == "lost" and b or sim.final
    if PGA.DEBUG then PGA.log(string.format("shot %d %s power %.2f yaw %.1f (aimed %.1f, flag %.1f, expected %s): %.1f,%.1f -> %.1f,%.1f %s",
        m.strokes, plan.shot, plan.power, plan.yaw, plan.aimYaw, plan.flagYaw, tostring(plan.expect),
        b.x, b.y, final.x, final.y, sim.result)) end
    -- the planner's cost, always logged (one line per partner shot): tune PGA.Planner.budgetMs from this
    PGA.log(string.format("plan: %s, %d test shots over %d frames, %.0f ms of work (%.1f ms a test shot), %.1f s lining up",
        plan.shot, plan.tried or 0, plan.frames, plan.workMs, plan.workMs / math.max(1, plan.tried or 1), plan.planMs / 1000))
    PG.broadcast("Flight", {
        by = -1, pgaNpc = true, mishit = plan.mishit == true, overhit = plan.overswung == true,
        cupX = sim.cup and sim.cup.x, cupY = sim.cup and sim.cup.y, cupZ = sim.cup and sim.cup.z,
        shot = plan.shot, path = sim.path, sampleDt = sim.sampleDt, duration = sim.duration, result = sim.result,
        evT = evT, evK = evK, x0 = b.x, y0 = b.y, z0 = b.z, x1 = final.x, y1 = final.y, z1 = final.z,
    })
    m.flightDue = now() + math.floor(sim.duration * 1000) + 300
    M.setPhase(m, "flight")
    if plan.mishit then M.say(m, pick(M.lines.mishit))
    elseif plan.overswung then M.say(m, pick(M.lines.overswing)) end
    return plan, sim
end

M.lines = {
    tee = { "Nice one. My turn.", "Alright, let's see.", "Here goes nothing." },
    cupFor = { [-3] = "Albatross! I'll never do that again.", [-2] = "Eagle! Did you see that?", [-1] = "Birdie!",
        [0] = "Par. I'll take it.", [1] = "Bogey. Could be worse.", [2] = "Double. Ugh." },
    water = { "Splash. Wonderful.", "That's a swimming ball now." },
    drop = { "I'll drop one here.", "Can't get to it. Dropping one." },
    overswing = { "Oof, swung out of my shoes there.", "Too much!", "Got a bit greedy with that one." },
    mishit = { "FORE!", "Shanked it. Don't look at me.", "Where is THAT going?" },
}


function M.landed(m)
    local sim = m.flight
    m.flight = nil
    local par = m.hole and m.hole.par or 4
    if sim.result == "cup" then
        m.holed, m.ball = true, nil
        M.say(m, M.lines.cupFor[PG.clamp(m.strokes - par, -3, 2)] or (m.strokes - par > 0 and "Finally." or "Yes!"))
    elseif sim.result == "water" then
        m.strokes = m.strokes + 1
        m.ball = { x = m.lastFrom.x, y = m.lastFrom.y, z = m.lastFrom.z }
        M.say(m, pick(M.lines.water))
    elseif sim.result ~= "lost" then
        m.ball = { x = sim.final.x, y = sim.final.y, z = sim.final.z }
    end
    if not m.holed and m.strokes >= par + cfg.maxOverPar then
        m.holed, m.picked, m.ball = true, true, nil
        M.say(m, "I'm picking that up. " .. m.strokes .. " for me.")
    end
    M.placeBall(m)
    M.setPhase(m, "follow")
    if m.holed then
        m.playOut = false
        M.sendScore(m)
        M.finishHoleIfDone(m)
    elseif m.playOut then
        m.nextTurnAt = now() + cfg.turnDelayMs * 2     -- "go ahead": straight on to their next shot
    elseif m.pHoled then
        m.nextTurnAt = now() + cfg.turnDelayMs * 2     -- you're in: they play on
    elseif m.owed then
        m.nextTurnAt = now() + cfg.turnDelayMs
    end
end

-- Their score onto your scorecard (PGA_Client: an extra column on Project Golf's card).
function M.sendScore(m)
    local hole, player = m.hole, M.playerOf(m)
    if not hole or not hole.course or not hole.number or not player then return end
    PGA.sendToPlayer(player, "PartnerScore", { course = hole.course.id, hole = hole.number, strokes = m.strokes,
        picked = m.picked == true, name = m.name, uid = m.uid, par = hole.par, rating = m.golfer and m.golfer.rating })
end

function M.finishHoleIfDone(m)
    if not (m.holed and m.pHoled) or not m.hole then return end
    local par = m.hole.par
    local function vs(n) local d = n - par return d == 0 and "E" or (d > 0 and "+" .. d or tostring(d)) end
    local text = "Hole " .. tostring(m.hole.number or "?") .. ":  you " .. m.pStrokes .. " (" .. vs(m.pStrokes) .. ")  -  "
        .. m.name .. " " .. m.strokes .. (m.picked and " (picked up)" or "") .. " (" .. vs(m.strokes) .. ")"
    M.notice(m, text)
    if m.pStrokes < m.strokes then M.say(m, "Your hole. Nicely played.")
    elseif m.pStrokes > m.strokes then M.say(m, "That one's mine!")
    else M.say(m, "Halved. Next tee?") end
    m.hole, m.ball, m.cup = nil, nil, nil
end

-- ---- your shots (Project Golf's Hit, watched) -------------------------------------------------------------------
function M.onPlayerShot(player, f)
    local m = M.matchOf(player)
    if not m or type(f) ~= "table" then return end
    -- teeing off on a tee box starts that hole (the same hole again only once you've finished it)
    local teeHole = PG.Courses.teeAt(f.x0, f.y0)
    if teeHole and teeHole.tee and (m.hole ~= teeHole or m.pHoled) then M.startHole(m, teeHole, { x = f.x0, y = f.y0 }) end
    if not m.hole then return end           -- off the course: they just keep you company
    m.pStrokes = m.pStrokes + 1 + (f.result == "water" and 1 or 0)
    if f.result == "cup" then
        local hole = f.cupX and PG.Courses.holeAtCup(f.cupX, f.cupY, f.cupZ)
        if hole == m.hole then m.pHoled = true end
    end
    if m.holed then
        M.finishHoleIfDone(m)
        return
    end
    if m.playOut then return end            -- they're playing the hole out on their own
    local due = now() + math.floor((tonumber(f.duration) or 1) * 1000) + cfg.turnDelayMs
    if m.phase == "follow" then
        m.nextTurnAt = math.max(m.nextTurnAt or 0, due)
    else
        m.owed = true                        -- mid-turn: they go again when this one's done
    end
end

function M.wrapHit()
    if M.hitWrapped or type(PG.ServerCommands.Hit) ~= "function" then return end
    local original = PG.ServerCommands.Hit
    PG.ServerCommands.Hit = function(player, args)
        local captured
        local broadcast = PG.broadcast
        PG.broadcast = function(command, a)
            if command == "Flight" then captured = a end
            return broadcast(command, a)
        end
        local ok, err = pcall(original, player, args)
        PG.broadcast = broadcast
        if not ok then error(err) end
        if captured then
            local ok2, err2 = pcall(M.onPlayerShot, player, captured)
            if not ok2 then PGA.log("shot hook failed:", err2) end
        end
    end
    M.hitWrapped = true
end

-- ---------------------------------------------------------------------------------------------------------------
-- The tick: turns and timers (movement itself is the behaviour module below)
-- ---------------------------------------------------------------------------------------------------------------
function M.tickMatch(m, t)
    local shell = M.shellOf(m.uid)
    local player = M.playerOf(m)
    if not player then return end
    local px, py = posOf(player)
    local sx, sy = posOf(shell)
    -- you walked off: the round ends after a while
    if px and sx and dist(px, py, sx, sy) > cfg.giveUpTiles then
        m.farSince = m.farSince or t
        if t - m.farSince > cfg.giveUpMs then return M.stop(m.uid, "player_left") end
    else
        m.farSince = nil
    end
    if not shell then return end           -- not loaded right now: wait
    if t - (m.friendAt or 0) >= M.FRIEND_EVERY_MS then M.befriend(m, false) end
    if px and sx and m.phase == "follow" and not m.playOut then
        local gap = dist(px, py, sx, sy)
        M.noteLagging(m, t, gap)
        M.hurry(m, shell, gap, t)
    elseif sx and m.phase == "walk" and m.stand then
        M.hurry(m, shell, dist(sx, sy, m.stand.x, m.stand.y), t)
    end

    if m.phase == "follow" then
        if m.nextTurnAt and t >= m.nextTurnAt and not m.holed and m.ball then
            if m.ball.tee and m.strokes == 0 then M.say(m, pick(M.lines.tee), player) end
            M.beginTurn(m)
        end
    elseif m.phase == "walk" then
        local d = dist(sx, sy, m.stand.x, m.stand.y)
        if d <= cfg.arriveTiles then
            M.face(shell, m.cup.x, m.cup.y)
            M.setPhase(m, "address")
        elseif t - m.phaseAt > cfg.walkTimeoutMs then
            if dist(sx, sy, m.ball.x, m.ball.y) <= 4 then
                M.setPhase(m, "address")
            else
                -- stuck: drop a ball beside them, one stroke penalty
                M.removeBall(m)
                m.strokes = m.strokes + 1
                local _, _, sz = posOf(shell)
                m.ball = { x = sx + 0.6, y = sy, z = sz or 0 }
                M.placeBall(m)
                M.say(m, pick(M.lines.drop))
                m.stand = M.standSpot(m)
                M.setPhase(m, "walk")
            end
        end
    elseif m.phase == "address" then
        if not m.plan or m.plan.ballAt ~= m.ball then
            m.plan = PGA.Planner.new(m.ball, m.cup, (m.golfer or M.golferOf(m.uid)).strength)
            m.plan.ballAt = m.ball
        end
        if not m.plan.done then
            M.face(shell, m.cup.x, m.cup.y)
            return                                  -- still thinking (PGA_Planner runs a few test shots a frame)
        end
        local yaw = math.rad(m.plan.best.yaw)
        M.face(shell, m.ball.x + math.cos(yaw) * 10, m.ball.y + math.sin(yaw) * 10)
        if t - m.phaseAt >= cfg.addressMs then
            local anims = AL() and AL().Animations
            if anims and type(anims.apply) == "function" then pcall(anims.apply, shell, PGA.SWING) end
            M.setPhase(m, "swing")
        end
    elseif m.phase == "swing" then
        if t - m.phaseAt >= cfg.swingDelayMs then M.shoot(m) end
    elseif m.phase == "flight" then
        if t >= (m.flightDue or 0) then M.landed(m) end
    end
end

-- (Project Zomboid's Lua has no next(): this is "is the table empty")
local function anyMatch()
    for _ in pairs(M.matches) do return true end
    return false
end

function M.onTick()
    if not anyMatch() then return end
    -- shot planning: a few test shots every frame, within PGA.Planner.budgetMs
    for _, m in pairs(M.matches) do
        if m.phase == "address" and m.plan and not m.plan.done then
            local ok, err = pcall(PGA.Planner.step, m.plan)
            if not ok then PGA.log("planner failed:", err); m.plan.done = true; m.plan.best = m.plan.best or
                { shot = m.plan.shot, yaw = m.plan.aimYaw, power = m.plan.flagPower or 0.5 } end
        end
    end
    local t = now()
    if M.lastTick and t - M.lastTick < 100 then return end
    M.lastTick = t
    for uid, m in pairs(M.matches) do
        local reg = AL() and AL().ActorRegistry
        local record = reg and type(reg.peek) == "function" and reg.peek(uid) or nil
        if reg and type(reg.peek) == "function" and (record == nil or record.lifecycle == "dead") then
            M.stop(uid, "partner_gone")
        else
            local ok, err = pcall(M.tickMatch, m, t)
            if not ok then PGA.log("tick failed:", err) end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The behaviour module: where they walk. Kind "orders" with priority 5, so it runs before A-Life's own orders and
-- activities; threats (zombies) still come first, as for every module.
-- ---------------------------------------------------------------------------------------------------------------
local function idle(t, ms, intent) return { kind = "idle", intent = intent, cooldownUntilMs = t + ms } end

-- A-Life only runs a "run" walk in short bursts (about 0.65 s in every 14 s) unless the NPC holds a fast-pace lease;
-- the lease itself is renewed every tick by M.hurry while they're far off.
function M.paceFor(d) return d > cfg.runGap and "run" or "walk" end

-- Where to stop when following: followBehind short of you, on the side they're coming from.
function M.followSpot(px, py, pz, sx, sy)
    local dx, dy = sx - px, sy - py
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.01 then return { x = px, y = py, z = pz } end
    return { x = px + dx / len * cfg.followBehind, y = py + dy / len * cfg.followBehind, z = pz }
end

-- Behind: ask A-Life to let them keep moving fast (Gait.grantBurst: a 1.2 s lease, refused when they're out of
-- breath). Without it, A-Life only jogs in short bursts. A partner's fast pace is a jog, never a sprint
-- (M.jogOnly, a wrap on Gait.burstPace).
function M.hurry(m, shell, gap, t)
    if gap <= cfg.runGap then return false end
    local gait = AL() and AL().Gait
    if not gait or type(gait.grantBurst) ~= "function" then return false end
    local reg = AL() and AL().ActorRegistry
    local actor = reg and type(reg.peek) == "function" and reg.peek(m.uid) or { uid = m.uid }
    local ok, granted = pcall(gait.grantBurst, actor, shell, nil, t, gap, cfg.runGap)
    m.jogAsked = (m.jogAsked or 0) + 1
    if ok and granted == true then m.jogGranted = (m.jogGranted or 0) + 1 end
    return ok and granted == true
end

function M.evaluate(actor, shell, context)
    local m = type(actor) == "table" and M.matches[actor.uid] or nil
    if not m then return nil end
    local t = (type(context) == "table" and context.now) or now()
    local start = type(context) == "table" and context.startMovement or nil
    local sx, sy, sz = posOf(shell)
    if sx == nil then return nil end
    if m.phase == "walk" and m.stand then
        local d = dist(sx, sy, m.stand.x, m.stand.y)
        if d > cfg.arriveTiles and start then
            local state = start(actor, shell, { x = m.stand.x, y = m.stand.y, z = m.stand.z }, "golf_walk",
                { pace = M.paceFor(d), timeoutMs = 9000, tolerance = 0.5 })
            if state then return state end
        end
        return idle(t, 300, "golf_walk_wait")
    elseif m.phase == "follow" and m.playOut then
        return idle(t, 400, "golf_play_out")         -- on to their next shot in a moment, not back to you
    elseif m.phase == "follow" then
        local player = M.playerOf(m)
        local px, py, pz = posOf(player)
        local gap = px and dist(px, py, sx, sy) or 0
        if px and start and gap > cfg.followGap then
            local spot = M.followSpot(px, py, pz, sx, sy)
            -- short walks, so a moving player is chased where they are now, not where they were
            local state = start(actor, shell, spot, "golf_follow",
                { pace = M.paceFor(gap), timeoutMs = cfg.followRetargetMs, tolerance = 1.0 })
            if state then return state end
        end
        if px then M.face(shell, px, py) end
        return idle(t, 400, "golf_watch")
    end
    return idle(t, 250, "golf_" .. m.phase)   -- address / swing / flight: stand still
end

-- Golf partners jog, they don't sprint: A-Life's fast pace for them is "run" (its jog) while they're playing.
function M.isPartnerShell(shell)
    local ok, data = pcall(function() return shell:getModData() end)
    local uid = ok and type(data) == "table" and data.ProjectALifeUID or nil
    return uid ~= nil and M.matches[uid] ~= nil
end

function M.jogOnly()
    local gait = AL() and AL().Gait
    if M.jogWrapped or not gait or type(gait.burstPace) ~= "function" then return M.jogWrapped == true end
    local original = gait.burstPace
    gait.burstPace = function(shell, ...)
        if M.isPartnerShell(shell) then return "run" end
        return original(shell, ...)
    end
    M.jogWrapped = true
    return true
end

function M.registerModule()
    local A = AL()
    local reg = A and A.ModuleRegistry
    if not reg or type(reg.register) ~= "function" then return false end
    if reg.modules and reg.modules[M.MODULE] then return true end
    local ok, done, why = pcall(reg.register, {
        id = M.MODULE, label = "Golf partner", kind = "orders", priority = 5, defaultEnabled = true,
        summary = "Project Golf: plays a round of golf with a player (follows them, walks to their own ball).",
        evaluate = function(actor, shell, context) return M.evaluate(actor, shell, context) end,
    })
    if not ok or not done then PGA.log("module refused:", ok and why or done) return false end
    -- every behaviour profile may run it (it does nothing unless the NPC is someone's partner)
    local profiles = A.BehaviorProfiles
    if profiles and type(profiles.definitions) == "table" then
        for _, d in ipairs(profiles.definitions) do
            if type(d.overlays) == "table" then d.overlays[M.MODULE] = true end
        end
    end
    if A.ModuleRules then A.ModuleRules.optInCache = nil end
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Talk: the Golf tab
-- ---------------------------------------------------------------------------------------------------------------
local function nameOf(record)
    if type(record) ~= "table" then return nil end
    local names = AL() and AL().Names
    local n
    if names and type(names.of) == "function" then
        local ok, got = pcall(names.of, record)
        if ok then n = got end
    end
    if type(n) == "table" then n = n.first or n.firstName or n.full or n.name end
    return type(n) == "string" and n ~= "" and n or nil
end

local function sayTo(shell, player, text)
    local speech = AL() and AL().Speech
    if speech and type(speech.say) == "function" and shell then pcall(speech.say, shell, text, { face = player }) end
    return text, "answered"
end

function M.onInvite(record, shell, player, context)
    if type(record) ~= "table" or not record.uid then return nil end
    if type(context) == "table" and context.stance == "careful" then
        return sayTo(shell, player, "Golf? I don't know you well enough to turn my back on you.")
    end
    local mine = M.matchOf(player)
    if mine and mine.uid == record.uid then return sayTo(shell, player, "We're already playing. Your shot.") end
    if not PGA.hasClub(player) then return sayTo(shell, player, "Golf? You haven't even got a club.") end
    local m = M.start(record.uid, player, nameOf(record))
    return sayTo(shell, player, "Golf? Out here? ...Why not. " .. M.golferLine(m.golfer) .. " Lead the way.")
end

-- "Go ahead, take your shot.": they play their next shot now instead of waiting for yours. On a tee box before
-- anyone has teed off, that starts the hole with them going first.
function M.onGoAhead(record, shell, player)
    local m = type(record) == "table" and M.matches[record.uid] or nil
    if not m then return nil end
    if m.phase ~= "follow" then return sayTo(shell, player, "I'm on it, hang on.") end
    if not m.hole or (m.holed and m.pHoled) then
        local px, py = posOf(player)
        local teeHole = px and PG.Courses.teeAt(px, py) or nil
        if not (teeHole and teeHole.tee) then return sayTo(shell, player, "Let's find a tee box first.") end
        M.startHole(m, teeHole)
    end
    if m.holed then return sayTo(shell, player, "I'm already in. All yours.") end
    if not m.ball then return sayTo(shell, player, "I've lost track of my ball...") end
    m.nextTurnAt = now() + 500
    m.playOut = true                          -- they play the hole out, shot after shot, without waiting for you
    return sayTo(shell, player, "Alright, I'll play it out. Watch and learn.")
end

function M.onStop(record, shell, player)
    if type(record) ~= "table" or not M.matches[record.uid] then return nil end
    M.stop(record.uid, "asked")
    return sayTo(shell, player, "Good game. Same time tomorrow, if we're still alive.")
end

function M.registerTalk()
    local talk = AL() and AL().Talk
    if not talk or type(talk.choiceHandlers) ~= "table" then return false end
    talk.choiceHandlers[PGA.Choice.invite] = function(record, shell, player, context) return M.onInvite(record, shell, player, context) end
    talk.choiceHandlers[PGA.Choice.goAhead] = function(record, shell, player) return M.onGoAhead(record, shell, player) end
    talk.choiceHandlers[PGA.Choice.stop] = function(record, shell, player) return M.onStop(record, shell, player) end
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Test spawn: a friendly A-Life NPC next to you, with a golf club and balls, who is your partner straight away.
-- Single player, or admins in multiplayer.
-- ---------------------------------------------------------------------------------------------------------------
function M.mayTestSpawn(player)
    if not isServer() then return true end
    local level = try(player, "getAccessLevel")
    return level ~= nil and level ~= "" and level ~= "None" and level ~= "none"
end

-- A peaceable faction's member who fights back (elders skip behaviour modules), preferring civilians.
function M.friendlyProfileId()
    local A = AL()
    local catalog = A and A.Catalog
    if not catalog then return nil end
    local current = catalog.current or (type(catalog.load) == "function" and catalog.load()) or nil
    if type(current) ~= "table" then return nil end
    local progression = A.LoadoutProgression
    local best, bestScore
    for _, profile in ipairs(current.npcOrder or {}) do
        local fid = profile.general and profile.general.faction
        local faction = fid and catalog.faction(fid)
        local spawn = type(faction) == "table" and faction.spawn or nil
        if type(spawn) == "table" and spawn.peaceable == true and spawn.visitorOnly ~= true then
            local elder = progression and type(progression.noncombat) == "function" and progression.noncombat(profile)
            if not elder then
                local text = string.lower(tostring(profile.id) .. " " .. tostring(fid))
                local score = (string.find(text, "civil", 1, true) and 2 or 0) + (string.find(text, "surviv", 1, true) and 1 or 0)
                if not bestScore or score > bestScore then best, bestScore = profile.id, score end
            end
        end
    end
    return best
end

function PGA.ServerCommands.SpawnPartner(player, args)
    local function tell(text) PG.sendToPlayer(player, "Notice", { text = text }) end
    if not PGA.testSpawnEnabled() then return tell("Golf partner: test spawn is off (sandbox: Project Golf x A-Life)") end
    if not M.mayTestSpawn(player) then return tell("Golf partner: admins only on a server") end
    local service = AL() and AL().DebugService
    if not service or type(service.spawnEncounter) ~= "function" then return tell("Golf partner: A-Life isn't running") end
    local profileId = M.friendlyProfileId()
    if not profileId then return tell("Golf partner: no friendly A-Life profile found") end
    local x, y, z = posOf(player)
    local ok, accepted, reason = pcall(service.spawnEncounter, player, {
        -- playerKeepOut = 0: A-Life's spawn tool otherwise keeps NPCs 40 tiles from every player
        profileIds = { profileId }, count = 1, mode = "roam", distance = 3, persistent = true, playerKeepOut = 0,
        requestId = "projectgolf-partner:" .. tostring(now()),
    }, true)
    if not ok or not accepted then
        PGA.log("spawn refused:", ok and reason or accepted)
        return tell("Golf partner: A-Life refused the spawn (" .. tostring(ok and reason or "error") .. ")")
    end
    M.pendingSpawn = { player = player, x = x, y = y, untilMs = now() + 30000 }
    tell("Golf partner on the way...")
end

-- A golfer's outfit for the test partner: the game's own golf hat, a polo shirt, sometimes an argyle sweater vest,
-- slacks, ankle socks and shoes, in colours picked from who they are (the same person always dresses the same).
-- Handed to A-Life's wardrobe (memory.dress, as it does for visitors): A-Life dresses them and keeps them dressed.
M.golfClothes = {
    polo  = { "0.95,0.95,0.95", "0.62,0.78,0.95", "0.95,0.70,0.78", "0.95,0.90,0.60", "0.62,0.85,0.66" },
    vest  = { "0.16,0.20,0.38", "0.55,0.12,0.15", "0.15,0.35,0.22", "0.85,0.85,0.85" },
    pants = { "0.85,0.78,0.60", "0.95,0.95,0.93", "0.22,0.26,0.40", "0.55,0.55,0.55" },
    shoes = { "Base.Shoes_Brown", "Base.Shoes_Black", "Base.Shoes_TrainerTINT" },
}

function M.golferOutfit(uid)
    local rng = PG.newRng(hashOf(uid, 97))
    local function pick(list) return list[math.floor(rng:next() * #list) + 1] end
    local G = M.golfClothes
    local list = {
        { "Base.Hat_GolfHat", "" },
        { "Base.Tshirt_PoloTINT", pick(G.polo) },
        { "Base.Trousers_WhiteTINT", pick(G.pants) },
        { "Base.Socks_Ankle", "" },
    }
    local shoes = pick(G.shoes)
    list[#list + 1] = { shoes, shoes == "Base.Shoes_TrainerTINT" and "0.95,0.95,0.95" or "" }
    if rng:next() < 0.5 then list[#list + 1] = { "Base.Jumper_TankTopDiamondTINT", pick(G.vest) } end
    return list
end

function M.dressAsGolfer(uid)
    local talk = AL() and AL().Talk
    if not talk or type(talk.writeMemory) ~= "function" then return false end
    local outfit = M.golferOutfit(uid)
    return talk.writeMemory(uid, function(memory)
        local rev = type(memory.dress) == "table" and tonumber(memory.dress.rev) or 0
        memory.dress = { list = outfit, rev = rev + 1 }
    end)
end

-- Kit them out: the club in hand (their weapon too) and a couple of balls in the bag.
function M.kitOut(shell)
    local inv = try(shell, "getInventory")
    if not inv then return end
    local club = try(inv, "getFirstTypeRecurse", PG.Items.Club) or try(inv, "AddItem", PG.Items.Club)
    try(inv, "AddItem", PG.Items.Ball)
    try(inv, "AddItem", PG.Items.Ball)
    local weapons = AL() and AL().Weapons
    if club and weapons and type(weapons.select) == "function" then pcall(weapons.select, shell, club, "melee") end
end

function M.onNpcSpawned(body, uid)
    local p = M.pendingSpawn
    if not p or type(uid) ~= "string" then return end
    if now() > p.untilMs then M.pendingSpawn = nil return end
    local bx, by = posOf(body)
    if not bx or dist(bx, by, p.x, p.y) > 30 then return end
    M.pendingSpawn = nil
    M.kitOut(body)
    M.dressAsGolfer(uid)                -- a test partner always turns up dressed for golf
    local reg = AL() and AL().ActorRegistry
    local record = reg and type(reg.peek) == "function" and reg.peek(uid) or nil
    local m = M.start(uid, p.player, nameOf(record))
    m.debug = true                      -- a test partner: full trust, kept up for the whole round
    M.fullOpinion(m)
    M.say(m, "Heard there's a golfer around here. " .. M.golferLine(m.golfer) .. " Show me the first tee!", p.player)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Install (A-Life's server files may load after ours: try now, and again at game start)
-- ---------------------------------------------------------------------------------------------------------------
function M.install()
    M.wrapHit()
    local a = M.registerModule()
    local b = M.registerTalk()
    if not M.spawnHooked and Events and Events.ProjectALife_NpcSpawned then
        Events.ProjectALife_NpcSpawned.Add(function(body, uid) pcall(M.onNpcSpawned, body, uid) end)
        M.spawnHooked = true
    end
    local c = M.protectSquads()
    M.jogOnly()
    M.ready = a and b and c and M.spawnHooked == true
    return M.ready
end

local function onClientCommand(module, command, player, args)
    if module ~= PGA.MOD_ID then return end
    local h = PGA.ServerCommands[command]
    if h then h(player, args) end
end

M.install()
Events.OnGameStart.Add(function() if not M.ready then M.install() end end)
Events.OnServerStarted.Add(function() if not M.ready then M.install() end end)
Events.OnTick.Add(function() M.onTick() end)
Events.OnClientCommand.Add(onClientCommand)
