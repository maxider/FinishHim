-- FinishHim core: how much damage Eviscerate will do at each combo point count, and how many points you have.
--
-- In WoW: Forever the target's health is secret, so Lua can never compare "damage vs health" itself. What stays
-- readable (same findings as DoesItDie):
--   * our own casts (UNIT_SPELLCAST_SENT/SUCCEEDED) and spell descriptions -> Eviscerate's damage per combo point
--   * UNIT_COMBAT damage amounts on the target -> what Eviscerate really hit for (armor, attack power included)
-- The comparison with health is done by StatusBars in Display.lua.
--
-- The estimate is the LOWEST roll of a normal (non-crit) hit, so a lit pip means "this kills even on a bad roll".

local ADDON_NAME, ns = ...

local MAX_LOG = 400
local MAX_POINTS = 5
local SAMPLES_KEPT = 20             -- learned hits kept per finisher (saved)
local HIT_WINDOW = 0.5              -- seconds after the cast in which its hit must arrive
local HIT_LOOKBACK = 0.25           -- the hit can also arrive just before the cast event
local AVOID_WINDOW = 0.4            -- a dodge/parry/miss this soon after a builder takes its points back
local PLAUSIBLE_MIN, PLAUSIBLE_MAX = 0.3, 3 -- a hit this far off the tooltip's numbers isn't Eviscerate

-- Finishers this addon predicts, by every rank's spell ID (works on any client language).
-- Eviscerate ranks 1-8 (Classic), 9-10 (TBC). The highest rank the player knows is the one predicted.
local FINISHERS = {
    { key = "Eviscerate", ranks = { 2098, 6760, 6761, 6762, 8623, 8624, 11299, 11300, 31016, 26865 } },
}
local FINISHER_BY_ID = {}
for _, finisher in ipairs(FINISHERS) do
    for _, id in ipairs(finisher.ranks) do FINISHER_BY_ID[id] = finisher end
end

local AVOIDED = {
    MISS = true, DODGE = true, PARRY = true, EVADE = true, IMMUNE = true, DEFLECT = true, RESIST = true, REFLECT = true,
}

