-- FinishHim display: a row of five pips above the target frame, one per combo point count. Pip N lights up
-- (red, with a skull) when Eviscerate with N points would kill the target, so the lowest lit pip is the fewest
-- points you need. The pip for your current points has a gold border, and the big skull on the left lights up
-- when Eviscerate kills right now.
--
-- Target health is secret, so Lua can't compare it with the damage. Each pip is a StatusBar instead (the trick
-- DoesItDie uses for its kill icon): max = target health, value = estimated damage. The bar is very long and
-- only its last pip-width shows through a clipping frame; the lit texture rides the fill's right edge, so it's
-- in view only when the fill reaches the end, i.e. damage >= health.

local ADDON_NAME, ns = ...

local WHITE = "Interface\\Buttons\\WHITE8X8"
local SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local BAR_LENGTH = 10000 -- a pip starts lighting PIP / BAR_LENGTH (~0.25%) of health short of lethal
local PIP = 24
local GAP = 4
local BIG = 34
local MAX_POINTS = 5
local UPDATE_INTERVAL = 0.1

local display = {}
ns.display = display

local row = CreateFrame("Frame", "FinishHimFrame", UIParent)
row:SetFrameStrata("HIGH")
row:SetClampedToScreen(true)
row:SetMovable(true)
row:EnableMouse(true)
row:SetSize(BIG + GAP * 2 + MAX_POINTS * (PIP + GAP), BIG + 12)
row:Hide()

-- A clipped kill window: `bar` (max = health, value = damage) and its `lit` texture, visible only when lethal.
local function killWindow(parent, size)
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
    lit:SetSize(size, size)
    lit:SetPoint("RIGHT", bar:GetStatusBarTexture(), "RIGHT")
    return window, bar, lit
end

-- Big skull: lethal with the points you have now.
local bigBack = row:CreateTexture(nil, "BACKGROUND")
bigBack:SetSize(BIG, BIG)
bigBack:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
bigBack:SetColorTexture(0, 0, 0, 0.35)
local bigWindow, bigBar, bigSkull = killWindow(row, BIG)
bigWindow:SetAllPoints(bigBack)
bigSkull:SetTexture(SKULL)

local pips = {}
for i = 1, MAX_POINTS do
    local pip = CreateFrame("Frame", nil, row)
    pip:SetSize(PIP, PIP)
    pip:SetPoint("LEFT", bigBack, "RIGHT", GAP * 2 + (i - 1) * (PIP + GAP), 0)

    local border = pip:CreateTexture(nil, "BACKGROUND", nil, -1)
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", 2, -2)
    local back = pip:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints()
    back:SetColorTexture(0.08, 0.08, 0.08, 0.85)

    local window, bar, lit = killWindow(pip, PIP)
    window:SetAllPoints()
    lit:SetColorTexture(0.75, 0.08, 0.08, 0.95)
    local skull = bar:CreateTexture(nil, "OVERLAY")
    skull:SetTexture(SKULL)
    skull:SetSize(PIP - 6, PIP - 6)
    skull:SetPoint("CENTER", lit, "CENTER")
    skull:SetAlpha(0.55)

    -- Labels sit on a frame above the kill window so they read in both states.
    local labels = CreateFrame("Frame", nil, pip)
    labels:SetAllPoints()
    labels:SetFrameLevel(window:GetFrameLevel() + 5)
    local number = labels:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    number:SetPoint("CENTER", 0, 0)
    number:SetText(i)
    local damage = labels:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    damage:SetPoint("TOP", pip, "BOTTOM", 0, -3)

    pips[i] = { frame = pip, border = border, bar = bar, damage = damage }
end

---------------------------------------------------------------------------
-- Position, dragging, tooltip
---------------------------------------------------------------------------

row:RegisterForDrag("LeftButton")
row:SetScript("OnDragStart", function(self)
    if ns.db and not ns.db.locked then self:StartMoving() end
end)
row:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, x, y = self:GetPoint()
    ns.db.point = { point, relativePoint, x, y }
end)

