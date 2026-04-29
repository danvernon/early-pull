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
    local rawPulls = session.pulls or {}

    -- Filter out tank pulls — they're supposed to pull, not what we want
    -- to call out. Tank pulls are still in storage with pullerIsTank=true,
    -- the leaderboard and per-pull list just hide them.
    local pulls = {}
    local tankPullCount = 0
    for _, p in ipairs(rawPulls) do
        if p.pullerIsTank then
            tankPullCount = tankPullCount + 1
        else
            pulls[#pulls + 1] = p
        end
    end

    lines[#lines + 1] = format("=== Session %d: %s — %s @ %s..%s (%d non-tank pulls%s) ===",
        indexFromEnd,
        tostring(session.instanceName or "?"),
        session.instanceID and ("id="..tostring(session.instanceID)) or "",
        startStamp, endStamp, #pulls,
        tankPullCount > 0 and format(", %d tank pulls hidden", tankPullCount) or "")

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

-- Build a flat array of every non-tank pull across all stored sessions.
local function collectAllNonTankPulls(sessions)
    local out = {}
    for _, s in ipairs(sessions) do
        for _, p in ipairs(s.pulls or {}) do
            if not p.pullerIsTank then
                out[#out + 1] = p
            end
        end
    end
    return out
end

-- Returns the leaderboard portion of the report — Details-style ranked list
-- of pullers across all stored sessions, sorted most-to-least.
function EarlyPull:BuildLeaderboard()
    local sessions = self.db and self.db.sessions or {}
    local pulls = collectAllNonTankPulls(sessions)
    local total = #pulls
    if total == 0 then
        return "EarlyPull Pull Report — no non-tank pulls recorded."
    end

    local agg = aggregatePulls(pulls)

    -- Pad name column to align the count + percent.
    local nameWidth = 0
    for _, a in ipairs(agg) do
        if #a.name > nameWidth then nameWidth = #a.name end
    end
    if nameWidth > 32 then nameWidth = 32 end

    local lines = {}
    local tankHidden = 0
    for _, s in ipairs(sessions) do
        for _, p in ipairs(s.pulls or {}) do
            if p.pullerIsTank then tankHidden = tankHidden + 1 end
        end
    end
    lines[#lines + 1] = format("EarlyPull Pull Report — %d non-tank pull%s%s",
        total, total == 1 and "" or "s",
        tankHidden > 0 and format(" (%d tank pulls hidden)", tankHidden) or "")

    for i, a in ipairs(agg) do
        local pct = total > 0 and (a.count / total * 100) or 0
        local breakdown = {}
        if a.early   > 0 then breakdown[#breakdown + 1] = a.early.." early" end
        if a.late    > 0 then breakdown[#breakdown + 1] = a.late.." late" end
        if a.ontime  > 0 then breakdown[#breakdown + 1] = a.ontime.." on time" end
        if a.untimed > 0 then breakdown[#breakdown + 1] = a.untimed.." untimed" end
        local breakStr = #breakdown > 0 and ("("..table_concat(breakdown, ", ")..")") or ""
        lines[#lines + 1] = format("%2d. %-"..nameWidth.."s  %3d   %5.1f%%  %s",
            i, a.name, a.count, pct, breakStr)
    end

    return table_concat(lines, "\n")
end

-- Window report = leaderboard only. Per-session detail was noisy and added
-- nothing the leaderboard didn't already convey; the chat post is the same
-- output, just sent to a channel.
function EarlyPull:BuildReport()
    return self:BuildLeaderboard()
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
    -- Post just the leaderboard to chat — Details-style ranked summary. The
    -- per-session detail stays in the in-game window for users who want it.
    local text = self:BuildLeaderboard()
    if not self.db or not self.db.sessions or #self.db.sessions == 0 then
        self:Print("No pulls recorded yet.")
        return
    end
    local lines = splitLinesForChat(text)
    local sender = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    for _, line in ipairs(lines) do
        if line ~= "" then
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
