-- EarlyPull
-- Ported from the "Early Pull" WeakAura (https://wago.io/V4JIxqNQ4).
-- Announces who pulled the boss and how early/late, based on DBM/BW pull timers.

local ADDON_NAME, ns = ...

local EarlyPull = {}
_G.EarlyPull = EarlyPull
ns.EarlyPull = EarlyPull

EarlyPull.id = ADDON_NAME

local abs = abs
local format = format
local ipairs = ipairs
local pairs = pairs
local print = print
local select = select
local strsplit = strsplit
local time = time
local tonumber = tonumber
local tostring = tostring

local C_Timer = C_Timer
local C_ChatInfo = C_ChatInfo
local GetInstanceInfo = GetInstanceInfo
local GetNumGroupMembers = GetNumGroupMembers
local GetNumSubgroupMembers = GetNumSubgroupMembers
local GetRealmName = GetRealmName
local GetTime = GetTime
local GetUnitName = GetUnitName
local IsEncounterInProgress = IsEncounterInProgress
local IsInGroup = IsInGroup
local IsInInstance = IsInInstance
local IsInRaid = IsInRaid
local UnitClass = UnitClass
local UnitExists = UnitExists
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local UnitGUID = UnitGUID
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsGroupAssistant = UnitIsGroupAssistant
local UnitIsGroupLeader = UnitIsGroupLeader
local UnitIsPlayer = UnitIsPlayer
local UnitName = UnitName

local LE_PARTY_CATEGORY_INSTANCE = LE_PARTY_CATEGORY_INSTANCE
local TIMER_TYPE_PLAYER_COUNTDOWN = TIMER_TYPE_PLAYER_COUNTDOWN

-- Midnight (12.0+): some Blizzard APIs return opaque "secret" values that
-- cannot be used as table keys. Guard every GUID-as-key access.
local issecretvalue = _G.issecretvalue or function() return false end

-- Polling delays (seconds, absolute from ENCOUNTER_START) for damage-meter
-- snapshots. Each tick re-queries the session; first one that finds a
-- damaging player announces and stops the chain. Extended past 2s because
-- the C_DamageMeter session sometimes doesn't populate inside the first
-- second of an encounter, especially after a UI reload.
local kPollDelays = {0.2, 0.5, 1.0, 2.0, 3.5, 5.0, 7.0}

local function safeUnitGUID(unit)
    local ok, guid = pcall(UnitGUID, unit)
    if not ok or guid == nil or issecretvalue(guid) then
        return nil
    end
    return guid
end

local function safeKey(v)
    if v == nil or issecretvalue(v) then return nil end
    return v
end

EarlyPull.defaults = {
    announceEarlyPull = 1,   -- Banner (RaidNotice, local)
    announceOnTimePull = 1,
    announceLatePull = 1,
    announceUntimedPull = 1,
    pullTimeDiffDecimals = 2,
    pullOnTimeWindow = 0.25,
    maxPullTimeDiff = 10,
    autoPrintDetails = false,
    -- afterPullDelay: kept for backwards compat with existing SavedVariables;
    -- the polling schedule is hard-coded in kPollDelays now.
    afterPullDelay = 0.5,
}

local function applyDefaults(db, defaults)
    for k, v in pairs(defaults) do
        if db[k] == nil then db[k] = v end
    end
end

function EarlyPull:Init()
    EarlyPullDB = EarlyPullDB or {}
    applyDefaults(EarlyPullDB, self.defaults)
    self.db = EarlyPullDB

    -- Pull history grouped into sessions. A session is a contiguous run of
    -- pulls within the same raid instance; sessions split on >30 min gaps
    -- or when the player enters a different raid instance.
    self.db.sessions = self.db.sessions or {}

    -- Migrate legacy flat pulls list (pre-2.2) into a single session.
    if self.db.pulls and #self.db.pulls > 0 and #self.db.sessions == 0 then
        local first = self.db.pulls[1]
        local last = self.db.pulls[#self.db.pulls]
        table.insert(self.db.sessions, {
            startTs = first.ts or time(),
            lastPullTs = last.ts or time(),
            instanceName = "Imported (pre-2.2)",
            pulls = self.db.pulls,
        })
    end
    self.db.pulls = nil

    for k in pairs(self.defaults) do
        self[k] = self.db[k]
    end

    -- Channels we consider "group chat" for DBM/BW pull-timer detection.
    self.groupChannelTest = {
        PARTY = true,
        RAID = true,
        INSTANCE_CHAT = true,
    }

    self.myName = UnitName("player")
    self.myRealm = GetRealmName()

    self:RegisterEvents()

    self:PLAYER_ENTERING_WORLD()
end

function EarlyPull:ReloadConfig()
    if not self.db then return end
    for k in pairs(self.defaults) do
        self[k] = self.db[k]
    end
end

function EarlyPull:RegisterEvents()
    local frame = CreateFrame("Frame", "EarlyPullEventFrame")
    self.frame = frame
    frame:SetScript("OnEvent", function(_, event, ...)
        local handler = self[event]
        if handler then handler(self, ...) end
    end)

    local events = {
        "CHAT_MSG_ADDON",
        "CHAT_MSG_INSTANCE_CHAT",
        "CHAT_MSG_INSTANCE_CHAT_LEADER",
        "CHAT_MSG_RAID",
        "CHAT_MSG_RAID_LEADER",
        "CHAT_MSG_PARTY",
        "CHAT_MSG_PARTY_LEADER",
        "CHAT_MSG_SAY",
        "START_TIMER",
        "STOP_TIMER_OF_TYPE",
        "START_PLAYER_COUNTDOWN",
        "CANCEL_PLAYER_COUNTDOWN",
        "PLAYER_ENTERING_WORLD",
        "GROUP_ROSTER_UPDATE",
        "UPDATE_INSTANCE_INFO",
        "ENCOUNTER_START",
        "ENCOUNTER_END",
        "DAMAGE_METER_COMBAT_SESSION_UPDATED",
    }
    -- COMBAT_LOG_EVENT_UNFILTERED is intentionally NOT registered. The
    -- pre-v2.0 architecture used it for blame scoring but the damage-meter
    -- rewrite replaced that path. Worse, Midnight's Restricted Addons system
    -- treats CLEU registration as a protected action inside raid encounters
    -- and floods BugGrabber with ADDON_ACTION_FORBIDDEN errors.
    for _, event in ipairs(events) do
        frame:RegisterEvent(event)
    end
end

function EarlyPull:Print(...)
    print("|cff55ffdd"..self.id..":|r", ...)
end

local kSessionGapSeconds = 30 * 60 -- new session if last pull was >30 min ago

-- Returns the session bucket the next pull belongs to, creating a new one
-- if the previous session is stale or in a different raid instance.
function EarlyPull:GetOrCreateSession(ts)
    self.db.sessions = self.db.sessions or {}
    local sessions = self.db.sessions
    local current = sessions[#sessions]
    -- GetInstanceInfo returns (name, type, ...) — destructuring with leading
    -- underscore was capturing the type as the name (so the header showed
    -- "raid" instead of e.g. "Manaforge Omega").
    local instanceName, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    if current
       and (ts - (current.lastPullTs or current.startTs or 0)) < kSessionGapSeconds
       and current.instanceID == instanceID
    then
        current.lastPullTs = ts
        return current
    end
    local s = {
        startTs = ts,
        lastPullTs = ts,
        instanceID = instanceID,
        instanceName = tostring(instanceName or "?"),
        pulls = {},
    }
    table.insert(sessions, s)
    -- Cap retained sessions at 50 most recent.
    while #sessions > 50 do
        table.remove(sessions, 1)
    end
    return s
end

-- Append a pull record to the appropriate session.
function EarlyPull:RecordPull(ctx, actor)
    if not (self.db and ctx) then return end
    -- Store names/classes as-is, even if currently secret-wrapped. The
    -- SavedVariables serializer normalizes secrets to plain text on disk,
    -- so they reload as regular strings and accumulate in cross-session
    -- history. Read-time aggregation (in Report.lua) filters anything that
    -- is *still* secret in this session so it doesn't blow up table keys.
    local record = {
        ts = (GetServerTime and GetServerTime()) or time(),
        encounterID = ctx.encounterID,
        encounterName = tostring(ctx.encounterName or "?"),
        pullTimeDiff = ctx.pullTimeDiff,
        pullerName = actor and actor.name or nil,
        pullerClass = actor and actor.classFilename or nil,
        pullerIsTank = actor and actor.isTank or false,
    }
    local session = self:GetOrCreateSession(record.ts)
    table.insert(session.pulls, record)
    -- Cap pulls within a single session at 500 to avoid runaway growth.
    while #session.pulls > 500 do
        table.remove(session.pulls, 1)
    end
end

function EarlyPull:PLAYER_ENTERING_WORLD()
    self:GROUP_ROSTER_UPDATE()
    self:UPDATE_INSTANCE_INFO()
end

function EarlyPull:GROUP_ROSTER_UPDATE()
    self.inParty = IsInGroup()
    self.inRaid = IsInRaid()
    self.inInstanceGroup = IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
    self.raidSize = GetNumGroupMembers()
    self.partySize = GetNumSubgroupMembers()
end

function EarlyPull:UPDATE_INSTANCE_INFO()
    self.instanceID = select(8, GetInstanceInfo())
    self.inInstance = IsInInstance()
end

function EarlyPull:MaySendPullTimer(sender)
    return (UnitIsGroupLeader(sender) or UnitIsGroupAssistant(sender)
        or ((self.inInstanceGroup or not self.inRaid) and UnitGroupRolesAssigned(sender) == "TANK"))
end

function EarlyPull:CHAT_MSG_ADDON(prefix, message, channel, sender)
    -- BW and DBM both broadcast a DBM message on pull, so use that.
    -- If DBM increments protocol version we will have to update this.
    if not (prefix:sub(1, 2) == "D5" and self.groupChannelTest[channel]) then
        return
    end
    local _, _, ty, duration, instanceID, target = strsplit("\t", message)
    if ty ~= "PT" then
        return
    end
    duration = tonumber(duration or 0)
    instanceID = tonumber(instanceID)
    if IsEncounterInProgress()
    or (self.inParty and not self:MaySendPullTimer(sender))
    or (duration > 60 or (duration > 0 and duration < 3) or duration < 0)
    or (instanceID and instanceID ~= self.instanceID) then
        return
    end
    if duration == 0 then
        self.expectedPullTimeDBM = nil
    else
        self.expectedPullTimeDBM = GetTime() + duration
    end
end

local function onChatMessage(self, text)
    local ctx = self.pullContext
    -- text:match throws on secret strings; guard before any string method call.
    if ctx and type(text) == "string" and not issecretvalue(text) and text:match("^Boss pulled") then
        ctx.announceSeen = true
    end
end

EarlyPull.CHAT_MSG_INSTANCE_CHAT = onChatMessage
EarlyPull.CHAT_MSG_INSTANCE_CHAT_LEADER = onChatMessage
EarlyPull.CHAT_MSG_RAID = onChatMessage
EarlyPull.CHAT_MSG_RAID_LEADER = onChatMessage
EarlyPull.CHAT_MSG_PARTY = onChatMessage
EarlyPull.CHAT_MSG_PARTY_LEADER = onChatMessage
EarlyPull.CHAT_MSG_SAY = onChatMessage

function EarlyPull:START_TIMER(timerType, timeRemaining, totalTime)
    if timerType ~= TIMER_TYPE_PLAYER_COUNTDOWN then
        return
    end
    self.expectedPullTimeBlizz = GetTime() + timeRemaining
end

function EarlyPull:STOP_TIMER_OF_TYPE(timerType)
    if timerType ~= TIMER_TYPE_PLAYER_COUNTDOWN then
        return
    end
    self.expectedPullTimeBlizz = nil
end

function EarlyPull:START_PLAYER_COUNTDOWN(initiatedBy, timeRemaining, totalTime)
    self.expectedPullTimeBlizz = GetTime() + timeRemaining
end

function EarlyPull:CANCEL_PLAYER_COUNTDOWN(initiatedBy)
    self.expectedPullTimeBlizz = nil
end

function EarlyPull:GetGroupChannel()
    if self.inInstanceGroup and self.inInstance then
        return "INSTANCE_CHAT"
    elseif self.inRaid then
        return "RAID"
    elseif self.inParty then
        return "PARTY"
    end
end

function EarlyPull:IsSayAllowed()
    return self.inInstance and not UnitIsDeadOrGhost("player")
end

function EarlyPull:GetAnnounceChannel(announceType)
    if announceType == 1 then
        return "BANNER"
    elseif announceType == 2 then
        return "CHAT"
    end
    return nil
end

function EarlyPull:ClassifyPull(pullTimeDiff)
    local announceType, pullDesc
    if not pullTimeDiff then
        announceType = self.announceUntimedPull
        pullDesc = "Boss pulled"
    elseif pullTimeDiff <= -self.pullOnTimeWindow then
        announceType = self.announceEarlyPull
        pullDesc = format("Boss pulled %."..self.pullTimeDiffDecimals.."f seconds early", -pullTimeDiff)
    elseif pullTimeDiff < self.pullOnTimeWindow then
        announceType = self.announceOnTimePull
        pullDesc = "Boss pulled on time"
    else
        announceType = self.announceLatePull
        pullDesc = format("Boss pulled %."..self.pullTimeDiffDecimals.."f seconds late", pullTimeDiff)
    end
    return self:GetAnnounceChannel(announceType), pullDesc
end

-- Use the Blizzard-provided damage-meter API to identify the puller.
-- CLEU is silently disabled in Midnight restricted contexts so this is
-- our primary signal alongside boss-target. Returns the actor with
-- the highest non-zero damage in the current session, or nil if the API
-- isn't ready or no players have damage yet.
-- Read who the boss is targeting at this moment. The boss targets whoever
-- has highest threat, and at the very start of an encounter that's the
-- person who pulled (typically the tank). Different API surface than CLEU
-- and the damage meter — may bypass Midnight's restricted-state filters.
-- Look up a player's assigned group role ("TANK" / "HEALER" / "DAMAGER" / "NONE")
-- by name. Used when an actor is resolved via the damage-meter path (which
-- doesn't tell us who's tanking) so we can still flag tank pulls correctly.
local function lookupRoleByName(playerName)
    -- Order is critical: issecretvalue MUST be checked before any string
    -- operation including ==. Lua `or` short-circuits left-to-right, so a
    -- `playerName == ""` written before issecretvalue would throw on a
    -- secret-wrapped input. v2.7.3 had this exact bug and crashed 15k
    -- times in one fight.
    if type(playerName) ~= "string" then return nil end
    if issecretvalue(playerName) then return nil end
    if playerName == "" then return nil end
    local ok, playerNameOnly = pcall(function() return playerName:match("^([^-]+)") or playerName end)
    if not ok or not playerNameOnly then return nil end

    local function nameMatches(unit)
        local n = GetUnitName(unit, true) or UnitName(unit)
        if type(n) ~= "string" then return false end
        if issecretvalue(n) then return false end
        if n == "" then return false end
        if n == playerName then return true end
        local short = n:match("^([^-]+)") or n
        return short == playerNameOnly
    end

    -- Wrap the whole scan in pcall so any single secret-string surprise
    -- inside the loop can't take down the resolver path.
    local resultOk, role = pcall(function()
        if nameMatches("player") then
            return UnitGroupRolesAssigned("player")
        end
        local prefix = IsInRaid() and "raid" or "party"
        local count = IsInRaid() and 40 or 4
        for i = 1, count do
            local unit = prefix..i
            if UnitExists(unit) and nameMatches(unit) then
                return UnitGroupRolesAssigned(unit)
            end
        end
        return nil
    end)
    if not resultOk then return nil end
    return role
end

function EarlyPull:GetPullerFromBossTarget()
    for i = 1, 8 do
        local unit = "boss"..i.."target"
        local exists = UnitExists(unit)
        local isPlayer = exists and UnitIsPlayer(unit)
        local name, realm
        if exists then
            name, realm = UnitName(unit)
        end
        if exists and self.autoPrintDetails and not self._btDumped then
            self._btDumped = true
            self:Print(format("BT scan: %s exists=%s isPlayer=%s name=%s",
                unit, tostring(exists), tostring(isPlayer), tostring(name)))
        end
        -- Order matters: issecretvalue check MUST come before the ~= comparison.
        -- Lua short-circuits left to right, and comparing a secret string to a
        -- regular string throws "attempt to compare ... a secret string value".
        if isPlayer and name and not issecretvalue(name) and name ~= UNKNOWN then
            local _, classFile = UnitClass(unit)
            local safeRealm = realm and not issecretvalue(realm) and realm ~= "" and realm or nil
            local fullName = safeRealm and (name.."-"..safeRealm) or name
            return {
                name = fullName,
                classFilename = (classFile and not issecretvalue(classFile)) and classFile or nil,
                sourceGUID = safeUnitGUID(unit),
                -- The boss is targeting them, which by definition means they
                -- have aggro — they are functionally the tank for this pull.
                isTank = true,
            }
        end
    end
    return nil
end

-- Fired by Blizzard's damage meter system per damage/heal event. The first
-- fire after ENCOUNTER_START is the soonest moment we can snapshot — usually
-- the session contains only the actual puller at that instant, so this gives
-- a much better attribution than waiting for the +0.5s polling tick.
function EarlyPull:DAMAGE_METER_COMBAT_SESSION_UPDATED()
    local ctx = self.pullContext
    if not ctx or ctx.recorded then return end
    -- Prefer boss target (= tank = puller) over damage-meter heuristic.
    local actor = self:GetPullerFromBossTarget() or self:GetPullerFromDamageMeter()
    if not actor then return end
    ctx.puller = actor
    ctx.message = self:BuildPullMessage(ctx, actor)
    self:Announce(ctx.announceChannel, ctx.message)
    ctx.recorded = true
    self:RecordPull(ctx, actor)
    if self.autoPrintDetails then
        self:PrintPullDetails()
    end
end

function EarlyPull:GetPullerFromDamageMeter()
    if not (C_DamageMeter and C_DamageMeter.GetCombatSessionFromType) then
        if self.autoPrintDetails then self:Print("DM: C_DamageMeter API not available.") end
        return nil
    end
    if not (Enum and Enum.DamageMeterSessionType and Enum.DamageMeterType) then
        if self.autoPrintDetails then self:Print("DM: Enum.DamageMeter* not available.") end
        return nil
    end

    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
        Enum.DamageMeterSessionType.Current,
        Enum.DamageMeterType.DamageDone)

    -- Always dump per poll so we can see the session populating over time.
    if self.autoPrintDetails then
        if not ok then
            self:Print(format("DM: pcall error: %s", tostring(session)))
        elseif not session then
            self:Print("DM: session is nil.")
        elseif not session.combatSources then
            self:Print(format("DM: combatSources is nil. fields=%s",
                tostring(session.totalAmount)))
        else
            self:Print(format("DM poll: sources=%d totalAmount=%s duration=%s",
                #session.combatSources, tostring(session.totalAmount),
                tostring(session.durationSeconds)))
            for i, actor in ipairs(session.combatSources) do
                if i <= 3 then
                    self:Print(format("  src[%d]: name=%s totalAmount=%s class=%s",
                        i, tostring(actor.name),
                        tostring(actor.totalAmount or actor.total),
                        tostring(actor.classFilename)))
                end
            end
        end
    end

    if not ok or not session or not session.combatSources then
        return nil
    end

    local bestActor, bestTotal = nil, 0
    local cmpErrors = 0
    for _, actor in ipairs(session.combatSources) do
        local total = actor.totalAmount or actor.total
        local ok = pcall(function()
            if total and total > bestTotal then
                bestTotal = total
                bestActor = actor
            end
        end)
        if not ok then cmpErrors = cmpErrors + 1 end
    end

    -- Fallback: if every comparison errored (likely all damage values are
    -- secret-wrapped numbers in restricted state), just take the first actor
    -- in the list. Not strictly the puller, but better than nothing.
    if not bestActor and #session.combatSources > 0 then
        bestActor = session.combatSources[1]
    end

    -- The damage-meter API doesn't surface roles, so a tank picking up the
    -- pull comes back without isTank set — they'd then end up in the report
    -- as a non-tank early pull. Cross-reference the resolved name against
    -- the group's assigned roles and tag tanks here so the report exclusion
    -- rule still applies.
    if bestActor and not bestActor.isTank then
        local role = lookupRoleByName(bestActor.name)
        if role == "TANK" then
            bestActor.isTank = true
        end
    end

    if self.autoPrintDetails then
        self:Print(format("DM selection: bestActor=%s bestTotal=%s cmpErrors=%d sources=%d isTank=%s",
            bestActor and tostring(bestActor.name) or "nil",
            tostring(bestTotal), cmpErrors, #session.combatSources,
            tostring(bestActor and bestActor.isTank or false)))
    end
    return bestActor
end

-- Build the banner/chat message for a resolved puller. Tanks don't get
-- the early-flag treatment — they're supposed to pull. Late and untimed
-- pulls still get normal text for everyone.
function EarlyPull:BuildPullMessage(ctx, actor)
    local namePart = " by "..self:FormatPullerName(actor)
    local diff = ctx.pullTimeDiff
    if actor.isTank and diff and diff < -self.pullOnTimeWindow then
        return "Boss pulled"..namePart.."."
    end
    return ctx.pullDesc..namePart.."."
end

function EarlyPull:FormatPullerName(actor)
    if not actor then return "[Unknown]" end
    local ok, formatted = pcall(function()
        local rawName = actor.name
        local class = safeKey(actor.classFilename)
        local hasName = type(rawName) == "string" and rawName ~= ""
                        and not issecretvalue(rawName)
        local displayName
        if hasName then
            displayName = rawName
        elseif class then
            -- No usable name, but we have a class. Show "[Unknown WARRIOR]"
            -- so the raid at least knows what kind of player pulled.
            displayName = "[Unknown "..class.."]"
        else
            return "[Unknown]"
        end
        if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
            local c = RAID_CLASS_COLORS[class]
            return format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, displayName)
        end
        return displayName
    end)
    if ok and formatted then return formatted end
    return "[Unknown]"
end

-- Clear pullContext when the encounter ends so the next ENCOUNTER_START
-- (a fresh pull after a wipe or kill) isn't mistaken for a phase-event
-- duplicate of the previous pull. Without this, re-pulling the same boss
-- within 60 seconds of the previous pull start gets silently dropped by
-- the duplicate-skip in ENCOUNTER_START.
function EarlyPull:ENCOUNTER_END(encounterID, encounterName, difficultyID, groupSize, success)
    self.pullContext = nil
end

function EarlyPull:ENCOUNTER_START(encounterID, encounterName)
    -- Scope to raid instances only. Dungeons, scenarios, world bosses, and
    -- timewalking content often don't populate boss units or produce events
    -- in the narrow scoring window, which gives misleading "unknown cause"
    -- results.
    local _, instanceType = IsInInstance()
    if instanceType ~= "raid" then
        return
    end

    encounterID = safeKey(encounterID) or 0
    local now = GetTime()

    -- Some bosses fire ENCOUNTER_START multiple times per pull — phase
    -- transitions and "encounter bar" updates trigger the event again. If
    -- we already have an active context for this same encounter from
    -- within the last 60 seconds, treat the new fire as a duplicate and
    -- skip it. Otherwise we'd fire a second banner mid-fight and append a
    -- duplicate record.
    if self.pullContext
       and self.pullContext.encounterID == encounterID
       and (now - (self.pullContext.pullTime or 0)) < 60 then
        return
    end

    local expectedPullTime = self.expectedPullTimeDBM or self.expectedPullTimeBlizz
    local pullTimeDiff = expectedPullTime and abs(now - expectedPullTime) <= self.maxPullTimeDiff and now - expectedPullTime
    self.expectedPullTimeDBM = nil
    self.expectedPullTimeBlizz = nil
    self._btDumped = false

    local announceChannel, pullDesc = self:ClassifyPull(pullTimeDiff)

    self.pullContext = {
        pullTime = now,
        pullTimeDiff = pullTimeDiff,
        announceChannel = announceChannel,
        pullDesc = pullDesc,
        encounterID = encounterID,
        encounterName = encounterName,
        syncSent = false, -- retained for EARLY_PULL_AFTER_PULL compatibility
    }

    -- Try to grab the puller from boss targeting RIGHT NOW. Boss target is
    -- often already populated at ENCOUNTER_START with the tank/puller. If we
    -- get them immediately, fire the full banner now. Otherwise, polling
    -- and DAMAGE_METER_COMBAT_SESSION_UPDATED will fire it once resolved.
    local immediate = self:GetPullerFromBossTarget()
    if immediate then
        self.pullContext.puller = immediate
        self.pullContext.message = self:BuildPullMessage(self.pullContext, immediate)
        self:Announce(announceChannel, self.pullContext.message)
        self.pullContext.recorded = true
        self:RecordPull(self.pullContext, immediate)
    end

    C_Timer.After(kPollDelays[1], function()
        self:EARLY_PULL_AFTER_PULL(self.id, now, 1)
    end)
end

function EarlyPull:EARLY_PULL_AFTER_PULL(id, pullTime, afterPullIndex)
    local ctx = self.pullContext
    if id ~= self.id or not ctx or pullTime ~= ctx.pullTime then
        return
    end

    -- If RecordPull has already fired for this pull (via the immediate
    -- boss-target check at ENCOUNTER_START, the DAMAGE_METER_COMBAT_SESSION_UPDATED
    -- handler, or a previous polling tick) we're done. Without this guard
    -- each subsequent poll would re-resolve and record again, producing
    -- 2-4 duplicate entries per actual pull.
    if ctx.recorded then
        return
    end

    -- Resolve the puller and fire the banner with the full message. Boss
    -- target is preferred (= tank = actual puller). Damage meter is a fallback
    -- but biases toward burst-DPS classes due to Midnight's secret-wrapped
    -- damage values that can't be sorted accurately.
    local actor = self:GetPullerFromBossTarget() or self:GetPullerFromDamageMeter()
    if actor then
        ctx.puller = actor
        ctx.message = self:BuildPullMessage(ctx, actor)
        self:Announce(ctx.announceChannel, ctx.message)
        ctx.recorded = true
        self:RecordPull(ctx, actor)
        if self.autoPrintDetails then
            self:PrintPullDetails()
        end
        return
    end

    local nextDelay = kPollDelays[afterPullIndex + 1]
    if nextDelay then
        C_Timer.After(nextDelay - (kPollDelays[afterPullIndex] or 0), function()
            self:EARLY_PULL_AFTER_PULL(id, pullTime, afterPullIndex + 1)
        end)
    else
        -- All polls exhausted with no resolution; record once as [Unknown].
        ctx.recorded = true
        ctx.message = ctx.pullDesc.." by [Unknown]."
        self:Announce(ctx.announceChannel, ctx.message)
        self:RecordPull(ctx, nil)
        if self.autoPrintDetails then
            self:PrintPullDetails()
        end
    end
end

function EarlyPull:GetBannerFrame()
    if self.bannerFrame then return self.bannerFrame end

    local frame = CreateFrame("Frame", "EarlyPullBannerFrame", UIParent)
    frame:SetFrameStrata("HIGH")
    frame:SetSize(900, 80)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -180)
    frame:Hide()

    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    text:SetPoint("CENTER")
    text:SetWidth(880)
    text:SetJustifyH("CENTER")
    text:SetTextColor(1, 0.3, 0.3)
    frame.text = text

    self.bannerFrame = frame
    return frame
