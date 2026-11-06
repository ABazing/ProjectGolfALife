next = nil  -- Project Zomboid's Lua has no next()
-- ---------- A-Life stubs ----------
function instanceItem(t) INST = (INST or 500) + 1; local it = newItem(t, INST); it.setName = function(self, n) self.name = n end; return it end
local spoken, applied, notices = {}, {}, {}
local SHELL; SHELL = { x = 12.5, y = 12.5, z = 0, inv = {}, getModData = function() return { ProjectALifeUID = "npc-1" } end,
  getX = function() return SHELL.x end, getY = function() return SHELL.y end, getZ = function() return SHELL.z end,
  getInventory = function() return { getFirstTypeRecurse = function() return nil end,
     AddItem = function(_, t) local it = newItem(t, 1); table.insert(SHELL.inv, t); return it end } end }
local registered, profiles = {}, { definitions = { { id = "a", overlays = {} }, { id = "b", overlays = {} } } }
local intents = { choices = {}, groups = {} }
function intents.addGroup(g) table.insert(intents.groups, g) return true end
function intents.addChoice(c) table.insert(intents.choices, c) return true end
local anims = { presets = {} }
function anims.supports(id) return anims.presets[id] ~= nil end
function anims.registerPreset(p) anims.presets[p.id] = p return true end
function anims.apply(shell, id) table.insert(applied, id) return true end
local socialRows = { cats = {} }
function socialRows.put(cat, ids) for id in string.gmatch(ids, "%S+") do socialRows.cats[id] = cat end end
local spawnArgs
NPC_RECORD = { uid = "npc-1", lifecycle = "active", factionId = "ward",
  memory = { squadId = "squad:26", hostileToPlayerKeys = { ["sp:0"] = true }, carefulPlayerKeys = { ["sp:0"] = 1e15 } } }
ProjectALife = {
  TalkIntents = intents, Animations = anims, TalkSocialRows = socialRows,
  Talk = { choiceHandlers = {}, shellFor = function(uid) return uid == "npc-1" and SHELL or nil end,
    writeMemory = function(uid, f) if uid == "npc-1" then f(NPC_RECORD.memory) return true end return false end },
  Speech = { say = function(_, text) table.insert(spoken, text) return true end, face = function() return true end },
  ModuleRegistry = { modules = {}, register = function(d) registered[d.id] = d; ProjectALife.ModuleRegistry.modules[d.id] = d return true end },
  BehaviorProfiles = profiles,
  ActorRegistry = { peek = function(uid) if uid == "npc-1" then return NPC_RECORD end end },
  Reputation = { TAG = "rep", playerKey = function() return "sp:0" end, sync = function() REP_SYNCED = true end,
    storage = { players = { ["sp:0"] = { ward = { status = "hostile", cause = "kill" }, other = { status = "hostile" } } } } },
  RenderProtocol = { canRetask = function() return true end },
  NpcOpinion = { keyOf = function() return "sp:0" end, hours = function() return 123 end,
    write = function(uid, f) if uid == "npc-1" then f(NPC_RECORD.memory) return true end return false end },
  Gait = { grantBurst = function(actor, shell, target, now, gap, floor) BURSTS = (BURSTS or 0) + 1; LASTBURSTGAP = gap; return gap > floor end,
    burstPace = function() return "sprint" end },
  Names = { of = function() return "Dave Miller" end },
  Weapons = { select = function() WEAPON = true return true end },
  Catalog = { current = { npcOrder = {
      { id = "raider_1", general = { faction = "raiders" } },
      { id = "civilian_old", general = { faction = "civ" } },
      { id = "civilian_1", general = { faction = "civ" } } } },
    faction = function(id) if id == "civ" then return { spawn = { peaceable = true } } end return { spawn = {} } end },
  LoadoutProgression = { noncombat = function(p) return p.id == "civilian_old" end },
  DebugService = { spawnEncounter = function(player, args, admin) spawnArgs = args return true, nil, {} end },
}
Events.ProjectALife_NpcSpawned = Events.ProjectALife_NpcSpawned
local media2 = arg[2]
package.path = media2 .. "/lua/shared/?.lua;" .. media2 .. "/lua/client/?.lua;" .. media2 .. "/lua/server/?.lua;" .. package.path
for _, f in ipairs{ "ProjectGolf/PG_Config", "ProjectGolf/PG_Physics", "ProjectGolf/PG_World", "ProjectGolf/PG_Net",
  "ProjectGolf/PG_Viewpoint", "ProjectGolf/PG_Options", "ProjectGolf/PG_Render", "ProjectGolf/PG_AimUI", "ProjectGolf/PG_StanceAction",
  "ProjectGolf/PG_Client", "ProjectGolf/PG_ContextMenu", "ProjectGolf/PG_Server",
  "ProjectGolfALife/PGA_Shared", "ProjectGolfALife/PGA_Planner", "ProjectGolfALife/PGA_Server", "ProjectGolfALife/PGA_Client" } do require(f) end
