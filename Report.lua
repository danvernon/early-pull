local ADDON_NAME, ns = ...
local EarlyPull = ns.EarlyPull

local format = format
local table_concat = table.concat
local time = time
local date = date

-- ---------------------------------------------------------------------------
-- Report formatting
-- ---------------------------------------------------------------------------

local function classifyDiffShort(diff)
    if not diff then return "untimed" end
    if diff <= -0.005 then
        return format("%.2fs early", -diff)
    elseif diff < 0.005 then
        return "on time"
    else
        return format("%.2fs late", diff)
    end
end

local function aggregatePulls(pulls)
    local agg = {}
    local order = {}
    for _, p in ipairs(pulls) do
        local key = p.pullerName or "[Unknown]"
        local a = agg[key]
        if not a then
            a = {name = key, class = p.pullerClass, count = 0, early = 0, ontime = 0, late = 0, untimed = 0}
            agg[key] = a
            order[#order + 1] = a
        end
        a.count = a.count + 1
        if not p.pullTimeDiff then
            a.untimed = a.untimed + 1
        elseif p.pullTimeDiff <= -0.005 then
            a.early = a.early + 1
        elseif p.pullTimeDiff < 0.005 then
            a.ontime = a.ontime + 1
        else
            a.late = a.late + 1
        end
    end
    table.sort(order, function(a, b) return a.count > b.count end)
    return order
end

local function appendSession(lines, session, indexFromEnd)
    local startStamp = session.startTs and date("%Y-%m-%d %H:%M", session.startTs) or "?"
    local endStamp = session.lastPullTs and date("%H:%M", session.lastPullTs) or "?"
    local pulls = session.pulls or {}
    lines[#lines + 1] = format("=== Session %d: %s — %s @ %s..%s (%d pulls) ===",
        indexFromEnd,
        tostring(session.instanceName or "?"),
        session.instanceID and ("id="..tostring(session.instanceID)) or "",
        startStamp, endStamp, #pulls)

    if #pulls == 0 then return end

    local agg = aggregatePulls(pulls)
    lines[#lines + 1] = "  By puller:"
    for _, a in ipairs(agg) do
        local parts = {}
        if a.early   > 0 then parts[#parts + 1] = a.early.." early" end
        if a.late    > 0 then parts[#parts + 1] = a.late.." late" end
        if a.ontime  > 0 then parts[#parts + 1] = a.ontime.." on time" end
        if a.untimed > 0 then parts[#parts + 1] = a.untimed.." untimed" end
        lines[#lines + 1] = format("    %s: %d (%s)", a.name, a.count,
            #parts > 0 and table_concat(parts, ", ") or "—")
    end

    lines[#lines + 1] = "  Pulls:"
    for i, p in ipairs(pulls) do
        local stamp = p.ts and date("%H:%M", p.ts) or "?"
        lines[#lines + 1] = format("    %d. [%s] %s — %s — %s",
            i, stamp, tostring(p.encounterName),
            classifyDiffShort(p.pullTimeDiff),
            tostring(p.pullerName or "[Unknown]"))
    end
end

-- Returns a multi-line string describing stored pulls grouped by raid session,
-- newest session first.
function EarlyPull:BuildReport()
    local sessions = self.db and self.db.sessions
    if not sessions or #sessions == 0 then
        return "No pulls recorded yet."
    end

    local total = 0
    for _, s in ipairs(sessions) do total = total + #(s.pulls or {}) end

    local lines = {}
    lines[#lines + 1] = format("EarlyPull report — %d session%s, %d total pulls.",
        #sessions, #sessions == 1 and "" or "s", total)
    lines[#lines + 1] = ""

    for i = #sessions, 1, -1 do
        appendSession(lines, sessions[i], #sessions - i + 1)
        lines[#lines + 1] = ""
    end

    return table_concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Report window
-- ---------------------------------------------------------------------------

local function buildReportFrame()
    local f = CreateFrame("Frame", "EarlyPullReportFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(560, 420)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    f.TitleText:SetText("EarlyPull — Pull Report")

    -- ScrollFrame + EditBox so the user can copy text out.
    local scroll = CreateFrame("ScrollFrame", "$parentScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -32)
    scroll:SetPoint("BOTTOMRIGHT", -32, 48)
    f.scroll = scroll

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(500)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(edit)
    f.edit = edit

    -- Buttons along the bottom.
    local function mkButton(label, x, w, onClick)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(w, 22)
        b:SetPoint("BOTTOMLEFT", x, 12)
        b:SetText(label)
        b:SetScript("OnClick", onClick)
        return b
    end

    f.reportBtn = mkButton("Report to Raid", 12, 130, function()
        EarlyPull:PostReport("RAID")
    end)
    f.reportPartyBtn = mkButton("Report to Party", 148, 130, function()
        EarlyPull:PostReport("PARTY")
    end)
    f.clearBtn = mkButton("Clear", 284, 80, function()
        if EarlyPullDB then EarlyPullDB.pulls = {} end
        EarlyPull:RefreshReport()
    end)
    f.refreshBtn = mkButton("Refresh", 368, 80, function()
        EarlyPull:RefreshReport()
    end)
    f.closeBtn = mkButton("Close", 452, 80, function() f:Hide() end)

    return f
end

function EarlyPull:RefreshReport()
    if not self.reportFrame then return end
    local text = self:BuildReport()
    self.reportFrame.edit:SetText(text)
    self.reportFrame.edit:HighlightText(0, 0)
end

function EarlyPull:ShowReport()
    if not self.reportFrame then
        self.reportFrame = buildReportFrame()
    end
    self:RefreshReport()
    self.reportFrame:Show()
end

-- ---------------------------------------------------------------------------
-- Posting to chat
-- ---------------------------------------------------------------------------

local function splitLinesForChat(text)
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    return lines
end

function EarlyPull:PostReport(channel)
    if InCombatLockdown and InCombatLockdown() then
        self:Print("Cannot post report while in combat.")
        return
    end
    local text = self:BuildReport()
    if text == "No pulls recorded yet." then
        self:Print(text)
        return
    end
    local lines = splitLinesForChat(text)
    local sender = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    for _, line in ipairs(lines) do
        if line ~= "" then
            -- Chat messages are capped at 255 characters; lines are short enough.
            sender(line, channel)
        end
    end
    self:Print(format("Posted %d lines to %s.", #lines, channel))
end

-- ---------------------------------------------------------------------------
-- Slash command extension
-- ---------------------------------------------------------------------------

-- Hook the existing /earlypull dispatcher to recognize the new subcommands.
-- Core.lua registers SLASH_EARLYPULL1 and SlashCmdList["EARLYPULL"]; we wrap
-- it here without touching the original definition.
local original = SlashCmdList.EARLYPULL
SlashCmdList.EARLYPULL = function(msg)
    local arg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if arg == "stats" or arg == "report" then
        EarlyPull:ShowReport()
    elseif arg == "report-raid" then
        EarlyPull:PostReport("RAID")
    elseif arg == "report-party" then
        EarlyPull:PostReport("PARTY")
    elseif arg == "stats-print" then
        EarlyPull:Print(EarlyPull:BuildReport())
    else
        if original then original(msg) end
    end
end