end

function EarlyPull:ShowBanner(message)
    -- Never feed secret text into a FontString. More importantly, use an
    -- addon-owned frame rather than Blizzard's shared RaidWarningFrame: in
    -- restricted combat that frame can contain secret-backed measurements,
    -- and RaidNotice_AddMessage's line-limit arithmetic then errors while the
    -- execution path is tainted by EarlyPull.
    if type(message) ~= "string" or issecretvalue(message) then
        message = "Boss pulled."
    end

    local frame = self:GetBannerFrame()
    self.bannerSequence = (self.bannerSequence or 0) + 1
    local sequence = self.bannerSequence
    frame.text:SetText(message)
    frame:Show()
    C_Timer.After(4, function()
        if self.bannerSequence == sequence then
            frame:Hide()
        end
    end)
end

function EarlyPull:Announce(announceChannel, message)
    if announceChannel == "BANNER" then
        self:ShowBanner(message)
        return true
    elseif announceChannel == "CHAT" then
        self:Print(message)
        return true
    end
    return false
end

function EarlyPull:PrintPullDetails()
    local ctx = self.pullContext
    if not ctx then
        self:Print("No pulls have been recorded.")
        return
    end

    self:Print(format("%s (id=%d) pulled %.3fs ago with timing=%s announce=%s.",
        tostring(ctx.encounterName), ctx.encounterID, GetTime() - ctx.pullTime,
        ctx.pullTimeDiff and format("%+.3fs", ctx.pullTimeDiff) or "UNTIMED",
        tostring(ctx.announceChannel)))

    if ctx.puller then
        local total = ctx.puller.total or ctx.puller.totalAmount or 0
        self:Print(format("Puller: %s (%s) with %d damage in current session.",
            tostring(ctx.puller.name), tostring(ctx.puller.classFilename or "?"), total))
    else
        local hasAPI = (C_DamageMeter and C_DamageMeter.GetCombatSessionFromType) and "yes" or "no"
        self:Print(format("Could not identify puller from damage-meter session (C_DamageMeter available: %s).", hasAPI))
    end
