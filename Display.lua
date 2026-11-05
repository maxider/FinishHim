-- FinishHim display: one row per tracked spell, stacked above the target frame (the first spell sits lowest).
-- A row is the spell's icon, a big skull, and one pip per entry: for combo point spells, one per point count.
-- Pip N lights up (red, with a skull) when the spell with N points would kill the target, so the lowest lit pip
-- is the fewest points you need. The pip for your current points has a gold border, and the big skull lights up
-- when the spell kills right now. Spells the player doesn't know have no row.
--
-- Target health is secret, so Lua can't compare it with the damage. Each pip is a StatusBar instead (the trick
-- DoesItDie uses for its kill icon): max = target health, value = estimated damage. The bar is very long and
-- only its last pip-width shows through a clipping frame; the lit texture rides the fill's right edge, so it's
-- in view only when the fill reaches the end, i.e. damage >= health.

local ADDON_NAME, ns = ...

local WHITE = "Interface\\Buttons\\WHITE8X8"
local SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local BAR_LENGTH = 10000 -- a pip starts lighting PIP / BAR_LENGTH (~0.25%) of health short of lethal
local PIP = 24
local GAP = 4
local BIG = 34
local ICON = 22
local MAX_PIPS = 5
local ROW_WIDTH = ICON + GAP + BIG + GAP * 2 + MAX_PIPS * (PIP + GAP)
local ROW_HEIGHT = BIG + 14 -- room for the damage numbers under the pips
local UPDATE_INTERVAL = 0.1
local LEARNED_COLOR = { 1, 0.82, 0 }   -- damage numbers once a real hit has been seen
local GUESSED_COLOR = { 0.55, 0.55, 0.55 } -- still the tooltip guess

local display = {}
ns.display = display

-- Holds the rows; this is what moves when dragged.
local container = CreateFrame("Frame", "FinishHimFrame", UIParent)
container:SetFrameStrata("HIGH")
container:SetClampedToScreen(true)
container:SetMovable(true)
container:SetSize(ROW_WIDTH, ROW_HEIGHT)
container:Hide()

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

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local rows = {} -- one per entry of ns.spells, created as needed

local function showTooltip(row)
    local spell = row.spell
    if not spell then return end
    local kind = ns.kinds[spell.kind]
    GameTooltip:SetOwner(row, "ANCHOR_TOP")
    GameTooltip:AddLine("FinishHim: " .. spell.name)
    if kind.usesPoints then
        local current, source = ns.comboPoints()
        GameTooltip:AddLine(string.format("Combo points: %d (%s)", current, source), 1, 1, 1)
    end
    local lastSource
    for n = 1, kind.pips do
        local estimate, from = ns.estimate(spell, n)
        local left = kind.usesPoints and (n .. (n == 1 and " point" or " points")) or "Damage"
        GameTooltip:AddDoubleLine(left, estimate and (estimate .. " or more") or "?", 1, 1, 1, 1, 1, 1)
        lastSource = from or lastSource
    end
    if lastSource then GameTooltip:AddLine("Estimate: " .. lastSource, 0.7, 0.7, 0.7, true) end
    local dots = ns.dotDamage()
    if dots > 0 then GameTooltip:AddLine(string.format("+ %d from your DoTs (DoesItDie)", dots), 0.7, 0.7, 0.7) end
    if spell.periodic then
        GameTooltip:AddLine("Damage over time: lit means it dies before the DoT runs out, not instantly.",
            1, 0.82, 0, true)
    else
        GameTooltip:AddLine("Lowest normal hit, no crit. A dodge or parry still saves it.", 0.7, 0.7, 0.7, true)
    end
    if not ns.db.locked then GameTooltip:AddLine("Unlocked: drag to move, /fh lock when done.", 0.4, 1, 0.4) end
    GameTooltip:Show()
end

local function createRow()
    local row = CreateFrame("Frame", nil, container)
    row:SetSize(ROW_WIDTH, ROW_HEIGHT)
    row:EnableMouse(true)
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", function()
        if not ns.db.locked then container:StartMoving() end
    end)
    row:SetScript("OnDragStop", function()
        container:StopMovingOrSizing()
        local point, _, relativePoint, x, y = container:GetPoint()
        ns.db.point = { point, relativePoint, x, y }
    end)
    row:SetScript("OnEnter", showTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local bigBack = row:CreateTexture(nil, "BACKGROUND")
    bigBack:SetSize(BIG, BIG)
    bigBack:SetPoint("TOPLEFT", row, "TOPLEFT", ICON + GAP, 0)
    bigBack:SetColorTexture(0, 0, 0, 0.35)
    local bigWindow, bigBar, bigSkull = killWindow(row, BIG)
    bigWindow:SetAllPoints(bigBack)
    bigSkull:SetTexture(SKULL)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON, ICON)
    icon:SetPoint("RIGHT", bigBack, "LEFT", -GAP, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local pips = {}
    for i = 1, MAX_PIPS do
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

    return { frame = row, icon = icon, bigWindow = bigWindow, bigBar = bigBar, pips = pips }
end

-- Fits a row to its spell: icon, and how many pips its kind has.
local function assign(row, spell)
    row.spell = spell
    row.frame.spell = spell -- for the tooltip
    row.icon:SetTexture(spell.icon or QUESTION)
    local count = ns.kinds[spell.kind].pips
    for i, pip in ipairs(row.pips) do pip.frame:SetShown(i <= count) end
end

---------------------------------------------------------------------------
-- Position
---------------------------------------------------------------------------

local laidOut -- which rows layout() last stacked, so it only redoes it when that changes

function display.setup()
    local db = ns.db
    if not db then return end
    container:SetScale(db.scale)
    container:ClearAllPoints()
    if db.point then
        container:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4])
    elseif TargetFrame then
        container:SetPoint("BOTTOM", TargetFrame, "TOP", 0, 0)
    else
        container:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
    end
    for i, spell in ipairs(ns.spells) do
        rows[i] = rows[i] or createRow()
        assign(rows[i], spell)
        for _, pip in ipairs(rows[i].pips) do pip.damage:SetShown(db.showNumbers) end
    end
    for i = #ns.spells + 1, #rows do
        rows[i].spell, rows[i].frame.spell = nil, nil
        rows[i].frame:Hide()
    end
    laidOut = nil
    display.refresh()
