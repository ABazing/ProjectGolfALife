-- Project Golf x A-Life (prototype) - shared part.
-- A friendly A-Life NPC plays a round with you at West Maple: invite them from the talk window ("Golf" tab), they
-- follow you to the tee, and after each of your shots they walk to their own ball and play it.
--
-- Shared because A-Life's talk rows and animation presets are shared tables: the client lists the rows, the server
-- answers them, and every machine needs the swing preset to play it back.

require "ProjectGolf/PG_Config"
require "ProjectGolf/PG_Net"

ProjectGolfALife = ProjectGolfALife or {}
local PGA = ProjectGolfALife

PGA.MOD_ID = "ProjectGolfALife"
PGA.VERSION = "0.1.0"

PGA.Config = PGA.Config or {
    -- Golf rating: every partner is a golfer from 1 (never held a club) to 10 (club champion). Random, but worked out
    -- from who they are, so the same person always has the same rating (nothing to save). Most people land in the
    -- middle; 1s and 10s are rare. The rating sets all three:
    --   Aiming     = the rating (how straight and how well judged their shots are, as your Aiming is for you)
    --   Strength   = strengthAt1 .. strengthAt10, give or take 1 (how far chips and drives carry, as for you)
    --   overswings = how often they go at a chip or a drive too hard, past the red line, and get the same spray and
    --                mishit chance you would: overswingAt1 .. overswingAt10 per chip or drive
    ratingMin      = 1,
    ratingMax      = 10,
    strengthAt1    = 3,
    strengthAt10   = 8,
    overswingAt1   = 0.12,   -- about one chip or drive in 8
    overswingAt10  = 0.02,   -- about one in 50
    maxOverPar     = 4,      -- they pick the ball up at par + this
    standOff       = 0.7,    -- how far beside the ball they stand to hit it (squares)
    arriveTiles    = 0.9,    -- close enough to the stand spot to address the ball
    followGap      = 3.5,    -- they come after you when further than this
    followBehind   = 2.0,    -- ...and stop this far from you, on their side (not on top of you)
    followRetargetMs = 2500, -- a follow walk is re-aimed at where you are now at least this often
    runGap         = 6,      -- further than this from where they're going: they jog (never sprint while golfing)
    addressMs      = 1200,   -- lining up before the swing
    swingDelayMs   = 520,    -- swing start to contact (the clip's downswing)
    turnDelayMs    = 1200,   -- pause after your ball stops before they go
    walkTimeoutMs  = 30000,  -- can't reach the ball in this long: drop one where they stand (+1)
    giveUpTiles    = 80,     -- you walk this far away for giveUpMs: the round ends
    giveUpMs       = 60000,
    teeSide        = 0.9,    -- their tee spot: this far to the side of the tee box centre, between the markers
                             -- (2 squares out): the other half from your ball, or a random half if they go first
}

PGA.Choice = { invite = "PGA_GOLF_INVITE", goAhead = "PGA_GOLF_GO_AHEAD", stop = "PGA_GOLF_STOP" }
PGA.SWING = "pg_golf_swing"

PGA.myPartner = PGA.myPartner or nil   -- client: uid of this player's partner (from the server)
PGA.DEBUG = PGA.DEBUG or false

function PGA.log(...)
    local parts = { "[ProjectGolfALife]" }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print(table.concat(parts, " "))
end

-- ---- sandbox (media/sandbox-options.txt, page "Project Golf x A-Life") -----------------------------------------------
-- Test partner spawn: the right-click "Golf partner (test)" option. Off by default.
function PGA.testSpawnEnabled()
    local sv = SandboxVars and SandboxVars.ProjectGolfALife
    return sv ~= nil and sv.TestPartnerSpawn == true
end

-- ---- network (same pattern as Project Golf: single player calls the handlers directly) --------------------------
PGA.ServerCommands = PGA.ServerCommands or {}
PGA.ClientCommands = PGA.ClientCommands or {}

function PGA.sendToServer(player, command, args)
    if isClient() then
        sendClientCommand(player, PGA.MOD_ID, command, args or {})
    else
        local h = PGA.ServerCommands[command]
        if h then h(player, args or {}) end
    end
end

function PGA.sendToPlayer(player, command, args)
    if isServer() then
        sendServerCommand(player, PGA.MOD_ID, command, args or {})
    else
        local h = PGA.ClientCommands[command]
        if h then h(args or {}) end
    end
end

-- ---- A-Life hooks ----------------------------------------------------------------------------------------------
-- The swing: A-Life's two-handed attack node (the same clip as Project Golf's own swing), with a golf club as the prop
-- in both hands. A one-shot, not combat (no weapon swap, no hit).
function PGA.registerPreset()
    local anims = ProjectALife and ProjectALife.Animations
    if not anims or type(anims.registerPreset) ~= "function" then return false end
    if type(anims.supports) == "function" and anims.supports(PGA.SWING) then return true end
    local ok, done, why = pcall(anims.registerPreset, {
        id = PGA.SWING, bumpType = "ALifeAttack2HA", hidden = true, timeoutMs = 1300,
        prop = ProjectGolf.Items.Club, hand = "both", handsFree = true,
    })
    if ok and done == false and why ~= "preset_duplicate" then PGA.log("swing preset refused:", why) end
    return ok and (done == true or why == "preset_duplicate")