end

-- Deferred init after SavedVariables load.
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" and name == ADDON_NAME then
        self:UnregisterEvent("ADDON_LOADED")
        EarlyPull:Init()
    end
end)

SLASH_EARLYPULL1 = "/earlypull"
SLASH_EARLYPULL2 = "/ep"
local function simulatePull()
    local channel = EarlyPull:GetAnnounceChannel(EarlyPull.announceEarlyPull or 1)
    local name = EarlyPull.myName or UnitName("player") or "TestPlayer"
    local message = format("Boss pulled 1.23 seconds early by %s.", name)
    if channel then
        EarlyPull:Announce(channel, message)
    else
        EarlyPull:Print("Announce channel is 'None' — change it in /earlypull to see the banner/chat.")
    end
end

SlashCmdList["EARLYPULL"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "details" or msg == "d" then
        EarlyPull:PrintPullDetails()
    elseif msg == "reset" then
        EarlyPullDB = nil
        EarlyPull:Print("Settings reset. Reload UI (/reload) to apply.")
    elseif msg == "test" or msg == "simulate" then
        simulatePull()
    elseif msg == "config" or msg == "" then
        if Settings and Settings.OpenToCategory and EarlyPull.settingsCategoryID then
            Settings.OpenToCategory(EarlyPull.settingsCategoryID)
        else
            EarlyPull:Print("Usage: /earlypull [config|details|test|reset]")
        end
    else
        EarlyPull:Print("Usage: /earlypull [config|details|test|reset]")
    end
end