end

-- Stacks the shown rows upward from the container's bottom, without gaps, and sizes the container to them.
local function layout(shown)
    local signature = table.concat(shown, ",")
    if signature == laidOut then return end
    laidOut = signature
    for _, row in ipairs(rows) do row.frame:Hide() end
    for position, index in ipairs(shown) do
        local frame = rows[index].frame
        frame:ClearAllPoints()
        frame:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, (position - 1) * ROW_HEIGHT)
        frame:Show()
    end
    container:SetHeight(math.max(1, #shown) * ROW_HEIGHT)
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

-- Test mode: every tracked spell's row, all lit, known or not (to place it on any character).
local function showTest()
    local shown = {}
    for index, row in ipairs(rows) do
        if row.spell then
            table.insert(shown, index)
            for i, pip in ipairs(row.pips) do
                pip.bar:SetMinMaxValues(0, 1)
                pip.bar:SetValue(1)
                pip.damage:SetText(i * 100)
                pip.damage:SetTextColor(LEARNED_COLOR[1], LEARNED_COLOR[2], LEARNED_COLOR[3])
                setBorder(pip, i == 3)
            end
            row.bigBar:SetMinMaxValues(0, 1)
            row.bigBar:SetValue(1)
        end
    end
    layout(shown)
    container:SetShown(#shown > 0)
end

-- Plain numbers for one row: the estimate per pip, the pip that's "now" (current combo points), and whether the
-- estimates are still the tooltip guess.
local function rowNumbers(spell, current)
    local kind = ns.kinds[spell.kind]
    local estimates, guessed = {}, false
    for n = 1, kind.pips do
        local estimate, _, isGuess = ns.estimate(spell, n)
        estimates[n] = estimate
        guessed = guessed or (estimate ~= nil and isGuess)
    end
    local nowEntry = kind.usesPoints and current or 1
    return estimates, nowEntry, guessed
end

local function update()
    local db = ns.db
    if testUntil then
        if GetTime() < testUntil then return showTest() end
        testUntil = nil
    end
    if not db.enabled or not targetAttackable() then
        container:Hide()
        return
    end

    local current, source = ns.comboPoints()
    local dots = ns.dotDamage()
    local shown, numbers = {}, {}
    for index, row in ipairs(rows) do
        local spell = row.spell
        if spell and spell.spellID then
            local estimates, nowEntry, guessed = rowNumbers(spell, current)
            local color = guessed and GUESSED_COLOR or LEARNED_COLOR
            numbers[index] = { estimates = estimates, nowEntry = nowEntry }
            table.insert(shown, index)
            for i, pip in ipairs(row.pips) do
                pip.damage:SetText(estimates[i] or "?")
                pip.damage:SetTextColor(color[1], color[2], color[3])
                pip.frame:SetAlpha(estimates[i] and 1 or 0.4)
                setBorder(pip, ns.kinds[spell.kind].usesPoints and i == current)
            end
            -- Counted points may be off by one: the big skull is dimmer then.
            local sure = source == "read" or not ns.kinds[spell.kind].usesPoints
            row.bigWindow:SetAlpha(sure and 1 or 0.6)
        end
    end
    if #shown == 0 then
        container:Hide()
        return
    end

    local ok, err = pcall(function()
        local health = UnitHealth("target")
        for _, index in ipairs(shown) do
            local row, n = rows[index], numbers[index]
            for i, pip in ipairs(row.pips) do
                pip.bar:SetMinMaxValues(0, health)
                pip.bar:SetValue(n.estimates[i] and (n.estimates[i] + dots) or 0)
            end
            local now = n.nowEntry >= 1 and n.estimates[n.nowEntry]
            row.bigBar:SetMinMaxValues(0, health)
            row.bigBar:SetValue(now and (now + dots) or 0)
        end
    end)
    if not ok then
        if not reportedError then
            reportedError = true
            ns.print("Display update failed: " .. tostring(err))
        end
        ns.trace("ERROR display: " .. tostring(err))
        container:Hide()
        return
    end
    layout(shown)
    container:Show()
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
