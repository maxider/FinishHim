-- FinishHim meter: learns from the game's built-in damage meter (C_DamageMeter) when hit amounts are hidden.
--
-- On Forever, UNIT_COMBAT can hand out secret amounts, so Core.lua's per-hit learning never sees a number.
-- The damage meter's totals per spell are readable once the fight is over (Details reads them the same way). So:
--   1. Out of combat, remember the meter's Overall total for each tracked spell (the baseline).
--   2. Core reports each tracked cast and its combo points (recordCast).
--   3. After the fight, the total minus the baseline is what those casts did together. Divided by the sum of
--      the tooltip middles of those casts, that's the same ratio the hit path learns, averaged over the fight.
-- The total includes crits, which would make the estimate too high, so it's divided by (1 + crit chance): melee
-- crits do double damage. Dodged casts count as 0, which only makes it more careful.

local ADDON_NAME, ns = ...

local READ_DELAYS = { 1, 3, 6, 12 } -- seconds after combat ends; the meter can stay secret a little longer
local BASELINE_INTERVAL = 3         -- how often the baseline is refreshed while out of combat with nothing pending
local DEFAULT_CRIT = 0.15           -- used when crit chance can't be read (errs careful)

local meter = {}
ns.meter = meter

local baseline       -- spell name -> Overall total when the baseline was taken; nil = not taken yet
local casts = {}     -- tracked casts since the baseline: { spell, entry, key, learned }
local lastResult = "nothing read yet"
local readToken = 0  -- bumps when combat starts, so reads scheduled for an earlier fight stop

local function isSecret(v) return ns.isSecret(v) end

local function inCombat()
    local ok, combat = pcall(UnitAffectingCombat, "player")
    if not ok or isSecret(combat) then return true end
    return combat and true or false
end

local function available()
    return type(C_DamageMeter) == "table" and type(C_DamageMeter.GetCombatSessionSourceFromType) == "function"
        and Enum and Enum.DamageMeterSessionType and Enum.DamageMeterType
end

-- Overall damage per tracked spell name (all ranks together), or nil and why not.
local function readTotals()
    if not available() then return nil, "not available on this client" end
    local okGuid, guid = pcall(UnitGUID, "player")
    if not okGuid or isSecret(guid) then return nil, "player GUID hidden" end
    local ok, source = pcall(C_DamageMeter.GetCombatSessionSourceFromType, Enum.DamageMeterSessionType.Overall,
        Enum.DamageMeterType.DamageDone, guid)
    if not ok then return nil, "error: " .. tostring(source) end
    if type(source) ~= "table" then return nil, "no data for you yet" end
    local totals, hidden = {}, false
    local okRead, err = pcall(function()
        local spells = source.combatSpells
        if type(issecrettable) == "function" and issecrettable(spells) then
            hidden = true
            return
        end
        if type(spells) ~= "table" then return end
        for _, entry in ipairs(spells) do
            local id, amount = entry.spellID, entry.totalAmount
            if isSecret(id) or isSecret(amount) then
                hidden = true
                return
            end
            local spell = type(id) == "number" and ns.trackedSpell(id)
            if spell and type(amount) == "number" then totals[spell.name] = (totals[spell.name] or 0) + amount end
        end
    end)
    if not okRead then return nil, "error: " .. tostring(err) end
    if hidden then return nil, "hidden (still in combat?)" end
    return totals
end

local function critChance()
    local ok, crit = pcall(GetCritChance)
    if ok and type(crit) == "number" and not isSecret(crit) then return crit / 100, string.format("%.1f%%", crit) end
    return DEFAULT_CRIT, string.format("unreadable, assumed %d%%", DEFAULT_CRIT * 100)
end

local function takeBaseline()
    local totals, why = readTotals()
    if totals then
        baseline = totals
        wipe(casts)
    end
    return totals, why
end

-- Called by Core for each tracked cast that has a known entry (combo points). Returns the record, which Core
-- marks .learned when it learned from the hit itself.
function meter.recordCast(spell, entry, key)
    local record = { spell = spell, entry = entry, key = key, learned = false }
    if baseline then table.insert(casts, record) end
    return record
end

-- Learns from what the tracked casts since the baseline did together, then starts a new baseline.
local function learnFromTotals(totals)
    local bySpell = {}
    for _, cast in ipairs(casts) do
        local name = cast.spell.name
        bySpell[name] = bySpell[name] or { spell = cast.spell, casts = {} }
        table.insert(bySpell[name].casts, cast)
    end
    local crit, critText = critChance()
    local results = {}
    for name, group in pairs(bySpell) do
        local done = (totals[name] or 0) - (baseline[name] or 0)
        local ranges = ns.rangesFor(group.spell)
        local middles, key, sameMob, alreadyLearned = 0, group.casts[1].key, true, false
        for _, cast in ipairs(group.casts) do
            local range = ranges and ranges[cast.entry]
            if range then middles = middles + (range.min + range.max) / 2 end
            if cast.key ~= key then sameMob = false end
            if cast.learned then alreadyLearned = true end
        end
        local result
        if alreadyLearned then
            result = "learned from the hits already"
        elseif done < 0 then
            result = "meter was reset, skipped"
        elseif done == 0 then
            result = "no damage in the meter (all avoided?), skipped"
        elseif middles <= 0 then
            result = "no tooltip numbers, skipped"
        else
            local ratio = done / middles / (1 + crit)
            ns.learnRatio(group.spell, sameMob and key or nil, ratio, string.format(
                "damage meter, %d cast(s) did %d, crit %s", #group.casts, done, critText))
            result = string.format("learned from %d cast(s)", #group.casts)
        end
        table.insert(results, name .. ": " .. result)
        ns.trace("METER " .. name .. ": " .. result)
    end
    baseline = totals
    wipe(casts)
    if #results > 0 then lastResult = table.concat(results, "; ") end
end

local function readAfterCombat(token, attempt)
    if token ~= readToken or inCombat() then return end -- a new fight started: its casts add to these
    if #casts == 0 then
        takeBaseline()
        return
    end
    local totals, why = readTotals()
    if totals then
        learnFromTotals(totals)
        return
    end
    if attempt < #READ_DELAYS then
        C_Timer.After(READ_DELAYS[attempt + 1] - READ_DELAYS[attempt], function() readAfterCombat(token, attempt + 1) end)
        return
    end
    lastResult = "couldn't read the meter after the fight: " .. tostring(why)
    ns.trace("METER " .. lastResult)
    baseline = nil -- start over with a fresh baseline
    wipe(casts)
end

function meter.status()
    if not available() then return "not available on this client (no fallback for hidden hits)" end
    local _, why = readTotals()
    return string.format("%s; baseline %s; %d cast(s) waiting for the fight to end; last: %s",
        why and ("now " .. why) or "readable now", baseline and "taken" or "not taken yet", #casts, lastResult)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(_, event)
    if not ns.db or not available() then return end
    readToken = readToken + 1
    if event == "PLAYER_REGEN_ENABLED" then
        local token = readToken
        C_Timer.After(READ_DELAYS[1], function() readAfterCombat(token, 1) end)
    end
end)

-- Keeps the baseline fresh while nothing is pending, so a fight always starts from a recent one.
local sinceBaseline = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    sinceBaseline = sinceBaseline + elapsed
    if sinceBaseline < BASELINE_INTERVAL then return end
    sinceBaseline = 0
    if ns.db and available() and #casts == 0 and not inCombat() then takeBaseline() end
end)