local PG, PGA = ProjectGolf, ProjectGolfALife
PGA.DEBUG = true
local M = PGA.Server
local ok, bad = 0, 0
local function check(n, c) print((c and "PASS  " or "FAIL  ") .. n); if c then ok = ok + 1 else bad = bad + 1 end end
local origNotice = PG.ClientCommands.Notice
PG.ClientCommands.Notice = function(a) table.insert(notices, a.text) return origNotice(a) end

check("swing preset registered with a golf club prop", anims.presets.pg_golf_swing and anims.presets.pg_golf_swing.prop == "Base.Golfclub")
check("golf lines never count as repeated questions", socialRows.cats.PGA_GOLF_GO_AHEAD == "order"
  and socialRows.cats.PGA_GOLF_INVITE == "order" and socialRows.cats.PGA_GOLF_STOP == "order")
check("Golf tab: invite, go ahead and stop rows", #intents.choices == 3 and intents.groups[1].id == "Golf")
check("behaviour module registered (orders, first)", registered.golfPartner and registered.golfPartner.kind == "orders" and registered.golfPartner.priority == 5)
check("every profile may run it", profiles.definitions[1].overlays.golfPartner and profiles.definitions[2].overlays.golfPartner)
check("talk handlers installed", type(ProjectALife.Talk.choiceHandlers.PGA_GOLF_INVITE) == "function")
check("Hit wrapped", M.hitWrapped)
local view = { record = { uid = "npc-1" }, player = PLAYER }
INV_ITEMS = {}
check("no club: no invite", not intents.choices[1].show(view) and not PGA.hasClub(PLAYER) and not PGA.hasClub(nil))
local noClub = ProjectALife.Talk.choiceHandlers.PGA_GOLF_INVITE({ uid = "npc-1" }, SHELL, PLAYER, {})
check("no club: invite refused on the server: " .. tostring(noClub), tostring(noClub):find("club") ~= nil and M.matches["npc-1"] == nil)
INV_ITEMS = { newItem(ProjectGolf.Items.Club, 950) }
check("club on you: invite shown", PGA.hasClub(PLAYER))
check("invite shown before a round", intents.choices[1].show(view) and not intents.choices[2].show(view) and not intents.choices[3].show(view))

-- a little test course in the mock world: tee at 10,10, cup (a placed flag) at 30,40
PG.Courses.list = { { id = "T", name = "Test", short = "Test", bounds = { 0, 0, 59, 59 },
  holes = { { number = 1, par = 4, cup = { x = 30, y = 40, z = 0 }, tee = { x = 10, y = 10 } } } } }
PG.Courses.list[1].holes[1].course = PG.Courses.list[1]
local flag = newItem("ProjectGolf.GolfFlag", 5)
sqAt(30, 40, 0):AddWorldInventoryItem(flag, 0.5, 0.5, 0)

-- spawn: picks the civilian who fights (not the elder), then the spawned NPC becomes the partner, kitted out
-- the test spawn is a sandbox option, off by default
local nBefore = #notices
PGA.ServerCommands.SpawnPartner(PLAYER, {})
check("test spawn off by default: refused", spawnArgs == nil and notices[#notices] and notices[#notices]:find("test spawn is off", 1, true) ~= nil)
local menuOpts = 0
local fakeCtx = { addOption = function() menuOpts = menuOpts + 1; return {} end, addSubMenu = function() end }
ISContextMenu.getNew = function() return { addOption = function() return {} end } end
for _, f in ipairs(handlers.OnFillWorldObjectContextMenu or {}) do pcall(f, 0, fakeCtx, {}, false) end
local offOpts = menuOpts
SandboxVars = SandboxVars or {}
SandboxVars.ProjectGolfALife = { TestPartnerSpawn = true }
menuOpts = 0
for _, f in ipairs(handlers.OnFillWorldObjectContextMenu or {}) do pcall(f, 0, fakeCtx, {}, false) end
check("...and its menu only shows when the sandbox option is on", menuOpts > offOpts)
PGA.ServerCommands.SpawnPartner(PLAYER, {})
check("test spawn asks A-Life for a friendly civilian, right next to you", spawnArgs and spawnArgs.profileIds[1] == "civilian_1" and spawnArgs.persistent == true and spawnArgs.playerKeepOut == 0)
M.onNpcSpawned(SHELL, "npc-1")
check("spawned NPC is your partner", M.matches["npc-1"] ~= nil and PGA.myPartner == "npc-1")
check("kitted out: club in hand, two balls", WEAPON and #SHELL.inv == 3)
local dress = NPC_RECORD.memory.dress
local types = {}
for _, row in ipairs(dress and dress.list or {}) do types[#types + 1] = row[1] end
print("  outfit: " .. table.concat(types, ", "))
check("dressed as a golfer (A-Life's wardrobe keeps it on)", dress and dress.rev == 1 and types[1] == "Base.Hat_GolfHat"
  and types[2] == "Base.Tshirt_PoloTINT" and types[3] == "Base.Trousers_WhiteTINT")
local o1, o2 = M.golferOutfit("palife:9:9"), M.golferOutfit("palife:9:9")
check("the same golfer always wears the same", o1[2][2] == o2[2][2] and #o1 == #o2)
check("go ahead and stop shown during a round", intents.choices[2].show(view) and intents.choices[3].show(view) and not intents.choices[1].show(view))
check("partner goes by their first name", M.matches["npc-1"].name == "Dave")
local mem = NPC_RECORD.memory
check("partner is forced friendly", mem.hostileOverride == false)
check("test partner trusts you fully (A-Life opinion 100)", mem.opinion and mem.opinion["sp:0"] and mem.opinion["sp:0"].v == 100)
mem.opinion["sp:0"].v = 10
clock = clock + 6000; M.onTick()
check("...and keeps trusting you through the round", mem.opinion["sp:0"].v == 100)
check("their grudges against you are gone", mem.hostileToPlayerKeys["sp:0"] == nil and mem.carefulPlayerKeys["sp:0"] == nil)
check("they tolerate you", (mem.tolerateUntil["sp:0"] or 0) > clock + 3600000)
local repPlayers = ProjectALife.Reputation.storage.players["sp:0"]
check("your hostile standing with their faction is cleared", repPlayers.ward == nil and REP_SYNCED)
check("...and only with their faction", repPlayers.other ~= nil)
check("their group gets no new trips during the round", ProjectALife.RenderProtocol.canRetask({ id = "squad:26" }) == false)
check("other groups still do", ProjectALife.RenderProtocol.canRetask({ id = "squad:99" }) == true)
mem.hostileToPlayerKeys["sp:0"] = true; repPlayers.ward = { status = "hostile", cause = "attack" }
clock = clock + 6000; M.onTick()
check("a hit mid-round is forgiven within seconds", mem.hostileToPlayerKeys["sp:0"] == nil and repPlayers.ward == nil)

-- the loop: the behaviour module moves the shell (A-Life's movement stand-in), the tick runs the turns
local actor = { uid = "npc-1" }
local function startMovement(a, shell, target, intent, opts)
  local dx, dy = target.x - shell.x, target.y - shell.y
  local d = math.sqrt(dx * dx + dy * dy)
  local step = math.min(d, 0.6)
  if d > 0 then shell.x, shell.y = shell.x + dx / d * step, shell.y + dy / d * step end
  LASTMOVE = intent
  return { kind = "movement", intent = intent }
end
local function run(ms)
  for _ = 1, ms / 100 do
    clock = clock + 100
    M.evaluate(actor, SHELL, { now = clock, startMovement = startMovement })
    M.onTick()
    for _, f in ipairs(handlers.OnTick or {}) do pcall(f) end
  end
end

-- you tee off on hole 1
local ball = newItem("Base.GolfBall", 77)
sqAt(10, 10, 0):AddWorldInventoryItem(ball, 0.5, 0.5, 0)
local flightsBefore = #PG.Client.flights
PG.ServerCommands.Hit(PLAYER, { shot = "drive", power = 0.5, yaw = 60, x = 10, y = 10, z = 0, id = 77 })
local m = M.matches["npc-1"]
check("your tee shot starts the hole for both", m.hole ~= nil and m.pStrokes == 1 and m.ball and m.ball.tee)
check("your flight is still yours", PG.Client.flights[flightsBefore + 1] and PG.Client.flights[flightsBefore + 1].mine == true)
local teeX, teeY = m.ball.x, m.ball.y
check("their tee spot is between the markers (0.9 from the centre, markers at 2)", math.abs(math.sqrt((teeX - 10.5) ^ 2 + (teeY - 10.5) ^ 2) - 0.9) < 0.01)
do
  local hole1 = PG.Courses.list[1].holes[1]
  local cupT = { x = 30.5, y = 40.5 }
  local ax, ay = cupT.x - 10.5, cupT.y - 10.5
  local len = math.sqrt(ax * ax + ay * ay)
  local nx, ny = -ay / len, ax / len
  local function side(p) return (p.x - 10.5) * nx + (p.y - 10.5) * ny end
  local right = M.teeSpot(hole1, cupT, { x = 10.5 + nx * 1.2, y = 10.5 + ny * 1.2 })
  local left = M.teeSpot(hole1, cupT, { x = 10.5 - nx * 1.2, y = 10.5 - ny * 1.2 })
  check("you tee on one half: they take the other", side(right) < 0 and side(left) > 0)
  local zr = ZombRand
  ZombRand = function() return 0 end; local a = M.teeSpot(hole1, cupT, nil)
  ZombRand = function() return 1 end; local b = M.teeSpot(hole1, cupT, nil)
  ZombRand = zr
  check("they tee off first: either half, not always the same", side(a) * side(b) < 0)
end
run(20000)
check("they walked to their ball", LASTMOVE == "golf_walk" or m.strokes > 0)
check("addressed and swung", applied[1] == "pg_golf_swing")
check("their tee shot was played", m.strokes == 1)
local theirs
for i = flightsBefore + 1, #PG.Client.flights do if PG.Client.flights[i].mine == false then theirs = PG.Client.flights[i] end end
check("their flight plays for everyone, not counted as yours", theirs ~= nil and (md.ProjectGolf == nil or (md.ProjectGolf.strokes or 0) <= 1))
check("their tee shot heads for the cup (closer than the tee)", m.holed or (m.ball and math.sqrt((m.ball.x - 30.5) ^ 2 + (m.ball.y - 40.5) ^ 2) < 33))
check("their ball is a real golf ball on the ground", m.holed or (m.ballItem and m.ballItem:getWorldItem() ~= nil))
check("...named after them", m.holed or (m.ballItem and m.ballItem.name == "Dave's golf ball"))
check("back to following you", m.phase == "follow")
run(10000)
check("they wait for your next shot", m.strokes == 1)

-- following: stop short of you on their side, jog when far, sprint lease when very far
local fs = M.followSpot(10, 10, 0, 20, 10)
check("follow stops 2 tiles short, on their side", math.abs(fs.x - 12) < 0.01 and fs.y == 10)
check("walks when close, jogs when far", M.paceFor(4) == "walk" and M.paceFor(8) == "run")
BURSTS = 0
check("no hurry when close", M.hurry(m, SHELL, 4, clock) == false and BURSTS == 0)
check("jogs once more than 6 behind (fast-pace lease)", M.hurry(m, SHELL, 8, clock) == true)
check("partners jog, never sprint", ProjectALife.Gait.burstPace(SHELL) == "run")
check("other NPCs keep A-Life's own pace", ProjectALife.Gait.burstPace({ getModData = function() return { ProjectALifeUID = "someone-else" } end }) == "sprint")
-- a follow walk is short so a moving player gets chased where they are now
local opts; local spyStart = function(a, sh, target, intent, o) opts = o; FOLLOWTARGET = target; return { kind = "movement" } end
local savedX2 = SHELL.x; SHELL.x = PLAYER:getX() + 20
m.phase = "follow"
M.evaluate(actor, SHELL, { now = clock, startMovement = spyStart })
check("follow walk re-aims every 2.5 s, jogging", opts and opts.timeoutMs == 2500 and opts.pace == "run")
check("...to a spot 2 tiles from you", FOLLOWTARGET and math.abs(FOLLOWTARGET.x - (PLAYER:getX() + 2)) < 0.01)
SHELL.x = savedX2
-- partner falls behind: logged once with the reason
local savedX = SHELL.x; SHELL.x = SHELL.x + 40
local logged = {}; local plog = PGA.log; PGA.log = function(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end logged[#logged + 1] = table.concat(t, " ") return plog(...) end
local noMove = function() return nil end
for _ = 1, 100 do clock = clock + 100; M.onTick() end
PGA.log = plog; SHELL.x = savedX
local lagLine; for _, l in ipairs(logged) do if string.find(l, "not following", 1, true) then lagLine = l end end
check("falling behind is logged with A-Life's reason", lagLine ~= nil and string.find(lagLine, "squad=squad:26", 1, true) ~= nil)
-- you hole out (pretend): they play on until they're in or pick up
M.onPlayerShot(PLAYER, { x0 = 29, y0 = 39, result = "cup", cupX = 30, cupY = 40, cupZ = 0, duration = 1 })
check("your hole-out is counted", m.pHoled and m.pStrokes == 2)
run(120000)
check("they finished the hole", m.hole == nil)
check("hole result shown to you", notices[#notices] and string.find(notices[#notices], "Hole 1:  you 2", 1, true) ~= nil)
check("...with their first name only", string.find(notices[#notices], "Dave ", 1, true) ~= nil and string.find(notices[#notices], "Miller", 1, true) == nil)
local startNotice
for _, n in ipairs(notices) do if string.find(n, "golf rating", 1, true) then startNotice = n end end
check("the round's start notice uses their first name", startNotice and startNotice:find("^Dave %- golf rating") ~= nil)
print("  " .. tostring(notices[#notices]))
print("  partner said: " .. table.concat(spoken, " | "))
check("their ball is cleaned up", m.ballItem == nil)
-- their score is on your card
local pdata = PLAYER:getModData().ProjectGolfALife
local pc = pdata and pdata.cards and pdata.cards.T
check("their score lands on your scorecard", pc and pc.name == "Dave" and pc.holes[1] and pc.holes[1].last == m.strokes)
-- the card draws a column for them
PG.Client.recordScore(PLAYER, PG.Courses.list[1].holes[1], 2)
local texts = {}
local origCentre, origText = ISUIElement.drawTextCentre, ISUIElement.drawText
ISUIElement.drawTextCentre = function(_, t) texts[#texts + 1] = t end
ISUIElement.drawText = function(_, t) texts[#texts + 1] = t end
local win = PG_GuideWindow:new(PLAYER); win.contentTop = 40; win.width = 480
win:renderCard("T")
ISUIElement.drawTextCentre, ISUIElement.drawText = origCentre, origText
local all = table.concat(texts, "|")
print("  card: " .. all)
check("scorecard lists only their first name", string.find(all, "Miller", 1, true) == nil)
check("scorecard has their column, headed with their name and golf rating", string.find(all, "|Dave (" .. m.golfer.rating .. ")|", 1, true) ~= nil and string.find(all, "|You|", 1, true) ~= nil)
check("their total and the match line", string.find(all, "Match: you won", 1, true) ~= nil)
-- New card clears theirs too
PG.Client.newScorecard(PLAYER, "T")
check("a new card clears their scores too", pc.holes[1].last == nil)

-- "go ahead": off a tee box with no hole going, they say so
local goAhead = ProjectALife.Talk.choiceHandlers.PGA_GOLF_GO_AHEAD
local gx = PLAYER.getX; PLAYER.getX = function() return 40 end
local said1 = goAhead({ uid = "npc-1" }, SHELL, PLAYER, {})
PLAYER.getX = gx
check("go ahead off the tee: let's find a tee box", said1 == "Let's find a tee box first." and m.hole == nil)
-- on the tee (the player stands at 10,10.5 = the test tee): they tee off first, without you hitting
local strokesBefore = m.strokes
local said2 = goAhead({ uid = "npc-1" }, SHELL, PLAYER, {})
check("go ahead on the tee starts the hole with them first", m.hole ~= nil and m.pStrokes == 0 and said2 == "Alright, I'll play it out. Watch and learn.")
check("go ahead: they'll play it out", m.playOut == true and string.find(said2, "play it out", 1, true) ~= nil)
local moves = {}
local spyMove = function(a, sh, target, intent, o) moves[intent] = (moves[intent] or 0) + 1 return startMovement(a, sh, target, intent, o) end
for _ = 1, 1200 do                                   -- two minutes, you never hit
  clock = clock + 100
  M.evaluate(actor, SHELL, { now = clock, startMovement = spyMove })
  M.onTick()
  if m.holed then break end
end
check("...they play the whole hole out without waiting for you", m.holed and m.pStrokes == 0)
check("...walking ball to ball, never back to follow you", (moves.golf_walk or 0) > 0 and (moves.golf_follow or 0) == 0)
check("...then they're back to normal", m.playOut == false)
print("  played it out in " .. m.strokes .. (m.picked and " (picked up)" or ""))
-- your tee shot on the same hole doesn't restart it
local ball2 = newItem("Base.GolfBall", 78)
sqAt(10, 10, 0):AddWorldInventoryItem(ball2, 0.5, 0.5, 0)
clock = clock + 5000
local their = m.strokes
PG.ServerCommands.Hit(PLAYER, { shot = "drive", power = 0.5, yaw = 60, x = 10, y = 10, z = 0, id = 78 })
check("your tee shot after theirs keeps the hole going (they're already in)", m.hole ~= nil and m.pStrokes == 1 and m.strokes == their)
-- ---------- golf rating ----------
local g1, g2 = M.golferOf("palife:1:4"), M.golferOf("palife:1:4")
check("same NPC, same golf rating", g1.rating == g2.rating and g1.strength == g2.strength)
local counts, lowStr, highStr, nLow, nHigh, lowOver, highOver = {}, 0, 0, 0, 0, 0, 0
for i = 1, 2000 do
  local g = M.golferOf("palife:" .. (1793820000000 + i * 7919) .. ":" .. i)
  counts[g.rating] = (counts[g.rating] or 0) + 1
  if g.rating <= 3 then lowStr = lowStr + g.strength; nLow = nLow + 1; lowOver = lowOver + g.overswing end
  if g.rating >= 8 then highStr = highStr + g.strength; nHigh = nHigh + 1; highOver = highOver + g.overswing end
  assert(g.rating >= 1 and g.rating <= 10 and g.aiming == g.rating and g.strength >= 0 and g.strength <= 10)
end
local line = {}
for r = 1, 10 do line[#line + 1] = r .. ":" .. (counts[r] or 0) end
print("  ratings over 2000 NPCs: " .. table.concat(line, " "))
check("every rating from 1 to 10 turns up", (function() for r = 1, 10 do if not counts[r] then return false end end return true end)())
check("most are middling, 1s and 10s are rare", (counts[5] or 0) + (counts[6] or 0) > 4 * ((counts[1] or 0) + (counts[10] or 0)))
check("better golfers hit further (Strength)", highStr / nHigh > lowStr / nLow + 2)
check("better golfers overswing less", highOver / nHigh < lowOver / nLow / 2)
check("their Strength carries their test shots too", PGA.Planner.multFor("drive", 8) > PGA.Planner.multFor("drive", 3)
  and PGA.Planner.multFor("putt", 8) == PGA.Planner.multFor("putt", 3))
-- overswings: past the red line, with your spray and mishit rules, the overhit sound for everyone
local saveG = m.golfer
m.golfer = { rating = 2, aiming = 2, strength = 4, overswing = 1 }
m.ball = { x = 10.5, y = 10.5, z = 0 }; m.cup = { x = 40.5, y = 40.5, z = 0 }
m.plan = PGA.Planner.solve(m.ball, m.cup, m.golfer.strength)
local over, mis = 0, 0
for i = 1, 40 do
  local pl = M.planShot(m, PG.newRng(1000 + i))
  if pl.overswung then over = over + 1 end
  if pl.mishit then mis = mis + 1 end
end
check("a golfer who always overswings goes past the red line", over == 40)
check("...and sometimes mishits it, like you would", mis > 0 and mis < 40)
m.golfer = { rating = 10, aiming = 10, strength = 8, overswing = 0 }
local clean = 0
for i = 1, 40 do if not M.planShot(m, PG.newRng(2000 + i)).overswung then clean = clean + 1 end end
check("a golfer who never overswings stays under it", clean == 40)
local flights = #PG.Client.flights
m.golfer = { rating = 2, aiming = 2, strength = 4, overswing = 1 }
m.plan = PGA.Planner.solve(m.ball, m.cup, m.golfer.strength); m.plan.ballAt = m.ball
local pl = M.shoot(m)
local fl = PG.Client.flights[#PG.Client.flights]
check("their overswing plays the overhit sound for everyone, and isn't your mishit", pl.overswung and #PG.Client.flights > flights and fl.mine == false)
m.golfer = saveG; m.phase = "follow"; m.flight = nil
-- stop
ProjectALife.Talk.choiceHandlers.PGA_GOLF_STOP({ uid = "npc-1" }, SHELL, PLAYER, {})
check("call it a day ends the round", M.matches["npc-1"] == nil and PGA.myPartner == nil)
check("forced friendly put back after the round", mem.hostileOverride == nil)
check("their group can get trips again", ProjectALife.RenderProtocol.canRetask({ id = "squad:26" }) == true)
check("module does nothing for others", M.evaluate(actor, SHELL, { now = clock, startMovement = startMovement }) == nil)
-- careful NPCs say no
local said = ProjectALife.Talk.choiceHandlers.PGA_GOLF_INVITE({ uid = "npc-2" }, SHELL, PLAYER, { stance = "careful" })
check("a careful stranger declines", said ~= nil and M.matches["npc-2"] == nil)
-- ---------- shot planning: lies, a dogleg, the frame budget ----------
local P = PGA.Planner
local function tree(x, y) local sq = sqAt(x, y, 0); table.insert(sq.objs, { _class = "IsoTree",
  getSprite = function() return { getName = function() return "vegetation_trees_01_11" end } end }) end
local function roughAt(x, y) local sq = sqAt(x, y, 0); table.insert(sq.objs, { _class = "IsoObject",
  getSprite = function() return { getName = function() return "blends_grassoverlays_01_3" end } end }) end
roughAt(5, 50); tree(6, 50)
check("lie: mown grass is fairway", P.lieAt(5.5, 45.5, 0) == "fairway")
check("lie: grass overlay is rough", P.lieAt(5.5, 50.5, 0) == "rough")
check("lie: trees", P.lieAt(6.5, 50.5, 0) == "trees")
-- dogleg: tee 8,8, cup 50,8, a belt of trees x 22-25 from the top down to y 16: the straight line is blocked
for x = 22, 25 do for y = 0, 16 do tree(x, y) end end
local flag2 = newItem("ProjectGolf.GolfFlag", 6)
sqAt(50, 8, 0):AddWorldInventoryItem(flag2, 0.5, 0.5, 0)
local tee, cup2 = { x = 8.5, y = 8.5, z = 0 }, { x = 50.5, y = 8.5, z = 0 }
local t0 = os.clock()
local plan = P.solve(tee, cup2)
local spent = (os.clock() - t0) * 1000
local straight = PG.simulate({ x = tee.x, y = tee.y, z = 0, shot = plan.shot, power = plan.flagPower, yaw = plan.aimYaw,
  distanceMult = plan.mult, seed = 7, maxTime = 12 }, PG.GameWorld)
print(string.format("  dogleg: %d test shots in %.0f ms here; straight at the flag ends %s (%.1f,%.1f); picked yaw %+.1f (flag %+.1f) power %.2f -> %s, %.1f left",
  plan.tried, spent, P.lieAt(straight.final.x, straight.final.y, 0), straight.final.x, straight.final.y,
  plan.best.yaw, plan.aimYaw, plan.best.power, tostring(plan.best.lie), plan.best.left or -1))
print("  best final", plan.best.final.x, plan.best.final.y, "flagPower", plan.flagPower)
check("dogleg: straight at the flag runs into the trees", P.lieAt(straight.final.x, straight.final.y, 0) == "trees" or straight.final.x < 23)
check("dogleg: they play round the corner instead", plan.best.yaw > plan.aimYaw + 15 and plan.best.lie ~= "trees")
check("dogleg: and it gets them closer, with a clear look at the flag", plan.best.left < 41 and P.treesOnLine(plan.best.final.x, plan.best.final.y, 0, cup2.x, cup2.y) == 0)
check("a drive tries about 75 shots", plan.tried >= 60 and plan.tried <= 80)
-- open hole: straight is still best
local open = P.solve({ x = 8.5, y = 40.5, z = 0 }, { x = 45.5, y = 40.5, z = 0 })
check("open hole: straight at the flag", math.abs(open.best.yaw - open.aimYaw) < 8)
local putt = P.solve({ x = 47.5, y = 8.5, z = 0 }, cup2)
check("putts: straight, about 11 test shots", putt.shot == "putt" and putt.tried <= 12 and math.abs(putt.best.yaw - putt.aimYaw) < 0.01)
-- spread over frames: with a tiny budget each step does one test shot
local p2 = P.new(tee, cup2); local frames = 0
repeat frames = frames + 1 until P.step(p2, 0) or frames > 500
check("planning is spread over frames (one test shot a frame at zero budget)", frames == p2.tried and p2.best ~= nil)
print(ok .. " passed, " .. bad .. " failed")
if bad > 0 then os.exit(1) end
