-- FinishHim options window (/fh, or right-click the pips): the tracked spells (reorder, remove), adding spells
-- (from a list of qualifying spellbook spells, by dragging one in, or by name), and the settings.
-- Everything is laid out top to bottom in refresh(), so sections grow and shrink with their lists.

local ADDON_NAME, ns = ...

local WHITE = "Interface\\Buttons\\WHITE8X8"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local WIDTH = 440
local PAD = 14
local ROW = 28
local MAX_TRACKED_ROWS = 8
local MAX_CANDIDATE_ROWS = 10

local window
local widgets = {} -- built once in createWindow, placed by refresh

local function setBackdrop(frame, shade, alpha)
    frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    frame:SetBackdropColor(shade, shade, shade + 0.01, alpha or 1)
    frame:SetBackdropBorderColor(0.25, 0.25, 0.28, 1)
end

local function pushButton(parent, text, width, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function header(text)
    local label = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetText(text)
    local line = window:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.28, 0.28, 0.3, 1)
    line:SetHeight(1)
    return { label = label, line = line }
end

-- Shown after an action: green for done, red for why not.
local function setMessage(text, ok)
    widgets.message:SetText(text or "")
    if ok then
        widgets.message:SetTextColor(0.4, 1, 0.4)
    else
        widgets.message:SetTextColor(1, 0.4, 0.4)
    end
end

local refresh -- forward

-- Something changed the spell list or a setting: redraw the pips and this window.
local function changed()
    ns.display.setup()
    refresh()
end

local function addSpell(input)
    local ok, message = ns.addSpell(input)
    setMessage(message, ok)
    if ok then changed() end
end

local function spellTooltip(owner, spellID)
    if not spellID then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if not pcall(GameTooltip.SetSpellByID, GameTooltip, spellID) then return GameTooltip:Hide() end
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Spell rows
---------------------------------------------------------------------------

local function spellRow()
    local row = CreateFrame("Frame", nil, window)
    row:SetSize(WIDTH - PAD * 2, ROW - 2)
    local back = row:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints()
    back:SetColorTexture(1, 1, 1, 0.03)

    local iconButton = CreateFrame("Button", nil, row)
    iconButton:SetSize(22, 22)
    iconButton:SetPoint("LEFT", 4, 0)
    local icon = iconButton:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    iconButton:SetScript("OnEnter", function(self) spellTooltip(self, row.spellID) end)
    iconButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("LEFT", iconButton, "RIGHT", 8, 0)
    name:SetJustifyH("LEFT")
    local status = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    status:SetPoint("LEFT", name, "RIGHT", 8, 0)
    status:SetJustifyH("LEFT")

    row.icon, row.name, row.status = icon, name, status
    return row
end