local DEFAULTS = {
    enabled = true,
    locked = true,
    scale = 1,
    point = nil,          -- { point, relativePoint, x, y } on UIParent once dragged; nil = above the target frame
    margin = 0,           -- percent taken off every estimate, to be extra careful
    guessFactor = 0.75,   -- tooltip minimum x this, until a real hit has been seen (armor isn't in the tooltip)
    showNumbers = true,
    includeDots = false,  -- add DoesItDie's remaining DoT damage (dies eventually, not instantly)
    debug = false,
}

local db
ns.finishers = FINISHERS

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function isSecret(v)
    if type(issecretvalue) ~= "function" then return false end
    local ok, r = pcall(issecretvalue, v)
    return ok and r or false
end
ns.isSecret = isSecret

local function plainNumber(ok, v)
    if ok and type(v) == "number" and not isSecret(v) then return v end
end

local function print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff5555FinishHim|r: " .. tostring(msg))
end
ns.print = print

local function trace(msg)
    if not db then return end
    table.insert(db.log, string.format("%.1f %s", GetTime(), msg))
    if #db.log > MAX_LOG then table.remove(db.log, 1) end
    if db.debug then print("|cff888888" .. msg .. "|r") end
end
ns.trace = trace

-- Plain GUID of the unit, or "target" for the target when GUIDs are secret (then only the current target works).
local function unitKey(unit)
    local ok, guid = pcall(UnitGUID, unit)
    if ok and type(guid) == "string" and not isSecret(guid) then return guid end
    if unit == "target" and UnitExists("target") then return "target" end
end
ns.unitKey = unitKey

local function spellDescription(spellID)
    local fn = (C_Spell and C_Spell.GetSpellDescription) or GetSpellDescription
    if not fn then return nil end
    local ok, desc = pcall(fn, spellID)
    if ok and type(desc) == "string" and not isSecret(desc) and desc ~= "" then return desc end
end

local function knows(spellID)
    for _, fn in ipairs({ IsPlayerSpell, IsSpellKnown }) do
        if type(fn) == "function" then
            local ok, known = pcall(fn, spellID)
            if ok and not isSecret(known) and known then return true end
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Tooltip: damage range per combo point
---------------------------------------------------------------------------

-- "1 point  : 6-11 damage\n 2 points: 12-17 damage ..." (German "1 Punkt: 6-11 Schaden" works too: only the
-- digits, the colon and the dash are matched). Returns { [points] = { min, max } } or nil.
local function parseRanges(desc)
    if not desc then return nil end
    local ranges, found = {}, false
    for points, low, high in desc:gmatch("(%d+)[^%d\n:]-:%s*(%d+)%s*%-%s*(%d+)") do
        points = tonumber(points)
        if points >= 1 and points <= MAX_POINTS and not ranges[points] then
            ranges[points] = { min = tonumber(low), max = tonumber(high) }
            found = true
        end
    end
    if not found then -- single numbers: "1 point: 10 damage"
        for points, amount in desc:gmatch("(%d+)[^%d\n:]-:%s*(%d+)") do
            points = tonumber(points)
            if points >= 1 and points <= MAX_POINTS and not ranges[points] then
                ranges[points] = { min = tonumber(amount), max = tonumber(amount) }
                found = true
            end
        end
    end
    return found and ranges or nil
end
ns.parseRanges = parseRanges

local rangeCache = {} -- spellID -> { ranges, at }
local RANGE_CACHE_SECONDS = 2 -- descriptions can change with attack power

local function rangesFor(spellID)
    if not spellID then return nil end
    local cached = rangeCache[spellID]
    local now = GetTime()
    if cached and now - cached.at < RANGE_CACHE_SECONDS then return cached.ranges end
    local ranges = parseRanges(spellDescription(spellID))
    -- Descriptions can be unreadable in combat: keep the last good parse rather than losing the estimate.
    if not ranges and cached then ranges = cached.ranges end
    rangeCache[spellID] = { ranges = ranges, at = now }
    return ranges
end

local activeRank = {} -- finisher key -> highest known rank's spell ID

local function updateKnownRanks()
    for _, finisher in ipairs(FINISHERS) do
        local best
        for _, id in ipairs(finisher.ranks) do
            if knows(id) then best = id end
        end
        activeRank[finisher.key] = best
    end
end
ns.updateKnownRanks = updateKnownRanks

function ns.activeRank(finisher)
    return activeRank[finisher.key]
end

---------------------------------------------------------------------------
-- Learning: what Eviscerate really hits for, relative to its tooltip
---------------------------------------------------------------------------
-- Each landed non-crit hit gives ratio = amount / tooltip middle at that combo point count. The ratio carries
-- armor and any attack power the tooltip leaves out, and works for every point count, so one 3-point hit
-- also improves the 5-point estimate. On a mob already hit this session, that mob's ratios are used; otherwise
-- a cautious pick (low quartile) of the saved ones, since other mobs may have more armor.

local mobSamples = {} -- unit key -> { ratio, ... } (this session only)

local function mean(list)
    local sum = 0
    for _, v in ipairs(list) do sum = sum + v end
    return sum / #list
end

local function lowQuartile(list)
    local sorted = {}
    for i, v in ipairs(list) do sorted[i] = v end
    table.sort(sorted)
    return sorted[math.floor(#sorted * 0.25) + 1]
end

-- Returns ratio and a description of where it came from.
local function ratioFor(finisher, key)
    local onMob = key and mobSamples[key] and mobSamples[key][finisher.key]
    if onMob and #onMob > 0 then
        return mean(onMob), string.format("learned on this mob (%d hit%s)", #onMob, #onMob == 1 and "" or "s")
    end
    local saved = db.samples[finisher.key]
    if saved and #saved > 0 then
        return lowQuartile(saved), string.format("learned (%d hit%s)", #saved, #saved == 1 and "" or "s")
    end
    return db.guessFactor, string.format("guess: tooltip x %.2f (no hit seen yet)", db.guessFactor)
end

local function learn(finisher, key, ratio, points, amount)
    local saved = db.samples[finisher.key] or {}
    db.samples[finisher.key] = saved
    table.insert(saved, ratio)
    while #saved > SAMPLES_KEPT do table.remove(saved, 1) end
    if key then
        mobSamples[key] = mobSamples[key] or {}
        local onMob = mobSamples[key][finisher.key] or {}
        mobSamples[key][finisher.key] = onMob
        table.insert(onMob, ratio)
    end
    trace(string.format("LEARN %s %d points hit %d (ratio %.3f to tooltip middle)", finisher.key, points, amount, ratio))
end

function ns.forget()
    wipe(db.samples)
    wipe(mobSamples)
end

-- Lowest normal hit of `finisher` at `points` on the target, plus a source description. nil if unknown.
function ns.estimate(finisher, points)
    local ranges = rangesFor(activeRank[finisher.key])
    local range = ranges and ranges[points]
    if not range then return nil end
    local ratio, source = ratioFor(finisher, unitKey("target"))
    local damage = range.min * ratio * (1 - db.margin / 100)
    return math.max(0, math.floor(damage)), source
end

function ns.tooltipRanges(finisher)
    return rangesFor(activeRank[finisher.key])
end

-- Remaining DoT damage on the target from DoesItDie, if that addon is loaded and the option is on.
function ns.dotDamage()
    if not db.includeDots or type(DoesItDie) ~= "table" or type(DoesItDie.GetRemainingDamage) ~= "function" then
        return 0
    end
    local ok, total = pcall(DoesItDie.GetRemainingDamage, "target")
    return plainNumber(ok, total) or 0
end

---------------------------------------------------------------------------
-- Combo points
---------------------------------------------------------------------------
-- Read from the API when it's plain. They were secret in combat on the Forever beta (DoesItDie's notes), so the
-- game's combo point display is read too, and as a last resort the addon counts them itself: builders say
-- "Awards N combo point(s)", a dodge/parry/miss right after takes them back, a finisher or target change resets.

local counted = 0
local lastBuilder -- { key, points, at }

-- Lit points on the game's own combo frame (readable by appearance), or nil.
local function displayedComboPoints()
    local frame = _G.ComboFrame
    if type(frame) ~= "table" or type(frame.IsShown) ~= "function" then return nil end
    local ok, shown = pcall(frame.IsShown, frame)
    if not ok or isSecret(shown) then return nil end
    if not shown then return 0 end
    local count = 0
    for i = 1, 12 do
        local point = _G["ComboPoint" .. i]
        local highlight = type(point) == "table" and point.Highlight
        if type(highlight) ~= "table" or type(highlight.GetAlpha) ~= "function" then break end
        local okV, visible = pcall(point.IsShown, point)
        local okA, alpha = pcall(highlight.GetAlpha, highlight)
        if not okV or not okA or isSecret(visible) or isSecret(alpha) or type(alpha) ~= "number" then return nil end
        if visible and alpha > 0.5 then count = count + 1 end
    end
    return count
end

-- Returns the plain reading (or nil) and what each source said, for /fh probe.
local function readComboPoints()
    local best, parts = nil, {}
    local function consider(label, ok, v)
        local n = plainNumber(ok, v)
        table.insert(parts, label .. "=" .. (not ok and "error" or v == nil and "nil" or n and tostring(n) or "secret"))
        if n then best = math.max(best or 0, n) end
    end
    if GetComboPoints then consider("GetComboPoints", pcall(GetComboPoints, "player", "target")) end
    if UnitPower and Enum and Enum.PowerType and Enum.PowerType.ComboPoints then
        consider("UnitPower", pcall(UnitPower, "player", Enum.PowerType.ComboPoints))
    end
    if best == nil then consider("display", true, displayedComboPoints()) end
    return best, table.concat(parts, " ") .. ", counted=" .. counted
end
ns.readComboPoints = readComboPoints

-- Current points and their source ("read" or "counted").
function ns.comboPoints()
    local points = readComboPoints()
    if points then return math.min(points, MAX_POINTS), "read" end
    return counted, "counted"
end

local function awardedPoints(desc)
    if not desc then return nil end
    local n = desc:match("Awards (%d+) combo point") or desc:match("(%d+) [Cc]ombo[%- ]?[Pp]unkt")
        or desc:match("(%d+) [Cc]ombo")
    return tonumber(n)
end

local function resetCount()
    counted, lastBuilder = 0, nil
end

---------------------------------------------------------------------------
-- Casts and hits
---------------------------------------------------------------------------

local sentKeys = {}       -- castGUID -> { key, points, at }: the target and combo points when the cast was sent
local pendingCast         -- { finisher, rank, points, key, at, hits }: Eviscerate waiting for its hit
local recentHits = {}     -- { key, amount, flag, at }: last fraction of a second of hits, for the look-back
local frameHitsAt, frameHits = nil, {}

local function onCastSent(castGUID, spellID)
    if isSecret(castGUID) or isSecret(spellID) or not castGUID then return end
    local now = GetTime()
    for guid, sent in pairs(sentKeys) do
        if now - sent.at > 10 then sentKeys[guid] = nil end
    end
    local points
    if FINISHER_BY_ID[spellID] then
        local read = readComboPoints()
        points = read or (counted > 0 and counted) or nil
    end
    sentKeys[castGUID] = { key = unitKey("target"), points = points, at = now }
end

local function onCastSucceeded(castGUID, spellID)
    if isSecret(spellID) then return end
    local now = GetTime()
    local sent = (castGUID and not isSecret(castGUID)) and sentKeys[castGUID]
    if sent then sentKeys[castGUID] = nil end
    local key = sent and sent.key or unitKey("target")

    local finisher = FINISHER_BY_ID[spellID]
    local desc = spellDescription(spellID)
    if finisher then
        local points = sent and sent.points
        resetCount()
        trace(string.format("CAST %s (id %d) with %s combo points on %s", finisher.key, spellID,
            tostring(points or "?"), tostring(key)))
        if points and points > 0 and key then
            pendingCast = { finisher = finisher, rank = spellID, points = math.min(points, MAX_POINTS), key = key,
                at = now, hits = {} }
            for _, hit in ipairs(recentHits) do
                if hit.key == key and now - hit.at <= HIT_LOOKBACK then table.insert(pendingCast.hits, hit) end
            end
        end
        return
    end
    if desc and desc:find("Finishing move") then
        resetCount()
        return
    end
    local awarded = awardedPoints(desc)
    if awarded then
        counted = math.min(MAX_POINTS, counted + awarded)
        lastBuilder = { key = key, points = awarded, at = now }
    end
end

-- Picks Eviscerate's hit out of what landed around the cast (white hits land too) and learns from it.
local function resolvePending()
    local cast = pendingCast
    pendingCast = nil
    local ranges = rangesFor(cast.rank)
    local range = ranges and ranges[cast.points]
    if not range then
        trace("SKIP learning: no tooltip range for " .. cast.points .. " points")
        return
    end
    local middle = (range.min + range.max) / 2
    local best
    for _, hit in ipairs(cast.hits) do
        local plausible = hit.amount >= middle * PLAUSIBLE_MIN and hit.amount <= middle * PLAUSIBLE_MAX
        if plausible and hit.flag ~= "GLANCING" and (not best or hit.amount > best.amount) then best = hit end
    end
    if not best then
        trace("SKIP learning: no plausible hit seen (dodged, or hits unreadable?)")
        return
    end
    if best.flag == "CRITICAL" then
        trace("SKIP learning: the hit was a crit (" .. best.amount .. ")")
        return
    end
    learn(cast.finisher, cast.key, best.amount / middle, cast.points, best.amount)
end

local function onUnitCombat(unit, action, flag, amount, school)
    if isSecret(action) or isSecret(unit) then return end
    local key = unitKey(unit)
    if not key then return end
    local now = GetTime()

    if AVOIDED[action] then
        if lastBuilder and lastBuilder.key == key and now - lastBuilder.at <= AVOID_WINDOW then
            counted = math.max(0, counted - lastBuilder.points)
            trace("COMBO builder " .. action .. ", counted=" .. counted)
            lastBuilder = nil
        end
        if pendingCast and pendingCast.key == key and now - pendingCast.at <= HIT_WINDOW then
            trace("CAST " .. pendingCast.finisher.key .. " " .. action)
        end
        return
    end
    if action ~= "WOUND" then return end
    if lastBuilder and lastBuilder.key == key then lastBuilder = nil end
    if isSecret(amount) or type(amount) ~= "number" then return end
    if not isSecret(school) and type(school) == "number" and school ~= 1 then return end -- Eviscerate is Physical
    local plainFlag = (not isSecret(flag)) and flag or ""

    -- The same hit fires for target, nameplateN, softenemy...: take it once per frame.
    if frameHitsAt ~= now then frameHitsAt, frameHits = now, {} end
    local signature = key .. ":" .. amount .. ":" .. tostring(plainFlag)
    if frameHits[signature] then return end
    frameHits[signature] = true

    local hit = { key = key, amount = amount, flag = plainFlag, at = now }
    table.insert(recentHits, hit)
    while recentHits[1] and now - recentHits[1].at > HIT_LOOKBACK do table.remove(recentHits, 1) end
    if pendingCast and pendingCast.key == key then table.insert(pendingCast.hits, hit) end
end

function ns.housekeep(now)
    if pendingCast and now - pendingCast.at > HIT_WINDOW then resolvePending() end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
frame:RegisterEvent("UNIT_COMBAT")
-- Never register COMBAT_LOG_EVENT_UNFILTERED: Forever forbids it and shows a "blocked" popup.

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        FinishHimDB = FinishHimDB or {}
        db = FinishHimDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        db.samples = db.samples or {}
        db.log = db.log or {}
        ns.db = db
        trace("===== session start =====")
        self:UnregisterEvent("ADDON_LOADED")
    elseif not db then
        return
    elseif event == "PLAYER_LOGIN" or event == "SPELLS_CHANGED" then
        updateKnownRanks()
        ns.display.setup()
    elseif event == "PLAYER_TARGET_CHANGED" then
        resetCount() -- combo points belong to the target they were built on
        ns.display.refresh()
    elseif event == "UNIT_SPELLCAST_SENT" then
        local _, _, castGUID, spellID = ...
        onCastSent(castGUID, spellID)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, castGUID, spellID = ...
        onCastSucceeded(castGUID, spellID)
        ns.display.refresh()
    elseif event == "UNIT_POWER_FREQUENT" then
        local _, powerType = ...
        if not isSecret(powerType) and powerType == "COMBO_POINTS" then
            local points = readComboPoints()
            if points then counted = math.min(points, MAX_POINTS) end -- keep the count in step while readable
            ns.display.refresh()
        end
    elseif event == "UNIT_COMBAT" then
        onUnitCombat(...)
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function onOff(v) return v and "|cff66ff66on|r" or "|cffff6666off|r" end

local HELP = {
    "/fh lock | unlock - lock the pips, or unlock to drag them",
    "/fh reset - put the pips back above the target frame",
    "/fh scale <0.5-3> - size of the pips",
    "/fh margin <0-50> - take this % off every estimate (extra careful)",
    "/fh guess <0.3-1.5> - tooltip multiplier used until a real hit is seen (default 0.75)",
    "/fh numbers - show/hide the damage under each pip",
    "/fh dots - also count DoesItDie's remaining DoT damage (dies eventually, not instantly)",
    "/fh test - light everything up for 10 seconds",
    "/fh probe - print tooltip, combo point readings and estimates",
    "/fh forget - forget learned hits",
    "/fh debug - print the log to chat as it happens",
    "/fh toggle - turn the addon on/off",
}

SLASH_FINISHHIM1 = "/fh"
SLASH_FINISHHIM2 = "/finishhim"
SlashCmdList.FINISHHIM = function(msg)
    if not db then return end
    local cmd, arg = strtrim(msg or ""):lower():match("^(%S*)%s*(.-)$")
    local number = tonumber(arg)
    if cmd == "lock" or cmd == "unlock" then
        db.locked = cmd == "lock"
        ns.display.setup()
        print(db.locked and "Locked." or "Unlocked: drag the pips. /fh lock when done.")
    elseif cmd == "reset" then
        db.point = nil
        ns.display.setup()
        print("Position reset.")
    elseif cmd == "scale" and number then
        db.scale = math.max(0.5, math.min(3, number))
        ns.display.setup()
    elseif cmd == "margin" and number then
        db.margin = math.max(0, math.min(50, number))
        print(string.format("Estimates reduced by %d%%.", db.margin))
    elseif cmd == "guess" and number then
        db.guessFactor = math.max(0.3, math.min(1.5, number))
        print(string.format("Guess before learning: tooltip x %.2f.", db.guessFactor))
    elseif cmd == "numbers" then
        db.showNumbers = not db.showNumbers
        ns.display.setup()
        print("Damage numbers " .. onOff(db.showNumbers))
    elseif cmd == "dots" then
        db.includeDots = not db.includeDots
        print("Counting DoesItDie's DoT damage " .. onOff(db.includeDots)
            .. (type(DoesItDie) == "table" and "" or " (DoesItDie isn't loaded, so this does nothing)"))
    elseif cmd == "test" then
        ns.display.test(10)
    elseif cmd == "probe" then
        updateKnownRanks()
        for _, finisher in ipairs(FINISHERS) do
            local id = activeRank[finisher.key]
            print(finisher.key .. ": known rank id " .. tostring(id))
            local desc = id and spellDescription(id)
            print("Tooltip: " .. (desc and desc:gsub("\r?\n", " / ") or "unreadable"))
            local ranges = ns.tooltipRanges(finisher)
            for points = 1, MAX_POINTS do
                local range = ranges and ranges[points]
                local estimate, source = ns.estimate(finisher, points)
                print(string.format("  %d: tooltip %s, estimate %s (%s)", points,
                    range and (range.min .. "-" .. range.max) or "?", tostring(estimate or "?"), source or "-"))
            end
        end
        local _, readings = readComboPoints()
        print("Combo points: " .. readings)
        local ok, health = pcall(UnitHealth, "target")
        print("Target health: " .. (not ok and "error" or isSecret(health) and "secret" or tostring(health)))
    elseif cmd == "forget" then
        ns.forget()
        print("Learned hits forgotten.")
    elseif cmd == "debug" then
        db.debug = not db.debug
        print("Debug " .. onOff(db.debug))
    elseif cmd == "toggle" then
        db.enabled = not db.enabled
        ns.display.refresh()
        print("FinishHim " .. onOff(db.enabled))
    else
        for _, line in ipairs(HELP) do print(line) end
    end
end
