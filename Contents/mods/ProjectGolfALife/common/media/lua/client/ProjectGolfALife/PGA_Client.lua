-- Project Golf x A-Life (prototype) - client part.
--   * the partner's shots fly through Project Golf's own Flight playback, but are never "yours": no stroke count,
--     no score, no halo for you
--   * which NPC is your partner (for the talk window's Golf tab)
--   * right-click anywhere: Golf partner (test) > Spawn a test golf partner (single player, or admins)

require "ProjectGolf/PG_Config"
require "ProjectGolf/PG_Client"
require "ProjectGolfALife/PGA_Shared"

local PG = ProjectGolf
local PGA = ProjectGolfALife
local C = PG.Client

-- ---- the partner's flights are not yours -------------------------------------------------------------------------
function PGA.wrapFlight()
    if PGA.flightWrapped or type(PG.ClientCommands.Flight) ~= "function" then return end
    local original = PG.ClientCommands.Flight
    PG.ClientCommands.Flight = function(args)
        local before = #C.flights
        original(args)
        if type(args) == "table" and args.pgaNpc and #C.flights > before then
            C.flights[#C.flights].mine = false
        end
    end
    PGA.flightWrapped = true
end
PGA.wrapFlight()

-- ---- partner state from the server -------------------------------------------------------------------------------
function PGA.ClientCommands.Partner(args)
    if type(args) ~= "table" or args.uid == nil then return end
    if args.on then
        PGA.myPartner = args.uid
    elseif PGA.myPartner == args.uid then
        PGA.myPartner = nil
    end
end

local function onServerCommand(module, command, args)
    if module ~= PGA.MOD_ID then return end
    local h = PGA.ClientCommands[command]
    if h then h(args) end
end
Events.OnServerCommand.Add(onServerCommand)

-- ---- test spawn ---------------------------------------------------------------------------------------------------
local function mayTestSpawn(player)
    if not isClient() then return true end
    local level = player and player.getAccessLevel and player:getAccessLevel() or nil
    return level ~= nil and level ~= "" and level ~= "None" and level ~= "none"
end

local function spawnPartner(player)
    PGA.sendToServer(player, "SpawnPartner", {})
end

local function onFillWorld(playerNum, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    if not player or not ProjectALife or not PGA.testSpawnEnabled() or not mayTestSpawn(player) then return end
    local option = context:addOption("Golf partner (test)", nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    if PGA.myPartner then
        sub:addOption("You already have a partner (talk to them: Golf tab)", nil, nil)
    else
        sub:addOption("Spawn a test golf partner", player, spawnPartner)
    end
end
Events.OnFillWorldObjectContextMenu.Add(onFillWorld)

-- ---------------------------------------------------------------------------------------------------------------
-- The partner's scorecard: an extra column on Project Golf's own card (Golf > Tips / Scorecard, West Maple page).
-- Kept on your character next to your card (mod data ProjectGolfALife.cards[courseId]), so it saves with the game.
-- A new card for you (teeing off on hole 1, or the New card button) is a new card for them too.
-- ---------------------------------------------------------------------------------------------------------------
require "ProjectGolf/PG_Guide"

function PGA.partnerCard(player, courseId, create)
    local md = player and player:getModData()
    if not md then return nil end
    if not md.ProjectGolfALife and not create then return nil end
    md.ProjectGolfALife = md.ProjectGolfALife or {}
    local data = md.ProjectGolfALife
    data.cards = data.cards or {}
    if not data.cards[courseId] and not create then return nil end
    data.cards[courseId] = data.cards[courseId] or { holes = {} }
    data.cards[courseId].holes = data.cards[courseId].holes or {}
    return data.cards[courseId]
end

local function hasScores(card)
    if not card then return false end
    for _, e in pairs(card.holes) do if e.last then return true end end
    return false
end

-- from the server when your partner finishes a hole
function PGA.ClientCommands.PartnerScore(args)
    if type(args) ~= "table" or not args.course or not args.hole or not args.strokes then return end
    local player = getSpecificPlayer and getSpecificPlayer(0) or getPlayer()
    local card = PGA.partnerCard(player, args.course, true)
    if not card then return end
    -- a different partner (by who they are, not their name: two Daves are two partners): their card starts fresh
    local who = args.uid or args.name
    if who and who ~= (card.uid or card.name) then
        if card.uid ~= nil or card.name ~= nil then for _, e in pairs(card.holes) do e.last, e.picked = nil, nil end end
        card.uid = args.uid
    end
    if args.name then card.name = args.name end
    if args.rating then card.rating = args.rating end
    card.holes[args.hole] = { last = args.strokes, picked = args.picked == true or nil }
end

-- your new card clears theirs too
if C.newScorecard and not PGA.newCardWrapped then
    local originalNew = C.newScorecard
    C.newScorecard = function(player, courseId, ...)
        local r = originalNew(player, courseId, ...)
        local card = PGA.partnerCard(player, courseId, false)
        if card then for _, e in pairs(card.holes) do e.last, e.picked = nil, nil end end
        return r
    end
    PGA.newCardWrapped = true
end

-- ---- drawing: Project Golf's card with a column for them (only once they have a score on it) -------------------
local function fontH(font)
    local ok, h = pcall(function() return getTextManager():getFontHeight(font) end)
    return (ok and h and h > 0) and h or (font == UIFont.Medium and 20 or 15)
end

local function textW(font, s)
    local ok, w = pcall(function() return getTextManager():MeasureStringX(font, s) end)
    return (ok and w) or #s * 7
end

local function wrap(font, text, width)
    local lines, line = {}, ""
    for word in text:gmatch("%S+") do
        local test = line == "" and word or (line .. " " .. word)
        if line ~= "" and textW(font, test) > width then
            lines[#lines + 1] = line
            line = word
        else
            line = test
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

local function scoreColour(score, par)
    if not score then return 0.5, 0.5, 0.5 end
    if score < par then return 0.4, 1, 0.4 end
    if score == par then return 1, 1, 1 end
    return 1, 0.55, 0.45
end

local function toPar(d)
    if d == 0 then return "E" end
    return d > 0 and ("+" .. d) or tostring(d)
end

-- Their first name only ("Dave Miller" -> "Dave"), cut short if it's long.
local function shortName(name)
    name = tostring(name or "Partner")
    name = name:match("^%s*(%S+)") or name
    if #name > 10 then name = name:sub(1, 9) .. "." end
    return name
end

function PGA.renderCardWithPartner(self, courseId, course, pcard)
    local card = PG.Client.getScorecard(self.player, courseId)
    self.hits = {}
    local small, medium = fontH(UIFont.Small), fontH(UIFont.Medium)
    local y = self.contentTop
    self:drawTextCentre(course.name, self.width / 2, y, 0.55, 0.9, 0.55, 1, UIFont.Medium)
    y = y + medium + 8

    local W = self.width
    local cols = { W * 0.11, W * 0.26, W * 0.44, W * 0.66, W * 0.87 }   -- Hole, Par, You, Partner, Best (yours)
    local function cell(text, col, r, g, b) self:drawTextCentre(text, cols[col], y, r, g, b, 1, UIFont.Small) end
    cell("Hole", 1, 1, 0.85, 0.4)
    cell("Par", 2, 1, 0.85, 0.4)
    cell("You", 3, 1, 0.85, 0.4)
    cell(shortName(pcard.name) .. (pcard.rating and (" (" .. pcard.rating .. ")") or ""), 4, 0.55, 0.8, 1)
    cell("Your best", 5, 1, 0.85, 0.4)
    y = y + small + 2
    self:drawRect(16, y, self.width - 32, 1, 0.6, 1, 1, 1)
    y = y + 4

    local function totals(from, to, holes)
        local par, played, parPlayed, score = 0, 0, 0, 0
        for i = from, to do
            local h = course.holes[i]
            par = par + h.par
            local s = holes[i] and holes[i].last
            if s then played = played + 1; parPlayed = parPlayed + h.par; score = score + s end
        end
        return par, played, parPlayed, score
    end
    local function summary(from, to, holes)
        local _, played, parPlayed, score = totals(from, to, holes)
        return played > 0 and (score .. " (" .. toPar(score - parPlayed) .. ")") or "-"
    end
    local function totalRow(label, from, to)
        local par = totals(from, to, card.holes)
        self:drawRect(16, y - 1, self.width - 32, small + 2, 0.12, 1, 1, 1)
        cell(label, 1, 1, 0.85, 0.4)
        cell(tostring(par), 2, 1, 0.85, 0.4)
        cell(summary(from, to, card.holes), 3, 1, 0.85, 0.4)
        cell(summary(from, to, pcard.holes), 4, 0.55, 0.8, 1)
        y = y + small + 4
    end

    local n = #course.holes
    local anyPicked = false
    for i, h in ipairs(course.holes) do
        local e = card.holes[i] or {}
        local p = pcard.holes[i] or {}
        cell(tostring(i), 1, 0.9, 0.9, 0.9)
        cell(tostring(h.par), 2, 0.9, 0.9, 0.9)
        local r, g, b = scoreColour(e.last, h.par)
        cell(e.last and tostring(e.last) or "-", 3, r, g, b)
        r, g, b = scoreColour(p.last, h.par)
        if p.picked then anyPicked = true end
        cell(p.last and (tostring(p.last) .. (p.picked and "*" or "")) or "-", 4, r, g, b)
        cell(e.best and tostring(e.best) or "-", 5, 0.9, 0.9, 0.9)
        if self.editing then
            local box, player = small, self.player
            for _, f in ipairs({ { col = cols[3], field = "last" }, { col = cols[5], field = "best" } }) do
                self:addHit(f.col - 18 - box, y, box, "-", function()
                    PG.Client.adjustScore(player, courseId, i, f.field, -1, h.par) end)
                self:addHit(f.col + 18, y, box, "+", function()
                    PG.Client.adjustScore(player, courseId, i, f.field, 1, h.par) end)
            end
        end
        y = y + small + 2
        if n == 18 and i == 9 then totalRow("Out", 1, 9) end
    end
    if n == 18 then totalRow("In", 10, 18) end
    totalRow("Total", 1, n)

    -- the match: holes won each, on the holes you both finished
    local won, lost, halved = 0, 0, 0
    for i = 1, n do
        local a, b = card.holes[i] and card.holes[i].last, pcard.holes[i] and pcard.holes[i].last
        if a and b then
            if a < b then won = won + 1 elseif a > b then lost = lost + 1 else halved = halved + 1 end
        end
    end
    y = y + 6
    local match = "Match: you won " .. won .. ", " .. shortName(pcard.name) .. " won " .. lost .. ", halved " .. halved
    self:drawText(match, 16, y, 0.55, 0.8, 1, 1, UIFont.Small)
    y = y + small + 2
    local best = card.bestRound and (card.bestRound .. " (" .. toPar(card.bestRound - totals(1, n, card.holes)) .. ")") or "none yet"
    local bestText = "Your best full round: " .. best
    self:drawText(bestText, 16, y, 0.8, 0.8, 0.8, 1, UIFont.Small)
    if self.editing then
        local bx, coursePar, player = 16 + textW(UIFont.Small, bestText) + 12, (totals(1, n, card.holes)), self.player
        self:addHit(bx, y, small, "-", function() PG.Client.adjustBestRound(player, courseId, -1, coursePar, n) end)
        self:addHit(bx + small + 6, y, small, "+", function() PG.Client.adjustBestRound(player, courseId, 1, coursePar, n) end)
    end
    y = y + small + 2
    local note = self.editing and "Click - / + to fix one of your scores. An empty box starts at par."
        or ("Scores fill in when a hole is finished. Teeing off on hole 1 starts a new card for both of you."
            .. (pcard.rating and ("  (" .. pcard.rating .. ") is their golf rating, out of 10.") or "")
            .. (anyPicked and "  * picked up." or ""))
    for _, line in ipairs(wrap(UIFont.Small, note, self.width - 32)) do
        self:drawText(line, 16, y, 0.6, 0.6, 0.6, 1, UIFont.Small)
        y = y + small + 1
    end
end

if PG_GuideWindow and not PGA.cardWrapped then
    local originalCard = PG_GuideWindow.renderCard
    PG_GuideWindow.renderCard = function(self, courseId, ...)
        local pcard = PGA.partnerCard(self.player, courseId, false)
        local course
        for _, c in ipairs(PG.Courses.list) do if c.id == courseId then course = c end end
        if course and hasScores(pcard) then return PGA.renderCardWithPartner(self, courseId, course, pcard) end
        return originalCard(self, courseId, ...)
    end
    PGA.cardWrapped = true
end