local function trackedRow()
    local row = spellRow()
    row.remove = pushButton(row, "x", 24, function()
        local ok, message = ns.removeSpell(row.index)
        setMessage(message, ok)
        changed()
    end)
    row.remove:SetPoint("RIGHT", -2, 0)
    row.down = pushButton(row, "v", 24, function()
        ns.moveSpell(row.index, 1)
        changed()
    end)
    row.down:SetPoint("RIGHT", row.remove, "LEFT", -2, 0)
    row.up = pushButton(row, "^", 24, function()
        ns.moveSpell(row.index, -1)
        changed()
    end)
    row.up:SetPoint("RIGHT", row.down, "LEFT", -2, 0)

    -- Health bar marker on/off, with a swatch in the marker's color.
    local bar = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    bar:SetSize(22, 22)
    bar:SetPoint("RIGHT", row.up, "LEFT", -40, 0)
    local barLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    barLabel:SetPoint("LEFT", bar, "RIGHT", 0, 0)
    barLabel:SetText("Bar")
    local swatch = row:CreateTexture(nil, "ARTWORK")
    swatch:SetSize(8, 8)
    swatch:SetPoint("LEFT", barLabel, "RIGHT", 4, 0)
    bar:SetScript("OnClick", function(self)
        ns.setMarker(row.index, self:GetChecked())
        changed()
    end)
    bar:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Health bar marker")
        GameTooltip:AddLine("Marks this spell's damage on the target's health bar. If the marker covers all the "
            .. "health that's left, the spell kills.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    bar:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.bar, row.swatch = bar, swatch
    -- Long names and statuses are cut off before the checkbox instead of running under it.
    row.status:SetPoint("RIGHT", bar, "LEFT", -4, 0)
    row.status:SetWordWrap(false)
    return row
end

local function candidateRow()
    local row = spellRow()
    row.add = pushButton(row, "Add", 56, function() addSpell(tostring(row.spellID)) end)
    row.add:SetPoint("RIGHT", -2, 0)
    return row
end

local function trackedStatus(spell)
    if not spell.spellID then return "|cffff6666not in your spellbook (hidden)|r" end
    local kind = ns.kinds[spell.kind].short
    if spell.periodic then return kind .. ", damage over time" end
    if ns.db.useTooltip then return kind .. ", tooltip minimum" end
    local count = ns.learnedCount(spell.name)
    if count > 0 then
        return string.format("%s, |cffffd100learned (%d)|r", kind, count)
    end
    return kind .. ", guess"
end

---------------------------------------------------------------------------
-- Settings widgets
---------------------------------------------------------------------------

local function checkbox(label, key, onChange)
    local holder = CreateFrame("Frame", nil, window)
    holder:SetSize((WIDTH - PAD * 2) / 2, 24)
    local box = CreateFrame("CheckButton", nil, holder, "UICheckButtonTemplate")
    box:SetSize(24, 24)
    box:SetPoint("LEFT")
    local text = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", box, "RIGHT", 2, 0)
    text:SetText(label)
    box:SetScript("OnClick", function(self)
        ns.db[key] = self:GetChecked() and true or false
        if onChange then onChange() end
        changed()
    end)
    function holder.Refresh() box:SetChecked(ns.db[key]) end
    return holder
end

local function slider(label, key, low, high, step, format)
    local holder = CreateFrame("Frame", nil, window)
    holder:SetSize(WIDTH - PAD * 2, 26)
    local text = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT")
    text:SetText(label)
    local bar = CreateFrame("Slider", nil, holder, "BackdropTemplate")
    bar:SetOrientation("HORIZONTAL")
    bar:SetSize(170, 16)
    bar:SetPoint("LEFT", holder, "LEFT", 180, 0)
    bar:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    bar:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    bar:SetMinMaxValues(low, high)
    bar:SetValueStep(step)
    if bar.SetObeyStepOnDrag then bar:SetObeyStepOnDrag(true) end
    local value = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    value:SetPoint("LEFT", bar, "RIGHT", 10, 0)
    local updating = false
    bar:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v / step + 0.5) * step
        value:SetText(format(v))
        if updating then return end
        ns.db[key] = v
        ns.display.setup()
    end)
    function holder.Refresh()
        updating = true
        bar:SetValue(ns.db[key])
        updating = false
        value:SetText(format(ns.db[key]))
    end
    return holder
end

---------------------------------------------------------------------------
-- Dropping a spell from the spellbook
---------------------------------------------------------------------------

-- The spell ID on the cursor, if a spell is being dragged.
local function cursorSpellID()
    if not GetCursorInfo then return nil end
    local kind, a, b, c = GetCursorInfo()
    if kind ~= "spell" then return nil end
    if type(c) == "number" and not ns.isSecret(c) then return c end -- (index, book, spellID) on most clients
    if GetSpellBookItemInfo and type(a) == "number" then
        local ok, _, id = pcall(GetSpellBookItemInfo, a, b)
        if ok and type(id) == "number" then return id end
    end
end

