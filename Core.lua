-- FinishHim core: how much damage each spell you picked will do, and how many combo points you have.
--
-- In WoW: Forever the target's health is secret, so Lua can never compare "damage vs health" itself. What stays
-- readable (same findings as DoesItDie):
--   * our own casts (UNIT_SPELLCAST_SENT/SUCCEEDED) and spell descriptions -> a spell's damage numbers
--   * UNIT_COMBAT damage amounts on the target -> what the spell really hit for (armor, attack power included)
-- The comparison with health is done by StatusBars in Display.lua.
--
-- Estimates are the LOWEST roll of a normal (non-crit) hit, so a lit pip means "this kills even on a bad roll".

local ADDON_NAME, ns = ...

local MAX_LOG = 400
local MAX_POINTS = 5
local SAMPLES_KEPT = 20             -- learned hits kept per spell (saved)
local HIT_WINDOW = 0.5              -- seconds after the cast in which its hit must arrive
local HIT_LOOKBACK = 0.25           -- the hit can also arrive just before the cast event
local AVOID_WINDOW = 0.4            -- a dodge/parry/miss this soon after a builder takes its points back
local PLAUSIBLE_MIN, PLAUSIBLE_MAX = 0.3, 3 -- a hit this far off the tooltip's numbers isn't the spell's
local EVISCERATE_ID = 2098          -- tracked by default (any rank; the name comes from the client's language)

local AVOIDED = {
    MISS = true, DODGE = true, PARRY = true, EVADE = true, IMMUNE = true, DEFLECT = true, RESIST = true, REFLECT = true,
}

local DEFAULTS = {
    enabled = true,
    locked = true,
    scale = 1,
    point = nil,          -- { point, relativePoint, x, y } on UIParent once dragged; nil = above the target frame
    useTooltip = true,    -- estimate = the tooltip's minimum as is (no armor, stats or learned ratio)
    margin = 0,           -- percent taken off every estimate, to be extra careful
    guessFactor = 0.75,   -- tooltip minimum x this, until a real hit has been seen (armor isn't in the tooltip)
    showNumbers = true,
    showMarkers = true,   -- health bar markers for spells that have them turned on
    includeDots = false,  -- add DoesItDie's remaining DoT damage (dies eventually, not instantly)
    debug = false,
}

local db

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

local function plainString(ok, v)
    if ok and type(v) == "string" and not isSecret(v) and v ~= "" then return v end
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

local function spellName(spellID)
    if C_Spell and C_Spell.GetSpellName then return plainString(pcall(C_Spell.GetSpellName, spellID)) end
    if GetSpellInfo then return plainString(pcall(GetSpellInfo, spellID)) end
end

-- Name, icon and spell ID of a spell in the player's spellbook, by name or ID. Looked up by name, Classic
-- clients give the highest rank the player knows, which is the one to predict. nil if the player doesn't know it.
local function spellInfo(nameOrID)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, nameOrID)
        if ok and type(info) == "table" and plainNumber(true, info.spellID) then
            return plainString(true, info.name), info.iconID, info.spellID
        end
    end
    if GetSpellInfo then
        local ok, name, _, icon, _, _, _, id = pcall(GetSpellInfo, nameOrID)
        if ok and plainString(true, name) and plainNumber(true, id) then return name, icon, id end
    end
end

local function spellDescription(spellID)
    local fn = (C_Spell and C_Spell.GetSpellDescription) or GetSpellDescription
    if not fn or not spellID then return nil end
    return plainString(pcall(fn, spellID))
end

---------------------------------------------------------------------------
-- Spell kinds: how a tooltip turns into damage numbers
---------------------------------------------------------------------------
-- Every kind's parser returns { [n] = { min, max }, school = mask }: one entry per combo point count for
-- "combo", only [1] for "direct" (single cast spells). Estimates, learning and the display all work per entry.

-- "1 point  : 6-11 damage\n 2 points: 12-17 damage ..." (German "1 Punkt: 6-11 Schaden" works too: only the
-- digits, the colon and the dash are matched). DoT finishers list single numbers: "1 point: 25 damage over 8 secs".
local function parseComboRanges(desc)
    if not desc then return nil end
    local ranges, found = {}, false
    for points, low, high in desc:gmatch("(%d+)[^%d\n:]-:%s*(%d+)%s*%-%s*(%d+)") do
        points = tonumber(points)
        if points >= 1 and points <= MAX_POINTS and not ranges[points] then
            ranges[points] = { min = tonumber(low), max = tonumber(high) }
            found = true
        end
    end
    if not found then
        for points, amount in desc:gmatch("(%d+)[^%d\n:]-:%s*(%d+)") do
            points = tonumber(points)
            if points >= 1 and points <= MAX_POINTS and not ranges[points] then
                ranges[points] = { min = tonumber(amount), max = tonumber(amount) }
                found = true
            end
        end
    end
    -- Two entries at least: a lone "1: 20" is more likely a stray number than a per-point table.
    local count = 0
    for _ in pairs(ranges) do count = count + 1 end
    return count >= 2 and ranges or nil
end

-- School words in tooltips ("13 Arcane damage", German "13 Arkanschaden") -> school mask.
local SCHOOLS = {
    physical = 1, holy = 2, fire = 4, nature = 8, frost = 16, shadow = 32, arcane = 64,
    heilig = 2, feuer = 4, natur = 8, schatten = 32, arkan = 64,
}

-- Single cast spells: the first fixed damage clause that isn't damage over time.
--   "An instant shot that causes 13 Arcane damage."              (Arcane Shot)
--   "Hurls a fiery ball that causes 14 to 23 Fire damage ..."     (Fireball: the DoT part after it is ignored)
--   "... 15% of your ranged attack power plus 273 Arcane damage"  (the attack power part is learned, not read)
-- Weapon-based abilities ("weapon damage plus 68") have no fixed number to start from and are refused, and so
-- are pure DoTs ("40 Shadow damage over 12 sec"): DoesItDie covers those.
local DIRECT_PATTERNS = {
    "(%d+)%s+to%s+(%d+)%s+(%a*)%s*[Dd]amage", -- 14 to 23 Fire damage
    "(%d+)%s*%-%s*(%d+)%s+(%a*)%s*[Dd]amage", -- 14-23 Fire damage
    "(%d+)%s+bis%s+(%d+)%s+(%a*)[Ss]chaden",  -- 14 bis 23 Feuerschaden
    "(%d+)()%s+(%a*)%s*[Dd]amage",            -- 13 Arcane damage (the () is a dummy so every pattern has 3 captures)
    "(%d+)()%s+(%a*)[Ss]chaden",              -- 13 Arkanschaden
}

local function parseDirect(desc)
    if not desc or desc:find("[Ww]eapon damage") or desc:find("[Ww]affenschaden") then return nil end
    local best, bestAt
    for _, pattern in ipairs(DIRECT_PATTERNS) do
        local start, finish, low, high, word = desc:find(pattern)
        -- Skip damage over time: look for the next match of the same pattern after it.
        while start and (desc:find("^%s*over %d", finish + 1) or desc:find("^%s*über %d", finish + 1)) do
            start, finish, low, high, word = desc:find(pattern, finish + 1)
        end
        if start and (not bestAt or start < bestAt) then
            if type(high) ~= "string" then high = low end -- the dummy capture is a position
            best = { min = tonumber(low), max = tonumber(high), word = word }
            bestAt = start
        end
    end
    if not best or best.min <= 0 then return nil end
    local school = SCHOOLS[(best.word or ""):lower()] or 1
    return { [1] = { min = best.min, max = math.max(best.min, best.max) }, school = school }
end

local KINDS = {
    combo = { label = "combo point spell", short = "combo points", parse = parseComboRanges, usesPoints = true,
        pips = MAX_POINTS },
    direct = { label = "single cast spell", short = "single cast", parse = parseDirect, usesPoints = false, pips = 1 },
}
-- Detection order in /fh add: a per-point table wins over a single number in the same tooltip.
local KIND_ORDER = { "combo", "direct" }
ns.kinds = KINDS

local function detectKind(desc)
    for _, id in ipairs(KIND_ORDER) do
        local ranges = KINDS[id].parse(desc)
        if ranges then return id, ranges end
    end
end

-- Damage over time ("... damage over 12 sec", German "über 12 Sek."): armor doesn't reduce it, its hits are
-- ticks (nothing to learn from), and a lit pip means "dies by the time it runs out", not "dies now".
local function isPeriodic(desc, kind)
    if kind ~= "combo" then return false end -- direct parsing already skips DoT clauses
    return desc ~= nil and (desc:find("over %d") ~= nil or desc:find("über %d") ~= nil)
end

---------------------------------------------------------------------------
-- Tracked spells
---------------------------------------------------------------------------
-- db.spells is the saved list { { name, kind, marker } } in display order, by name so any rank matches. marker:
-- draw the spell's damage on the target's health bar (on unless turned off; combo spells mark the damage at
-- the current combo points).
-- ns.spells is the same list with what this session knows: { name, kind, marker, spellID (highest known rank or
-- nil), icon, periodic, school }. Rows of spells the player doesn't know (other class, not learned yet) stay hidden.

ns.spells = {}
local spellByName = {}

local rangeCache = {} -- spellID -> { ranges, at }
local RANGE_CACHE_SECONDS = 2 -- descriptions can change with attack power

local function rangesFor(spell)
    local spellID = spell.spellID
    if not spellID then return nil end
    local cached = rangeCache[spellID]
    local now = GetTime()
    if cached and now - cached.at < RANGE_CACHE_SECONDS then return cached.ranges end
    local ranges = KINDS[spell.kind].parse(spellDescription(spellID))
    -- Descriptions can be unreadable in combat: keep the last good parse rather than losing the estimate.
    if not ranges and cached then ranges = cached.ranges end
    rangeCache[spellID] = { ranges = ranges, at = now }
    return ranges
end

local function refreshSpells()
    wipe(ns.spells)
    wipe(spellByName)
    for _, saved in ipairs(db.spells) do
        if KINDS[saved.kind] then
            local _, icon, spellID = spellInfo(saved.name)
            local desc = spellDescription(spellID)
            local ranges = KINDS[saved.kind].parse(desc)
            local spell = { name = saved.name, kind = saved.kind, marker = saved.marker ~= false,
                spellID = spellID, icon = icon, periodic = isPeriodic(desc, saved.kind),
                school = ranges and ranges.school or 1 }
            table.insert(ns.spells, spell)
            spellByName[saved.name] = spell
        end
    end
end
ns.refreshSpells = refreshSpells

-- "Eviscerate", "11300", or a shift-clicked spell link. Returns true and a message, or false and why not.
local function addSpell(input)
    local id = tonumber(input:match("|Hspell:(%d+)") or input:match("^(%d+)$"))
    local lookup = id or strtrim((input:gsub("[%[%]]", "")))
    if lookup == "" then return false, "Which spell? /fh add Eviscerate (or shift-click it from your spellbook)" end
    local found = spellInfo(lookup) or (id and spellName(id))
    if not found then return false, "Couldn't find '" .. tostring(lookup) .. "'. Is it in your spellbook?" end
    local name, _, spellID = spellInfo(found) -- the highest rank of it the player knows
    if not spellID then return false, found .. " isn't in your spellbook." end
    if spellByName[name] then return false, name .. " is already tracked." end

    local desc = spellDescription(spellID)
    if not desc then return false, "Can't read " .. name .. "'s tooltip right now. Try again out of combat." end
    local kind = detectKind(desc)
    if not kind then
        return false, name .. " has no fixed damage in its tooltip (weapon-based, damage over time, or no damage), "
            .. "so it can't be predicted."
    end
    table.insert(db.spells, { name = name, kind = kind, marker = true })
    refreshSpells()
    local spell = spellByName[name]
    return true, string.format("Tracking %s (%s%s).", name, KINDS[kind].label,
        spell.periodic and ", damage over time: lit means it dies before the DoT runs out" or "")
end

local function removeSpell(input)
    local index = tonumber(input)
    if not index then
        local wanted = strtrim((input:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|H.-|h", ""):gsub("|[hr]", "")
            :gsub("[%[%]]", ""))):lower()
        for i, saved in ipairs(db.spells) do
            if saved.name:lower() == wanted then index = i end
        end
    end
    local saved = index and db.spells[index]
    if not saved then return false, "Not tracked: " .. input .. " (/fh list shows what is)" end
    table.remove(db.spells, index)
    refreshSpells()
    return true, "Stopped tracking " .. saved.name .. "."
end

-- For the options window (Options.lua). addSpell takes a string: a name, an ID as text, or a link.
ns.addSpell = addSpell
ns.removeSpell = removeSpell

-- Turns tracked spell `index`'s health bar marker on or off.
function ns.setMarker(index, on)
    local saved = db.spells[index]
    if not saved then return end
    saved.marker = on and true or false
    refreshSpells()
end

-- Moves tracked spell `index` up (-1) or down (+1) in the list (and the display's stacking order).
function ns.moveSpell(index, delta)
    local other = index + delta
    if not db.spells[index] or not db.spells[other] then return end
    db.spells[index], db.spells[other] = db.spells[other], db.spells[index]
    refreshSpells()
end

-- How many saved hits (or fights) the spell's estimate has learned from.
function ns.learnedCount(spellName)
    local saved = db.samples[spellName]
    return saved and #saved or 0
end

-- Spellbook entries' spell IDs, from whichever spellbook API this client has.
local function spellbookIDs()
    local ids = {}
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and Enum and Enum.SpellBookSpellBank then
        local okLines, lines = pcall(C_SpellBook.GetNumSpellBookSkillLines)
        for line = 1, (okLines and plainNumber(true, lines)) or 0 do
            local ok, info = pcall(C_SpellBook.GetSpellBookSkillLineInfo, line)
            if ok and type(info) == "table" and info.itemIndexOffset and info.numSpellBookItems then
                for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                    local okItem, item = pcall(C_SpellBook.GetSpellBookItemInfo, i, Enum.SpellBookSpellBank.Player)
                    if okItem and type(item) == "table" and plainNumber(true, item.spellID) and not item.isPassive then
                        table.insert(ids, item.spellID)
                    end
                end
            end
        end
        if #ids > 0 then return ids end
    end
    if GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo then
        local okTabs, tabs = pcall(GetNumSpellTabs)
        for tab = 1, (okTabs and plainNumber(true, tabs)) or 0 do
            local ok, _, _, offset, count = pcall(GetSpellTabInfo, tab)
            if ok and plainNumber(true, offset) and plainNumber(true, count) then
                for i = offset + 1, offset + count do
                    local okItem, itemType, id = pcall(GetSpellBookItemInfo, i, BOOKTYPE_SPELL or "spell")
                    if okItem and itemType == "SPELL" and plainNumber(true, id) then table.insert(ids, id) end
                end
            end
        end
    end
    return ids
end

-- Spells in the player's spellbook that a kind can read and that aren't tracked yet, for the options window's
-- "Add" list: { name, icon, spellID, periodic }, by name, one entry per spell (highest rank).
function ns.candidateSpells()
    local found, list = {}, {}
    for _, id in ipairs(spellbookIDs()) do
        local name = spellName(id)
        if name and not found[name] and not spellByName[name] then
            found[name] = true
            local _, icon, best = spellInfo(name)
            local desc = spellDescription(best or id)
            local kind = detectKind(desc)
            if kind then
                table.insert(list, { name = name, icon = icon, spellID = best or id, kind = kind,
                    periodic = isPeriodic(desc, kind) })
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

---------------------------------------------------------------------------
-- Learning: what a spell really hits for, relative to its tooltip
---------------------------------------------------------------------------
-- Each landed non-crit hit gives ratio = amount / tooltip middle for that entry (combo point count). The ratio
-- carries armor and any attack power the tooltip leaves out, and works for every entry, so a 3-point hit also
-- improves the 5-point estimate. On a mob already hit this session, that mob's ratios are used; otherwise a
-- cautious pick (low quartile) of the saved ones, since other mobs may have more armor.

local mobSamples = {} -- unit key -> spell name -> { ratio, ... } (this session only)

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

-- Returns ratio, a description of where it came from, and true when it's only the guess (no hit seen yet).
local function ratioFor(spell, key)
    if spell.periodic then return 1, "tooltip total (damage over time, armor doesn't reduce it)" end
    local onMob = key and mobSamples[key] and mobSamples[key][spell.name]
    if onMob and #onMob > 0 then
        return mean(onMob), string.format("learned on this mob (%d hit%s)", #onMob, #onMob == 1 and "" or "s")
    end
    local saved = db.samples[spell.name]
    if saved and #saved > 0 then
        return lowQuartile(saved), string.format("learned (%d hit%s)", #saved, #saved == 1 and "" or "s")
    end
    return db.guessFactor, string.format("guess: tooltip x %.2f (no hit seen yet)", db.guessFactor), true
end

-- Saves one ratio for `spell` (and for the mob behind `key`, if given). `note` says what it was learned from.
-- Used by the hit path below and by Meter.lua (the game's damage meter, after a fight).
local function learnRatio(spell, key, ratio, note)
    local saved = db.samples[spell.name] or {}
    db.samples[spell.name] = saved
    table.insert(saved, ratio)
    while #saved > SAMPLES_KEPT do table.remove(saved, 1) end
    if key then
        mobSamples[key] = mobSamples[key] or {}
        local onMob = mobSamples[key][spell.name] or {}
        mobSamples[key][spell.name] = onMob
        table.insert(onMob, ratio)
    end
    trace(string.format("LEARN %s: %s (ratio %.3f to tooltip middle)", spell.name, note, ratio))
end
ns.learnRatio = learnRatio

function ns.forget()
    wipe(db.samples)
    wipe(mobSamples)
end

-- Lowest normal hit of `spell` at entry `n` (combo points) on the target, a source description, and true when
-- it's only guessed from the tooltip (Display greys those). nil if unknown.
-- With useTooltip on, it's the tooltip's minimum as is: learning still runs, but isn't used.
-- 4th result: the same estimate from the tooltip's maximum (the best normal roll), for the "could kill" box.
function ns.estimate(spell, n)
    local ranges = rangesFor(spell)
    local range = ranges and ranges[n]
    if not range then return nil end
    local ratio, source, guessed = 1, "tooltip minimum", false
    if not db.useTooltip then ratio, source, guessed = ratioFor(spell, unitKey("target")) end
    local scale = ratio * (1 - db.margin / 100)
    local low = math.max(0, math.floor(range.min * scale))
    local high = math.max(low, math.floor((range.max or range.min) * scale))
    return low, source, guessed or false, high
end

function ns.tooltipRanges(spell)
    return rangesFor(spell)
end
ns.rangesFor = rangesFor

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

local sentKeys = {}       -- castGUID -> { key, points, at }: the target (and combo points) when the cast was sent
local pendingCast         -- { spell, entry, key, at, hits, seen, hidden, record }: a tracked cast waiting for its hit
-- Hits on targets while a cast waited: how many, and how many had a hidden (secret) amount. For /fh probe.
local hitStats = { seen = 0, hidden = 0 }
local recentHits = {}     -- { key, amount, flag, at }: last fraction of a second of hits, for the look-back
local frameHitsAt, frameHits = nil, {}

local function trackedSpell(spellID)
    local name = spellName(spellID)
    return name and spellByName[name]
end
ns.trackedSpell = trackedSpell

local function onCastSent(castGUID, spellID)
    if isSecret(castGUID) or isSecret(spellID) or not castGUID then return end
    local now = GetTime()
    for guid, sent in pairs(sentKeys) do
        if now - sent.at > 10 then sentKeys[guid] = nil end
    end
    local spell = trackedSpell(spellID)
    local points
    if spell and KINDS[spell.kind].usesPoints then
        points = readComboPoints() or (counted > 0 and counted) or nil -- spent by the time the cast succeeds
    end
    sentKeys[castGUID] = { key = unitKey("target"), points = points, at = now }
end

local function onCastSucceeded(castGUID, spellID)
    if isSecret(spellID) then return end
    local now = GetTime()
    local sent = (castGUID and not isSecret(castGUID)) and sentKeys[castGUID]
    if sent then sentKeys[castGUID] = nil end
    local key = sent and sent.key or unitKey("target")
    local desc = spellDescription(spellID)

    local spell = trackedSpell(spellID)
    if spell then
        local usesPoints = KINDS[spell.kind].usesPoints
        local entry = usesPoints and (sent and sent.points) or (not usesPoints and 1) or nil
        if usesPoints then resetCount() end
        trace(string.format("CAST %s (id %d)%s on %s", spell.name, spellID,
            usesPoints and (" with " .. tostring(entry or "?") .. " combo points") or "", tostring(key)))
        -- DoTs hit in ticks, so there's no single hit to learn from.
        if entry and entry > 0 and key and not spell.periodic then
            entry = math.min(entry, MAX_POINTS)
            pendingCast = { spell = spell, entry = entry, key = key, at = now, hits = {}, seen = 0, hidden = 0,
                record = ns.meter.recordCast(spell, entry, key) } -- the damage meter's fallback, if no hit is readable
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

-- Picks the spell's hit out of what landed around the cast (white hits land too) and learns from it: the
-- largest plausible non-glancing hit of the spell's school.
local function resolvePending()
    local cast = pendingCast
    pendingCast = nil
    local ranges = rangesFor(cast.spell)
    local range = ranges and ranges[cast.entry]
    if not range then
        trace("SKIP learning: no tooltip range for entry " .. cast.entry)
        return
    end
    local middle = (range.min + range.max) / 2
    local best
    for _, hit in ipairs(cast.hits) do
        local plausible = hit.amount >= middle * PLAUSIBLE_MIN and hit.amount <= middle * PLAUSIBLE_MAX
            and (hit.school == nil or hit.school == cast.spell.school)
        if plausible and hit.flag ~= "GLANCING" and (not best or hit.amount > best.amount) then best = hit end
    end
    if not best then
        trace(string.format("SKIP hit learning: %d hit(s) on the target, %d with hidden amounts%s", cast.seen,
            cast.hidden, cast.hidden > 0 and " (the damage meter will try after the fight)" or ""))
        return
    end
    if best.flag == "CRITICAL" then
        trace("SKIP learning: the hit was a crit (" .. best.amount .. ")")
        return
    end
    learnRatio(cast.spell, cast.key, best.amount / middle, string.format("%d points hit %d", cast.entry, best.amount))
    cast.record.learned = true -- so the damage meter doesn't count this cast a second time
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
            trace("CAST " .. pendingCast.spell.name .. " " .. action)
        end
        return
    end
    if action ~= "WOUND" then return end
    if lastBuilder and lastBuilder.key == key then lastBuilder = nil end
    local hidden = isSecret(amount) or type(amount) ~= "number"
    if pendingCast and pendingCast.key == key and unit == "target" then
        pendingCast.seen, hitStats.seen = pendingCast.seen + 1, hitStats.seen + 1
        if hidden then pendingCast.hidden, hitStats.hidden = pendingCast.hidden + 1, hitStats.hidden + 1 end
    end
    if hidden then return end
    local plainSchool = (not isSecret(school) and type(school) == "number") and school or nil
    local plainFlag = (not isSecret(flag)) and flag or ""

    -- The same hit fires for target, nameplateN, softenemy...: take it once per frame.
    if frameHitsAt ~= now then frameHitsAt, frameHits = now, {} end
    local signature = key .. ":" .. amount .. ":" .. tostring(plainFlag)
    if frameHits[signature] then return end
    frameHits[signature] = true

    local hit = { key = key, amount = amount, flag = plainFlag, school = plainSchool, at = now }
    table.insert(recentHits, hit)
    while recentHits[1] and now - recentHits[1].at > HIT_LOOKBACK do table.remove(recentHits, 1) end
    if pendingCast and pendingCast.key == key then table.insert(pendingCast.hits, hit) end
end

function ns.housekeep(now)
    if pendingCast and now - pendingCast.at > HIT_WINDOW then resolvePending() end
end

---------------------------------------------------------------------------
-- Saved settings
---------------------------------------------------------------------------

local function loadSettings()
    FinishHimDB = FinishHimDB or {}
    db = FinishHimDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    db.samples = db.samples or {}
    db.log = db.log or {}
    ns.db = db
end

-- First run (or v0.1.0, which only knew Eviscerate): track Eviscerate. Its name comes from the client, so this
-- waits for PLAYER_LOGIN. v0.1.0 saved Eviscerate's hits under the English name.
local function ensureSpellList()
    if db.spells then return end
    db.spells = {}
    local name = spellName(EVISCERATE_ID)
    if not name then return end
    table.insert(db.spells, { name = name, kind = "combo" })
    if name ~= "Eviscerate" and db.samples.Eviscerate then
        db.samples[name], db.samples.Eviscerate = db.samples.Eviscerate, nil
    end
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

local loggedIn = false

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        loadSettings()
        trace("===== session start =====")
        self:UnregisterEvent("ADDON_LOADED")
    elseif not db then
        return
    elseif event == "PLAYER_LOGIN" or event == "SPELLS_CHANGED" then
        if event == "PLAYER_LOGIN" then
            loggedIn = true
            ensureSpellList()
        end
        if not loggedIn then return end
        refreshSpells() -- new ranks, spells learned
        ns.display.setup()
        ns.refreshOptions()
    elseif not loggedIn then
        return
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
    "/fh - open the options window (or right-click the pips)",
    "/fh add <spell> - track a spell: combo point or single cast (name, or shift-click it from your spellbook)",
    "/fh remove <spell or number> - stop tracking a spell",
    "/fh list - show the tracked spells",
    "/fh lock | unlock - lock the pips, or unlock to drag them",
    "/fh reset - put the pips back above the target frame",
    "/fh scale <0.5-3> - size of the pips",
    "/fh tooltip - toggle using the tooltip's minimum as is (on) or learned damage (off)",
    "/fh margin <0-50> - take this % off every estimate (extra careful)",
    "/fh guess <0.3-1.5> - tooltip multiplier used until a real hit is seen (default 0.75)",
    "/fh numbers - show/hide the damage under each pip",
    "/fh markers - show/hide the damage markers on the target's health bar",
    "/fh dots - also count DoesItDie's remaining DoT damage (dies eventually, not instantly)",
    "/fh test - light everything up for 10 seconds",
    "/fh probe - print tooltips, combo point readings and estimates",
    "/fh forget - forget learned hits",
    "/fh debug - print the log to chat as it happens",
    "/fh toggle - turn the addon on/off",
}

local function probe()
    refreshSpells()
    if #ns.spells == 0 then print("No spells tracked (/fh add <spell>).") end
    for _, spell in ipairs(ns.spells) do
        print(string.format("%s (%s): known rank id %s%s", spell.name, spell.kind, tostring(spell.spellID),
            spell.periodic and ", damage over time" or ""))
        local desc = spellDescription(spell.spellID)
        print("Tooltip: " .. (desc and desc:gsub("\r?\n", " / ") or "unreadable"))
        local ranges = ns.tooltipRanges(spell)
        for n = 1, KINDS[spell.kind].pips do
            local range = ranges and ranges[n]
            local estimate, source = ns.estimate(spell, n)
            print(string.format("  %d: tooltip %s, estimate %s (%s)", n,
                range and (range.min .. "-" .. range.max) or "?", tostring(estimate or "?"), source or "-"))
        end
    end
    local _, readings = readComboPoints()
    print("Combo points: " .. readings)
    print(string.format("Hits right after your casts: %d seen, %d with hidden amounts", hitStats.seen, hitStats.hidden))
    print("Damage meter: " .. ns.meter.status())
    print("Health bar markers: " .. ns.display.markerStatus())
    local ok, health = pcall(UnitHealth, "target")
    print("Target health: " .. (not ok and "error" or isSecret(health) and "secret" or tostring(health)))
end

SLASH_FINISHHIM1 = "/fh"
SLASH_FINISHHIM2 = "/finishhim"
SlashCmdList.FINISHHIM = function(msg)
    if not db then return end
    -- Only the command is lowercased: spell names and links keep their case.
    local cmd, arg = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    local number = tonumber(arg)
    if cmd == "" or cmd == "options" or cmd == "config" then
        ns.openOptions()
    elseif cmd == "add" or cmd == "remove" then
        local ok, message = (cmd == "add" and addSpell or removeSpell)(arg)
        print(message)
        if ok then
            ns.display.setup()
            ns.refreshOptions()
        end
    elseif cmd == "list" then
        if #db.spells == 0 then print("No spells tracked (/fh add <spell>).") end
        for i, saved in ipairs(db.spells) do
            local spell = spellByName[saved.name]
            print(string.format("%d. %s (%s)%s", i, saved.name, saved.kind,
                (spell and spell.spellID) and "" or " - not in your spellbook, hidden"))
        end
    elseif cmd == "lock" or cmd == "unlock" then
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
    elseif cmd == "tooltip" then
        db.useTooltip = not db.useTooltip
        print(db.useTooltip and "Using the tooltip's minimum damage as is."
            or "Using learned damage (tooltip x what your hits did).")
        ns.display.setup()
        if ns.refreshOptions then ns.refreshOptions() end
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
    elseif cmd == "markers" then
        db.showMarkers = not db.showMarkers
        ns.display.setup()
        print("Health bar markers " .. onOff(db.showMarkers))
    elseif cmd == "dots" then
        db.includeDots = not db.includeDots
        print("Counting DoesItDie's DoT damage " .. onOff(db.includeDots)
            .. (type(DoesItDie) == "table" and "" or " (DoesItDie isn't loaded, so this does nothing)"))
    elseif cmd == "test" then
        ns.display.test(10)
    elseif cmd == "probe" then
        probe()
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