row:SetScript("OnEnter", function(self)
    local finisher = ns.finishers[1]
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("FinishHim: " .. finisher.key)
    local current, source = ns.comboPoints()
    GameTooltip:AddLine(string.format("Combo points: %d (%s)", current, source), 1, 1, 1)
    local lastSource
    for points = 1, MAX_POINTS do
        local estimate, from = ns.estimate(finisher, points)
        GameTooltip:AddDoubleLine(points .. (points == 1 and " point" or " points"),
            estimate and (estimate .. " or more") or "?", 1, 1, 1, 1, 1, 1)
        lastSource = from or lastSource
    end
    if lastSource then GameTooltip:AddLine("Estimate: " .. lastSource, 0.7, 0.7, 0.7, true) end
    local dots = ns.dotDamage()
    if dots > 0 then GameTooltip:AddLine(string.format("+ %d from your DoTs (DoesItDie)", dots), 0.7, 0.7, 0.7) end
    GameTooltip:AddLine("Lowest normal hit, no crit. A dodge or parry still saves it.", 0.7, 0.7, 0.7, true)
    if not ns.db.locked then GameTooltip:AddLine("Unlocked: drag to move, /fh lock when done.", 0.4, 1, 0.4) end
    GameTooltip:Show()
end)
row:SetScript("OnLeave", function() GameTooltip:Hide() end)

function display.setup()
    local db = ns.db
    if not db then return end
    row:SetScale(db.scale)
    row:ClearAllPoints()
    if db.point then
        row:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4])
    elseif TargetFrame then
        row:SetPoint("BOTTOM", TargetFrame, "TOP", 0, 0)
    else
        row:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
    end
    for _, pip in ipairs(pips) do pip.damage:SetShown(db.showNumbers) end
    display.refresh()
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local testUntil
local reportedError

local function targetAttackable()
    if not UnitExists("target") then return false end
    local okDead, dead = pcall(UnitIsDead, "target")
    if okDead and not ns.isSecret(dead) and dead then return false end
    local ok, attackable = pcall(UnitCanAttack, "player", "target")
    if ok and not ns.isSecret(attackable) then return attackable end
    return true -- can't tell: show it
end

local function setBorder(pip, current)
    if current then
        pip.border:SetColorTexture(1, 0.82, 0, 1)
    else
        pip.border:SetColorTexture(0.3, 0.3, 0.3, 0.9)
    end
end

local function update()
    local db = ns.db
    if testUntil then
        if GetTime() < testUntil then
            for i, pip in ipairs(pips) do
                pip.bar:SetMinMaxValues(0, 1)
                pip.bar:SetValue(1)
                pip.damage:SetText(i * 100)
                setBorder(pip, i == 3)
            end
            bigBar:SetMinMaxValues(0, 1)
            bigBar:SetValue(1)
            row:Show()
            return
        end
        testUntil = nil
    end

    local finisher = ns.finishers[1]
    if not db.enabled or not ns.activeRank(finisher) or not targetAttackable() then
        row:Hide()
        return
    end

    local current, source = ns.comboPoints()
    local dots = ns.dotDamage()
    local estimates = {}
    for points = 1, MAX_POINTS do estimates[points] = ns.estimate(finisher, points) end

    for i, pip in ipairs(pips) do
        pip.damage:SetText(estimates[i] or "?")
        pip.frame:SetAlpha(estimates[i] and 1 or 0.4)
        setBorder(pip, i == current)
    end
    -- Counted points may be off by one: the big skull is dimmer then.
    bigWindow:SetAlpha(source == "read" and 1 or 0.6)

    local ok, err = pcall(function()
        local health = UnitHealth("target")
        for i, pip in ipairs(pips) do
            pip.bar:SetMinMaxValues(0, health)
            pip.bar:SetValue(estimates[i] and (estimates[i] + dots) or 0)
        end
        local now = current >= 1 and estimates[current]
        bigBar:SetMinMaxValues(0, health)
        bigBar:SetValue(now and (now + dots) or 0)
    end)
    if not ok then
        if not reportedError then
            reportedError = true
            ns.print("Display update failed: " .. tostring(err))
        end
        ns.trace("ERROR display: " .. tostring(err))
        row:Hide()
        return
    end
    row:Show()
end

function display.refresh()
    if not ns.db then return end
    ns.housekeep(GetTime())
    local ok, err = pcall(update)
    if not ok and not reportedError then
        reportedError = true
        ns.print("Display error: " .. tostring(err))
    end
end

function display.test(seconds)
    testUntil = GetTime() + seconds
    display.refresh()
end

local driver = CreateFrame("Frame")
local sinceUpdate = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate < UPDATE_INTERVAL then return end
    sinceUpdate = 0
    display.refresh()
end)