local function onDrop()
    local id = cursorSpellID()
    if not id then return end
    ClearCursor()
    addSpell(tostring(id))
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function createWindow()
    window = CreateFrame("Frame", "FinishHimOptions", UIParent, "BackdropTemplate")
    window:Hide()
    window:SetWidth(WIDTH)
    window:SetPoint("CENTER")
    window:SetFrameStrata("DIALOG")
    window:SetToplevel(true)
    window:SetClampedToScreen(true)
    window:EnableMouse(true)
    window:SetMovable(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    setBackdrop(window, 0.06, 0.97)
    table.insert(UISpecialFrames, "FinishHimOptions") -- Escape closes it

    local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", PAD, -14)
    title:SetText("FinishHim")
    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    widgets.trackedHeader = header("Tracked spells")
    widgets.trackedEmpty = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    widgets.trackedEmpty:SetText("No spells tracked. Add one below.")
    widgets.tracked = {}
    for i = 1, MAX_TRACKED_ROWS do widgets.tracked[i] = trackedRow() end

    widgets.addHeader = header("Add a spell")
    local drop = CreateFrame("Button", nil, window, "BackdropTemplate")
    drop:SetSize(WIDTH - PAD * 2, 30)
    setBackdrop(drop, 0.11)
    local dropText = drop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dropText:SetPoint("CENTER")
    dropText:SetText("Drag a spell from your spellbook and drop it here")
    local dropGlow = drop:CreateTexture(nil, "HIGHLIGHT")
    dropGlow:SetAllPoints()
    dropGlow:SetColorTexture(1, 0.82, 0, 0.08)
    drop:SetScript("OnReceiveDrag", onDrop)
    drop:SetScript("OnClick", onDrop) -- a picked-up spell is dropped with a click too
    widgets.drop = drop

    widgets.candidateNote = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    widgets.candidateNote:SetJustifyH("LEFT")
    widgets.candidates = {}
    for i = 1, MAX_CANDIDATE_ROWS do widgets.candidates[i] = candidateRow() end

    local nameLabel = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameLabel:SetText("Or type its name:")
    local nameBox = CreateFrame("EditBox", nil, window, "BackdropTemplate")
    nameBox:SetSize(220, 22)
    setBackdrop(nameBox, 0.13)
    nameBox:SetFontObject("GameFontHighlightSmall")
    nameBox:SetTextInsets(6, 6, 0, 0)
    nameBox:SetAutoFocus(false)
    local function submitName()
        local text = strtrim(nameBox:GetText() or "")
        if text == "" then return end
        nameBox:SetText("")
        nameBox:ClearFocus()
        addSpell(text)
    end
    nameBox:SetScript("OnEnterPressed", submitName)
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local nameAdd = pushButton(window, "Add", 56, submitName)
    nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 8, 0)
    nameAdd:SetPoint("LEFT", nameBox, "RIGHT", 6, 0)
    widgets.nameLabel = nameLabel

    widgets.message = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    widgets.message:SetJustifyH("LEFT")
    widgets.message:SetWidth(WIDTH - PAD * 2)

    widgets.settingsHeader = header("Settings")
    widgets.checks = {
        checkbox("Enabled", "enabled"),
        checkbox("Show damage numbers", "showNumbers"),
        checkbox("Lock position", "locked"),
        checkbox("Add DoesItDie's DoT damage", "includeDots"),
        checkbox("Health bar markers", "showMarkers"),
        checkbox("Use tooltip minimum", "useTooltip"),
        checkbox("Nameplate combo dots", "plateDots"),
        checkbox("Nameplate damage marker", "plateMarker"),
    }
    widgets.sliders = {
        slider("Size", "scale", 0.5, 3, 0.1, function(v) return string.format("%.1fx", v) end),
        slider("Nameplate dot size", "plateDotSize", 6, 20, 1, function(v) return string.format("%d px", v) end),
        slider("Nameplate dot height", "plateDotsOffset", -40, 40, 1, function(v) return string.format("%+d px", v) end),
        slider("Safety margin", "margin", 0, 50, 1, function(v) return string.format("-%d%%", v) end),
        slider("Guess before learning", "guessFactor", 0.3, 1.5, 0.05,
            function(v) return string.format("tooltip x %.2f", v) end),
    }
    widgets.buttons = {
        pushButton(window, "Test (10s)", 100, function() ns.display.test(10) end),
        pushButton(window, "Reset position", 120, function()
            ns.db.point = nil
            ns.display.setup()
            setMessage("Position reset.", true)
        end),
        pushButton(window, "Forget learned", 120, function()
            ns.forget()
            setMessage("Learned numbers forgotten.", true)
            changed()
        end),
    }
    widgets.dotsNote = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    widgets.dotsNote:SetJustifyH("LEFT")
    widgets.dotsNote:SetWidth(WIDTH - PAD * 2)

    window:SetScript("OnShow", function()
        ns.refreshSpells()
        setMessage("")
        refresh()
    end)
end