end

-- The talk rows, in a "Golf" tab. Shown by what this client heard from the server about its partner.
local function viewUid(view)
    return type(view) == "table" and type(view.record) == "table" and view.record.uid or nil
end

-- A-Life's anti-spam (TalkSocial) answers the same question twice in 30 minutes with "I just told you that", and
-- wears out their patience if you keep at it. Golf lines are things you say every hole, so they go in A-Life's
-- "order" category, which it never counts as repeats (like "Fall in behind me" or yes / no answers).
function PGA.exemptFromRepeats()
    local rows = ProjectALife and ProjectALife.TalkSocialRows
    if not rows or type(rows.put) ~= "function" then return false end
    rows.put("order", PGA.Choice.invite .. " " .. PGA.Choice.goAhead .. " " .. PGA.Choice.stop)
    return true
end

-- Carrying a golf club (in hand, in the inventory or in a bag)? The invite only shows then.
function PGA.hasClub(player)
    if not player then return false end
    local ok, found = pcall(function()
        local inv = player:getInventory()
        return inv ~= nil and inv:getFirstTypeRecurse(ProjectGolf.Items.Club) ~= nil
    end)
    return ok and found == true
end

function PGA.registerChoices()
    local intents = ProjectALife and ProjectALife.TalkIntents
    if not intents or type(intents.addChoice) ~= "function" then return false end
    PGA.exemptFromRepeats()
    if type(intents.addGroup) == "function" then intents.addGroup({ id = "Golf", label = "Golf" }) end
    intents.addChoice({ id = PGA.Choice.invite, text = "Fancy a round of golf?", words = "fancy a round of golf",
        topic = "Golf", group = "Golf",
        show = function(view) return PGA.myPartner == nil and viewUid(view) ~= nil and PGA.hasClub(view.player) end })
    intents.addChoice({ id = PGA.Choice.goAhead, text = "Go ahead, take your shot.", words = "go ahead take your shot",
        topic = "Golf", group = "Golf",
        show = function(view) local uid = viewUid(view) return uid ~= nil and PGA.myPartner == uid end })
    intents.addChoice({ id = PGA.Choice.stop, text = "Let's call it a day on the golf.", words = "call it a day on the golf",
        topic = "Golf", group = "Golf",
        show = function(view) local uid = viewUid(view) return uid ~= nil and PGA.myPartner == uid end })
    return true
end

function PGA.installShared()
    local a = PGA.registerPreset()
    local b = PGA.registerChoices()
    PGA.sharedReady = a and b
    return PGA.sharedReady
end

PGA.installShared()
if Events and Events.OnGameBoot then Events.OnGameBoot.Add(function() if not PGA.sharedReady then PGA.installShared() end end) end
if Events and Events.OnGameStart then Events.OnGameStart.Add(function() if not PGA.sharedReady then PGA.installShared() end end) end
if Events and Events.OnServerStarted then Events.OnServerStarted.Add(function() if not PGA.sharedReady then PGA.installShared() end end) end
-- (again once everything has loaded, in case A-Life's talk rows load after this file)
if Events and Events.OnGameStart then Events.OnGameStart.Add(function() PGA.exemptFromRepeats() end) end
if Events and Events.OnServerStarted then Events.OnServerStarted.Add(function() PGA.exemptFromRepeats() end) end
