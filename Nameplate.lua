-- FinishHim on the target's nameplate (Plater's, or Blizzard's): small round combo dots above the health bar
-- for the first tracked combo point spell, and the damage marker at the end of the health fill for every spell
-- with its marker on. Combo points only count on the current target, so only the target's plate is drawn.
--
-- Same secret-value tricks as Display.lua:
-- - Each dot has two clipped kill windows (StatusBars with max = health, value = damage): yellow for the
--   tooltip's maximum, red for its minimum.
-- - The marker is a reverse-fill StatusBar pinned to our own invisible health mirror's fill edge.
-- The widgets are parented to the nameplate, so they move, scale and hide with it. Their level comes from the
-- health bar (or a fallback when it's secret), and their strata matches Plater's bar.

local ADDON_NAME, ns = ...

local WHITE = "Interface\\Buttons\\WHITE8X8"
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local BAR_LENGTH = 10000
local MAX_DOTS = 5
local DOT_GAP = 3
local FALLBACK_LEVEL = 200
local UPDATE_INTERVAL = 0.1
local OWNED_COLOR = { 1, 0.78, 0.1 }
local EMPTY_COLOR = { 0.32, 0.32, 0.34 }

local plate = {}
ns.plate = plate

local function isSecret(v) return ns.isSecret(v) end

local function isStatusBar(value)
    if type(value) ~= "table" or type(value.GetObjectType) ~= "function" then return false end
    local ok, kind = pcall(value.GetObjectType, value)
    return ok and kind == "StatusBar"
end

local function shown(frame)
    local ok, visible = pcall(frame.IsVisible, frame)
    if not ok or isSecret(visible) then return true end
    if not visible then return false end
    local okAlpha, alpha = pcall(frame.GetEffectiveAlpha, frame)
    return not (okAlpha and type(alpha) == "number" and not isSecret(alpha) and alpha <= 0)
end

-- The target's nameplate, its health bar, and where the bar was found.
local function findTargetPlate()
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
    local ok, namePlate = pcall(C_NamePlate.GetNamePlateForUnit, "target")
    if not ok or not namePlate then return nil end
    local okForbidden, forbidden = pcall(function() return namePlate.IsForbidden and namePlate:IsForbidden() end)
    if not okForbidden or forbidden then return nil end
    -- Plater: plate.unitFrame.healthBar (lowercase unitFrame; Blizzard's is UnitFrame).
    local platerFrame = namePlate.unitFrame
    local platerBar = type(platerFrame) == "table" and platerFrame.healthBar
    if isStatusBar(platerBar) and shown(platerBar) then return namePlate, platerBar, "Plater" end
    local blizzard = namePlate.UnitFrame
    local bar = blizzard and (blizzard.healthBar or (blizzard.HealthBarsContainer and blizzard.HealthBarsContainer.healthBar))
    if isStatusBar(bar) and shown(bar) then return namePlate, bar, "Blizzard" end
    return namePlate, nil, "no health bar found"
end

---------------------------------------------------------------------------
-- Widgets (one set, moved to whichever plate is the target's)
---------------------------------------------------------------------------

local widgets -- created on first use
local lastWhere = "not drawn yet"

local function killWindow(parent, size, r, g, b, a)
    local window = CreateFrame("Frame", nil, parent)
    window:SetSize(size, size)
    window:SetClipsChildren(true)
    local bar = CreateFrame("StatusBar", nil, window)
    bar:SetStatusBarTexture(WHITE)
    bar:SetStatusBarColor(0, 0, 0, 0)
    bar:SetSize(BAR_LENGTH, size)
    bar:SetPoint("RIGHT", window, "RIGHT")
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local lit = bar:CreateTexture(nil, "ARTWORK")
    lit:SetTexture(CIRCLE)
    lit:SetVertexColor(r, g, b, a)
    lit:SetSize(size, size)
    lit:SetPoint("RIGHT", bar:GetStatusBarTexture(), "RIGHT")
    return window, bar, lit
end

local function createDot(parent, size)
    local dot = { frame = CreateFrame("Frame", nil, parent) }
    local f = dot.frame
    f:SetSize(size, size)
    dot.glow = f:CreateTexture(nil, "BACKGROUND", nil, -3)
    dot.glow:SetTexture(CIRCLE)
    dot.glow:SetPoint("TOPLEFT", -4, 4)
    dot.glow:SetPoint("BOTTOMRIGHT", 4, -4)
    dot.glow:SetVertexColor(1, 0.75, 0.1, 0.4)
    dot.glow:SetBlendMode("ADD")
    dot.ring = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    dot.ring:SetTexture(CIRCLE)
    dot.ring:SetPoint("TOPLEFT", -1.5, 1.5)
    dot.ring:SetPoint("BOTTOMRIGHT", 1.5, -1.5)
    local back = f:CreateTexture(nil, "BACKGROUND")
    back:SetTexture(CIRCLE)
    back:SetAllPoints()
    back:SetVertexColor(0.07, 0.07, 0.08, 0.95)
    dot.maxWindow, dot.maxBar = killWindow(f, size, 0.9, 0.68, 0, 0.95)
    dot.maxWindow:SetAllPoints()
    dot.window, dot.bar, dot.lit = killWindow(f, size, 0.8, 0.08, 0.06, 1)
    dot.window:SetAllPoints()
    local skull = dot.bar:CreateTexture(nil, "OVERLAY")
    skull:SetTexture(SKULL)
    skull:SetSize(size - 3, size - 3)
    skull:SetPoint("CENTER", dot.lit, "CENTER")
    skull:SetAlpha(0.6)
    local shineFrame = CreateFrame("Frame", nil, f)
    shineFrame:SetAllPoints()
    dot.shineFrame = shineFrame
    local shine = shineFrame:CreateTexture(nil, "ARTWORK")
    shine:SetTexture(CIRCLE)
    shine:SetSize(size * 0.55, size * 0.3)
    shine:SetPoint("TOP", f, "TOP", 0, -1)
    shine:SetVertexColor(1, 1, 1, 0.16)
    return dot
end

local function createMarker(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(WHITE)
    bar:SetStatusBarColor(0, 0, 0, 0)
    if bar.SetReverseFill then bar:SetReverseFill(true) end
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local span = bar:GetStatusBarTexture()
    local fill = bar:CreateTexture(nil, "ARTWORK")
    fill:SetAllPoints(span)
    local edge = bar:CreateTexture(nil, "OVERLAY")
    edge:SetPoint("TOPLEFT", span, "TOPLEFT")
    edge:SetPoint("BOTTOMLEFT", span, "BOTTOMLEFT")
    edge:SetWidth(1)
    return { bar = bar, fill = fill, edge = edge }
end

local function createWidgets()
    local w = {}
    w.dotsFrame = CreateFrame("Frame", nil, UIParent)
    w.dots = {}
    -- The marker: a clip over the health bar, our own health mirror, and one chunk per marked spell.
    w.clip = CreateFrame("Frame", nil, UIParent)
    w.clip:SetClipsChildren(true)
    w.mirror = CreateFrame("StatusBar", nil, w.clip)
    w.mirror:SetAllPoints(w.clip)
    w.mirror:SetStatusBarTexture(WHITE)
    w.mirror:SetStatusBarColor(0, 0, 0, 0)
    w.mirror:SetMinMaxValues(0, 1)
    w.mirror:SetValue(1)
    w.healthEnd = w.mirror:GetStatusBarTexture()
    w.markers = {}
    return w
end

local function layoutDots(w, size)
    if w.dotSize ~= size then
        -- Dot size changed: rebuild (sizes are baked into the kill windows).
        for _, dot in ipairs(w.dots) do dot.frame:Hide() end
        w.dots = {}
        for i = 1, MAX_DOTS do w.dots[i] = createDot(w.dotsFrame, size) end
        w.dotSize = size
        w.level = nil -- re-layer the new frames
    end
    w.dotsFrame:SetSize(MAX_DOTS * size + (MAX_DOTS - 1) * DOT_GAP, size)
    for i, dot in ipairs(w.dots) do
        dot.frame:ClearAllPoints()
        dot.frame:SetPoint("LEFT", w.dotsFrame, "LEFT", (i - 1) * (size + DOT_GAP), 0)
    end
end

-- Parents and anchors the widgets to the target's plate and its health bar, layered above the bar.
local function attach(w, namePlate, healthBar, where)
    if w.healthBar ~= healthBar or w.namePlate ~= namePlate then
        w.namePlate, w.healthBar = namePlate, healthBar
        w.dotsFrame:SetParent(namePlate)
        w.clip:SetParent(namePlate)
        w.clip:ClearAllPoints()
        w.clip:SetAllPoints(healthBar)
        w.level = nil
    end
    local db = ns.db
    w.dotsFrame:ClearAllPoints()
    w.dotsFrame:SetPoint("BOTTOM", healthBar, "TOP", 0, db.plateDotsOffset or 4)

    local okLevel, level = pcall(healthBar.GetFrameLevel, healthBar)
    if not okLevel or isSecret(level) or type(level) ~= "number" then level = FALLBACK_LEVEL end
    local okStrata, strata = pcall(healthBar.GetFrameStrata, healthBar)
    if not okStrata or isSecret(strata) or type(strata) ~= "string" then strata = nil end
    if w.level == level and w.strata == strata then return end
    w.level, w.strata = level, strata
    -- Strata first: setting it resets the level.
    if strata then
        w.clip:SetFrameStrata(strata)
        w.dotsFrame:SetFrameStrata(strata)
    end
    w.clip:SetFrameLevel(level + 3)
    w.mirror:SetFrameLevel(level + 4)
    for i, marker in ipairs(w.markers) do
        if strata then marker.bar:SetFrameStrata(strata) end
        marker.bar:SetFrameLevel(level + 5 + i)
    end
    w.dotsFrame:SetFrameLevel(level + 15)
    for _, dot in ipairs(w.dots) do
        dot.frame:SetFrameLevel(level + 16)
        dot.maxWindow:SetFrameLevel(level + 17)
        dot.window:SetFrameLevel(level + 18)
        dot.shineFrame:SetFrameLevel(level + 20)
    end
    lastWhere = where
end

local function hideAll()
    if not widgets then return end
    widgets.dotsFrame:Hide()
    widgets.clip:Hide()
end

local function setDot(dot, owned, current)
    local color = owned and OWNED_COLOR or EMPTY_COLOR
    dot.ring:SetVertexColor(color[1], color[2], color[3], 1)
    dot.glow:SetShown(current)
end

-- entries: { damage, colorIndex }, biggest first so smaller chunks draw on top. maxHealth/health may be secret.
local function drawMarkers(w, entries, maxHealth, health)
    table.sort(entries, function(a, b) return a.damage > b.damage end)
    w.mirror:SetMinMaxValues(0, maxHealth)
    w.mirror:SetValue(health)
    for i, entry in ipairs(entries) do
        local marker = w.markers[i]
        if not marker then
            marker = createMarker(w.clip)
            w.markers[i] = marker
            marker.bar:SetPoint("TOPRIGHT", w.healthEnd, "TOPRIGHT")
            marker.bar:SetPoint("BOTTOMRIGHT", w.healthEnd, "BOTTOMRIGHT")
            w.level = nil -- layer it on the next attach
        end
        local okWidth, width = pcall(w.clip.GetWidth, w.clip)
        if okWidth and type(width) == "number" and not isSecret(width) then marker.bar:SetWidth(width) end
        local color = ns.display.markerColor(entry.colorIndex)
        marker.fill:SetColorTexture(color[1], color[2], color[3], 0.55)
        marker.edge:SetColorTexture(color[1], color[2], color[3], 1)
        marker.bar:SetMinMaxValues(0, maxHealth)
        marker.bar:SetValue(entry.damage)
        marker.bar:Show()
    end
    for i = #entries + 1, #w.markers do w.markers[i].bar:Hide() end
    w.clip:SetShown(#entries > 0)
end

---------------------------------------------------------------------------
-- Update
---------------------------------------------------------------------------

local function targetAttackable()
    if not UnitExists("target") then return false end
    local okDead, dead = pcall(UnitIsDead, "target")
    if okDead and not isSecret(dead) and dead then return false end
    local ok, attackable = pcall(UnitCanAttack, "player", "target")
    if ok and not isSecret(attackable) then return attackable end
    return true
end

local function update()
    local db = ns.db
    if not (db and db.enabled and (db.plateDots or db.plateMarker)) then return hideAll() end
    local testing = ns.display.testing and ns.display.testing()
    if not testing and not targetAttackable() then return hideAll() end
    local namePlate, healthBar, where = findTargetPlate()
    if not healthBar then
        lastWhere = namePlate and where or "target has no nameplate"
        return hideAll()
    end
    widgets = widgets or createWidgets()
    local w = widgets
    layoutDots(w, db.plateDotSize or 11)
    attach(w, namePlate, healthBar, where)

    local current = ns.comboPoints()
    local dots = ns.dotDamage()
    local comboSpell, markerEntries = nil, {}
    for i, spell in ipairs(ns.spells) do
        if spell.spellID then
            local kind = ns.kinds[spell.kind]
            if kind.usesPoints and not comboSpell then comboSpell = spell end
            if db.plateMarker and db.showMarkers and spell.marker then
                local n = kind.usesPoints and current or 1
                local damage = testing and (0.3 / (#markerEntries + 1)) or (n >= 1 and ns.estimate(spell, n))
                if damage and damage > 0 then table.insert(markerEntries, { damage = damage, colorIndex = i }) end
            end
        end
    end

    -- Dots
    if db.plateDots and comboSpell then
        local health = testing and 1 or UnitHealth("target")
        for i, dot in ipairs(w.dots) do
            local low, high
            if testing then
                low, high = (i >= 3) and 1 or 0, (i >= 2) and 1 or 0
            else
                local estimate, _, _, best = ns.estimate(comboSpell, i)
                low = estimate and (estimate + dots) or 0
                high = best and (best + dots) or 0
            end
            dot.bar:SetMinMaxValues(0, health)
            dot.bar:SetValue(low)
            dot.maxBar:SetMinMaxValues(0, health)
            dot.maxBar:SetValue(high)
            local shownPoints = testing and 3 or current
            setDot(dot, i <= shownPoints, i == shownPoints)
        end
        w.dotsFrame:Show()
    else
        w.dotsFrame:Hide()
    end

    -- Marker
    if #markerEntries > 0 then
        if testing then
            drawMarkers(w, markerEntries, 1, 1)
        else
            drawMarkers(w, markerEntries, UnitHealthMax("target"), UnitHealth("target"))
        end
    else
        w.clip:Hide()
    end
end

-- For /fh probe.
function plate.status()
    local db = ns.db
    local parts = { (db.plateDots or db.plateMarker) and "on" or "off" }
    local namePlate, healthBar, where = findTargetPlate()
    if not namePlate then
        table.insert(parts, "target has no nameplate")
    else
        table.insert(parts, healthBar and ("health bar: " .. where) or where)
    end
    table.insert(parts, "last drawn on: " .. lastWhere)
    if widgets then
        table.insert(parts, string.format("dots %s, marker %s, level %s/%s",
            widgets.dotsFrame:IsShown() and "shown" or "hidden", widgets.clip:IsShown() and "shown" or "hidden",
            tostring(widgets.strata), tostring(widgets.level)))
    end
    return table.concat(parts, "; ")
end

local driver = CreateFrame("Frame")
local sinceUpdate = 0
local reportedError = false
driver:SetScript("OnUpdate", function(_, elapsed)
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate < UPDATE_INTERVAL then return end
    sinceUpdate = 0
    if not ns.db then return end
    local ok, err = pcall(update)
    if not ok then
        hideAll()
        if not reportedError then
            reportedError = true
            ns.print("Nameplate display error: " .. tostring(err))
        end
        if ns.trace then ns.trace("ERROR nameplate: " .. tostring(err)) end
    end
end)