-- Places every widget top to bottom and fills the lists.
function refresh()
    if not (window and window:IsShown()) then return end
    local y = -44
    local function place(frame, x, height)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", window, "TOPLEFT", x or PAD, y)
        frame:Show()
        y = y - height
    end
    local function placeHeader(h)
        y = y - 6
        h.label:ClearAllPoints()
        h.label:SetPoint("TOPLEFT", window, "TOPLEFT", PAD, y)
        h.line:ClearAllPoints()
        h.line:SetPoint("TOPLEFT", window, "TOPLEFT", PAD, y - 16)
        h.line:SetPoint("TOPRIGHT", window, "TOPRIGHT", -PAD, y - 16)
        y = y - 24
    end

    -- Tracked spells
    placeHeader(widgets.trackedHeader)
    local spells = ns.spells
    widgets.trackedEmpty:SetShown(#spells == 0)
    if #spells == 0 then place(widgets.trackedEmpty, PAD + 4, 20) end
    for i, row in ipairs(widgets.tracked) do
        local spell = spells[i]
        if spell then
            row.index, row.spellID = i, spell.spellID
            row.icon:SetTexture(spell.icon or QUESTION)
            row.icon:SetDesaturated(not spell.spellID)
            row.name:SetText(spell.name)
            row.status:SetText(trackedStatus(spell))
            row.bar:SetChecked(spell.marker)
            local color = ns.display.markerColor(i)
            row.swatch:SetColorTexture(color[1], color[2], color[3], 1)
            row.up:SetEnabled(i > 1)
            row.down:SetEnabled(i < #spells)
            place(row, PAD, ROW)
        else
            row:Hide()
        end
    end

    -- Add a spell
    placeHeader(widgets.addHeader)
    local candidates = ns.candidateSpells()
    widgets.candidateNote:SetText(#candidates > 0 and "Damage spells in your spellbook:"
        or "No other damage spells with fixed numbers found in your spellbook.")
    place(widgets.candidateNote, PAD + 4, 18)
    for i, row in ipairs(widgets.candidates) do
        local candidate = candidates[i]
        if candidate then
            row.spellID = candidate.spellID
            row.icon:SetTexture(candidate.icon or QUESTION)
            row.icon:SetDesaturated(false)
            row.name:SetText(candidate.name)
            row.status:SetText(ns.kinds[candidate.kind].short .. (candidate.periodic and ", damage over time" or ""))
            place(row, PAD, ROW)
        else
            row:Hide()
        end
    end
    y = y - 4
    place(widgets.drop, PAD, 36)
    y = y - 4 -- the name box is centered on its label, so it sticks out above it
    place(widgets.nameLabel, PAD + 4, 26)
    place(widgets.message, PAD + 4, widgets.message:GetText() ~= "" and 18 or 0)

    -- Settings
    placeHeader(widgets.settingsHeader)
    for i, check in ipairs(widgets.checks) do
        check.Refresh()
        local column = (i - 1) % 2
        check:ClearAllPoints()
        check:SetPoint("TOPLEFT", window, "TOPLEFT", PAD + column * (WIDTH - PAD * 2) / 2, y)
        check:Show()
        if column == 1 or i == #widgets.checks then y = y - 26 end
    end
    local hasDoesItDie = type(DoesItDie) == "table"
    widgets.dotsNote:SetText(hasDoesItDie and "DoT damage means \"dies eventually\", not \"dies now\"."
        or "DoesItDie isn't loaded, so its DoT damage can't be added.")
    place(widgets.dotsNote, PAD + 4, 18)
    y = y - 4
    for _, s in ipairs(widgets.sliders) do
        s.Refresh()
        place(s, PAD + 4, 28)
    end
    y = y - 6
    local x = PAD
    for _, button in ipairs(widgets.buttons) do
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", window, "TOPLEFT", x, y)
        x = x + button:GetWidth() + 6
    end
    y = y - 22 - PAD
    window:SetHeight(-y)
end

function ns.refreshOptions()
    refresh()
end

function ns.openOptions()
    if not ns.db then return end
    if not window then createWindow() end
    if window:IsShown() then
        window:Hide()
    else
        window:Show()
    end
end

-- Options > AddOns > FinishHim: a short page with a button that opens the window.
local function registerSettingsPage()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
    local panel = CreateFrame("Frame")
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("FinishHim")
    local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    text:SetText("Settings have their own window. You can also type /fh or right-click the pips.")
    local open = pushButton(panel, "Open FinishHim options", 200, function()
        if SettingsPanel and SettingsPanel:IsShown() then pcall(HideUIPanel, SettingsPanel) end
        if not (window and window:IsShown()) then ns.openOptions() end
    end)
    open:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -14)
    local category = Settings.RegisterCanvasLayoutCategory(panel, "FinishHim")
    Settings.RegisterAddOnCategory(category)
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    local ok, err = pcall(registerSettingsPage)
    if not ok then ns.trace("Settings page registration failed: " .. tostring(err)) end
end)
