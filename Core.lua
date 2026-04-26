-- EarlyPull
-- Ported from the "Early Pull" WeakAura (https://wago.io/V4JIxqNQ4).
-- Announces who pulled the boss and how early/late, based on DBM/BW pull timers.

local ADDON_NAME, ns = ...

local EarlyPull = {}
_G.EarlyPull = EarlyPull
ns.EarlyPull = EarlyPull

EarlyPull.id = ADDON_NAME

local abs = abs
local assert = assert
local bit_band = bit.band
local floor = floor
local format = format
local ipairs = ipairs
local max = max
local pairs = pairs
local print = print
local select = select
local strsplit = strsplit
local tonumber = tonumber
local tostring = tostring
local wipe = wipe

local C_Timer = C_Timer
local C_ChatInfo = C_ChatInfo
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
local GetInstanceInfo = GetInstanceInfo
local GetNumGroupMembers = GetNumGroupMembers
local GetNumSubgroupMembers = GetNumSubgroupMembers
local GetRealmName = GetRealmName
local GetSpellLink = (C_Spell and C_Spell.GetSpellLink) or GetSpellLink
local GetTime = GetTime
local GetUnitName = GetUnitName
local IsEncounterInProgress = IsEncounterInProgress
local IsInGroup = IsInGroup
local IsInInstance = IsInInstance
local IsInRaid = IsInRaid
local SendChatMessage = SendChatMessage
local UnitDetailedThreatSituation = UnitDetailedThreatSituation
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local UnitGUID = UnitGUID
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsGroupAssistant = UnitIsGroupAssistant
local UnitIsGroupLeader = UnitIsGroupLeader
local UnitName = UnitName
local UnitPlayerControlled = UnitPlayerControlled

local LE_PARTY_CATEGORY_INSTANCE = LE_PARTY_CATEGORY_INSTANCE
local TIMER_TYPE_PLAYER_COUNTDOWN = TIMER_TYPE_PLAYER_COUNTDOWN

local kSourceFlagMask = COMBATLOG_OBJECT_CONTROL_MASK
local kSourceFlagFilter = COMBATLOG_OBJECT_CONTROL_PLAYER
local kDestFlagMask = bit.bor(COMBATLOG_OBJECT_CONTROL_MASK, COMBATLOG_OBJECT_REACTION_MASK)
local kDestFlagFilter1 = bit.bor(COMBATLOG_OBJECT_CONTROL_NPC, COMBATLOG_OBJECT_REACTION_HOSTILE)
local kDestFlagFilter2 = bit.bor(COMBATLOG_OBJECT_CONTROL_NPC, COMBATLOG_OBJECT_REACTION_NEUTRAL)
local kNegInfinity = -math.huge

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
    pullOnTimeWindow = 0.005,
    maxPullTimeDiff = 10,
    syncPriority = 2,
    autoPrintDetails = false,
    -- advanced heuristics
    afterPullDelay = 0.5,
    criticalWindowBegin = -0.33,
    criticalWindowEnd = 0.33,
    timelinessDecayRate = 3,
    timelinessOffset = 0,
    combatLogBaseScore = 90,
    combatLogNonDamagePenalty = 0.9,
    combatLogSpellCastPenalty = 0.7,
    combatLogNonBossTargetPenalty = 0.4,
    spellBlameCutoff = 50,
    threatLogBaseScore = 100,
    threatLogNotEarliestPenalty = 0.4,
    threatLogOffTankPenalty = 0.8,
    threatLogNonTankPenalty = 0.7,
    targetLogBaseScore = 80,
    targetLogNotEarliestPenalty = 0.4,
    lowCertaintyCutoff = 50,
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

    for k in pairs(self.defaults) do
        self[k] = self.db[k]
    end

    self.groupChannelTest = {
        PARTY = true,
        RAID = true,
        INSTANCE_CHAT = true,
    }

    self.combatLog = {pos = 0, maxPos = 1000}
    self.threatLog = {pos = 0, maxPos = 100}
    self.targetLog = {pos = 0, maxPos = 100}
    self.bossLog = {pos = 0, maxPos = 100}
    self.syncLog = {pos = 0, maxPos = 100}

    for i = 1, self.combatLog.maxPos do
        self.combatLog[i] = {time = kNegInfinity, guid = nil, name = nil, event = nil, destGUID = nil, spellID = nil}
    end
    for i = 1, self.threatLog.maxPos do
        self.threatLog[i] = {time = kNegInfinity, threatEntries = {count = 0}}
    end
    for i = 1, self.targetLog.maxPos do
        self.targetLog[i] = {time = kNegInfinity, guid = nil, name = nil}
    end
    for i = 1, self.bossLog.maxPos do
        self.bossLog[i] = {time = kNegInfinity, guid = nil}
    end
    for i = 1, self.syncLog.maxPos do
        self.syncLog[i] = {time = kNegInfinity, message = nil}
    end

    self.unitList = {raid = {}, raidpet = {}, party = {}, partypet = {}, boss = {}, bosstarget = {}}

    for i = 1, 40 do
        self.unitList.raid[i] = "raid"..i
        self.unitList.raidpet[i] = "raidpet"..i
    end
    for i = 1, 4 do
        self.unitList.party[i] = "party"..i
        self.unitList.partypet[i] = "partypet"..i
    end
    for i = 1, 8 do
        self.unitList.boss[i] = "boss"..i
        self.unitList.bosstarget[i] = "boss"..i.."target"
    end

    self.combatLogDamageEventTest = {
        SPELL_DAMAGE = true,
        SPELL_PERIODIC_DAMAGE = true,
        SWING_DAMAGE = true,
        RANGE_DAMAGE = true,
    }
    self.combatLogSwingEventTest = {
        SWING_DAMAGE = true,
        SWING_MISSED = true,
    }
    self.combatLogTrackedEvents = {
        SPELL_DAMAGE = true,
        SPELL_MISSED = true,
        SPELL_PERIODIC_DAMAGE = true,
        SPELL_PERIODIC_MISSED = true,
        SWING_DAMAGE = true,
        SWING_MISSED = true,
        RANGE_DAMAGE = true,
        RANGE_MISSED = true,
        SPELL_AURA_APPLIED = true,
        SPELL_CAST_SUCCESS = true,
        SPELL_SUMMON = true,
    }

    self.summons = {counter = 0}
    self.summons2 = {counter = 0}

    self.myName = UnitName("player")
    self.myRealm = GetRealmName()

    self:InitSync()
    self:RegisterEvents()

    self:PLAYER_ENTERING_WORLD()
end

function EarlyPull:ReloadConfig()
    if not self.db then return end
    for k in pairs(self.defaults) do
        self[k] = self.db[k]
    end
    -- sync priority change may toggle sync; re-init
    self:InitSync()
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
        "INSTANCE_ENCOUNTER_ENGAGE_UNIT",
        "DAMAGE_METER_COMBAT_SESSION_UPDATED",
        "COMBAT_LOG_EVENT_UNFILTERED",
    }
    for _, event in ipairs(events) do
        frame:RegisterEvent(event)
    end

    frame:RegisterUnitEvent("UNIT_THREAT_LIST_UPDATE",
        "boss1", "boss2", "boss3", "boss4", "boss5", "boss6", "boss7", "boss8")
    frame:RegisterUnitEvent("UNIT_TARGET",
        "boss1", "boss2", "boss3", "boss4", "boss5", "boss6", "boss7", "boss8")
end

function EarlyPull:InitSync()
    self.syncEnabled = false
    if self.syncPriority == 4 then return end -- Isolated

    self.syncPrefix = "EarlyPull"
    self.syncVersion = 2

    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(self.syncPrefix)
        self.syncEnabled = true
    end
end

function EarlyPull:Print(...)
    print("|cff55ffdd"..self.id..":|r", ...)
end

function EarlyPull:AdvanceLog(log)
    local pos = (log.pos % log.maxPos) + 1
    log.pos = pos
    return log[pos]
end

-- relPos = pos shifted to be time-monotonic and 0-indexed
-- relPos = (pos - 1 - offset) % maxPos
-- pos = 1 + (relPos + offset) % maxPos

-- returns relPos of first entry.time >= time
-- first: relPos of lower search cutoff (inclusive)
local function binarySearchLogTime(log, time, first)
    local offset = log.pos
    local maxPos = log.maxPos
    local floor = floor

    local count = maxPos - first
    local current
    local step

    while count > 0 do
        step = floor(count / 2)
        current = first + step
        if log[1 + (current + offset) % maxPos].time < time then
            first = current + 1
            count = count - (step + 1)
        else
            count = step
        end
    end
    return first
end

local function iterEmpty()
end

local function iterRange(state, i)
    i = i + 1
    if i <= state[2] then
        return i, state[1][i]
    end
end

local function iterTwoRanges(state, i)
    i = i + 1
    local j = state[2]
    if i <= state[j] then
        return i, state[1][i]
    elseif j == 3 then
        i = state[4]
        if i <= state[5] then
            state[2] = 5
            return i, state[1][i]
        end
    end
end

function EarlyPull:IterateLogWindow(log, beginTime, endTime)
    local beginRelPos = binarySearchLogTime(log, beginTime, 0)
    local endRelPos = binarySearchLogTime(log, endTime, beginRelPos)
    assert(beginRelPos <= endRelPos)
    if beginRelPos == endRelPos then
        return iterEmpty
    end
    local offset = log.pos
    local maxPos = log.maxPos
    local beginPos = 1 + (beginRelPos + offset) % maxPos
    local endPos = 1 + (endRelPos - 1 + offset) % maxPos -- now inclusive
    if beginPos <= endPos then
        return iterRange, {log, endPos}, beginPos - 1
    else
        return iterTwoRanges, {log, 3, maxPos, 1, endPos}, beginPos - 1
    end
end

function EarlyPull:PLAYER_ENTERING_WORLD()
    self:GROUP_ROSTER_UPDATE()
    self:UPDATE_INSTANCE_INFO()
    self:ScanAllBosses()
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
    if self.syncEnabled and prefix == self.syncPrefix and self.groupChannelTest[channel] then
        self:OnSync(prefix, message, channel, sender)
        return
    end

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
    if ctx and text and text:match("^Boss pulled") then
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

local threatScanUnits = {}

local function addThreatScanUnit(unit)
    local guid = safeUnitGUID(unit)
    if guid then
        threatScanUnits[guid] = unit
    end
end

function EarlyPull:ScanThreat(mob)
    wipe(threatScanUnits)
    if self.inRaid then
        local raid = self.unitList.raid
        local raidpet = self.unitList.raidpet
        for i = 1, self.raidSize do
            addThreatScanUnit(raid[i])
            addThreatScanUnit(raidpet[i])
        end
    else
        if self.inParty then
            local party = self.unitList.party
            local partypet = self.unitList.partypet
            for i = 1, self.partySize do
                addThreatScanUnit(party[i])
                addThreatScanUnit(partypet[i])
            end
        end
        addThreatScanUnit("player")
        addThreatScanUnit("pet")
    end
    addThreatScanUnit("target")
    addThreatScanUnit("focus")
    addThreatScanUnit("mouseover")

    local entry = self:AdvanceLog(self.threatLog)
    entry.time = GetTime()
    local threatEntries = entry.threatEntries

    local count = 0
    for guid, unit in pairs(threatScanUnits) do
        if UnitPlayerControlled(unit) then
            local ok, isTanking, state, scaledPercent, rawPercent, threatValue
                = pcall(UnitDetailedThreatSituation, unit, mob)
            if not ok then
                isTanking, state, scaledPercent, rawPercent, threatValue = nil, nil, nil, nil, nil
            end
            -- Midnight: threatValue can be a secret number that errors on arithmetic.
            if issecretvalue(threatValue) then threatValue = nil end
            if issecretvalue(isTanking) then isTanking = nil end
            if state or threatValue then
                count = count + 1
                local threatEntry = threatEntries[count] or {}
                threatEntries[count] = threatEntry

                threatEntry.guid = guid
                threatEntry.name = GetUnitName(unit, true)
                threatEntry.isTanking = isTanking
                threatEntry.threatValue = threatValue
            end
        end
    end
    threatEntries.count = count
end

function EarlyPull:UNIT_THREAT_LIST_UPDATE(unit)
    if unit and unit:match("^boss%d$") then
        self:ScanThreat(unit)
    end
end

function EarlyPull:ScanBoss(unit, targetUnit)
    local bossGUID = safeUnitGUID(unit)
    if bossGUID then
        local now = GetTime()

        local bossEntry = self:AdvanceLog(self.bossLog)
        bossEntry.time = now
        bossEntry.guid = bossGUID

        local targetGUID = safeUnitGUID(targetUnit)
        if targetGUID and UnitPlayerControlled(targetUnit) then
            local targetEntry = self:AdvanceLog(self.targetLog)
            targetEntry.time = now
            targetEntry.guid = targetGUID
            targetEntry.name = GetUnitName(targetUnit, true)
        end
    end
end

function EarlyPull:ScanAllBosses()
    local boss = self.unitList.boss
    local bosstarget = self.unitList.bosstarget
    for i = 1, 8 do
        self:ScanBoss(boss[i], bosstarget[i])
    end
end

function EarlyPull:UNIT_TARGET(unit)
    if unit and unit:match("^boss%d$") then
        self:ScanBoss(unit, unit.."target")
    end
end

function EarlyPull:COMBAT_LOG_EVENT_UNFILTERED()
    local _, event, _, sourceGUID, sourceName, sourceFlags, _, destGUID, _, destFlags, _, spellID, _, _, auraType
        = CombatLogGetCurrentEventInfo()

    self.cleuRaw = (self.cleuRaw or 0) + 1
    if not self.combatLogTrackedEvents[event] then
        return
    end
    self.cleuTracked = (self.cleuTracked or 0) + 1

    if event == "SPELL_SUMMON" then
        local destKey = safeKey(destGUID)
        if not destKey then return end
        local summons = self.summons
        summons[destKey] = sourceName
        local counter = summons.counter + 1
        if counter >= 1000 then
            self.summons = self.summons2
            self.summons2 = summons
            wipe(self.summons)
            self.summons.counter = 0
        else
            summons.counter = counter
        end
        return
    end

    if not (sourceGUID and destGUID)
    or (event == "SPELL_AURA_APPLIED" and auraType ~= "DEBUFF") then
        return
    end
    self.cleuPostGuidAura = (self.cleuPostGuidAura or 0) + 1

    -- Midnight: sourceFlags may be secret for other raid members (privacy).
    -- Use the flag filter when we can read it; fall back to GUID prefix when
    -- we can't, so we don't silently drop every other raider's events.
    if sourceFlags and not issecretvalue(sourceFlags) then
        if bit_band(sourceFlags, kSourceFlagMask) ~= kSourceFlagFilter then
            return
        end
    elseif sourceGUID and not issecretvalue(sourceGUID) then
        local prefix = sourceGUID:match("^([^-]+)-")
        if prefix ~= "Player" and prefix ~= "Pet" and prefix ~= "Vehicle" then
            return
        end
    end
    self.cleuPostSrc = (self.cleuPostSrc or 0) + 1

    if not destFlags or issecretvalue(destFlags) then return end
    local destFlagsMasked = bit_band(destFlags, kDestFlagMask)
    if destFlagsMasked ~= kDestFlagFilter1 and destFlagsMasked ~= kDestFlagFilter2 then
        return
    end
    self.cleuPostDst = (self.cleuPostDst or 0) + 1

    -- Midnight: sourceGUID may be secret; fall back to a name-based key so we
    -- can still identify the culprit. destGUID is only used to check if the
    -- target is a known boss; if secret, DetermineBlame applies the non-boss penalty.
    local sourceKey = safeKey(sourceGUID) or (sourceName and "name:"..sourceName) or nil
    if not sourceKey then return end
    local destKey = safeKey(destGUID)

    local entry = self:AdvanceLog(self.combatLog)
    entry.time = GetTime()
    entry.guid = sourceKey
    entry.name = sourceName
    entry.event = event
    entry.destGUID = destKey
    entry.spellID = safeKey(spellID)
    self.cleuWritten = (self.cleuWritten or 0) + 1
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

function EarlyPull:GetGroupRank()
    return UnitIsGroupLeader("player") and 2 or UnitIsGroupAssistant("player") and 1 or 0
end

function EarlyPull:CreateSyncTable(encounterID)
    return {self.syncVersion, encounterID, self.syncPriority, self:GetGroupRank(), self.myName, self.myRealm}
end

function EarlyPull:SerializeSyncTable(syncTable)
    return table.concat(syncTable, "\t")
end

function EarlyPull:DeserializeSyncTable(data)
    local syncTable = {strsplit("\t", data)}
    for i = 1, 6 do
        if i <= 4 then
            syncTable[i] = tonumber(syncTable[i])
        end
        if not syncTable[i] then
            return nil
        end
    end
    return syncTable
end

-- returns true if a has worse priority than b
function EarlyPull:CompareSyncTables(a, b)
    if a[1] < b[1] then return true elseif a[1] > b[1] then return false end
    if a[3] < b[3] then return true elseif a[3] > b[3] then return false end
    if a[4] < b[4] then return true elseif a[4] > b[4] then return false end
    if a[5] > b[5] then return true elseif a[5] < b[5] then return false end
    if a[6] > b[6] then return true elseif a[6] < b[6] then return false end
end

function EarlyPull:CheckSyncTableEncounter(syncTable, encounterID)
    return syncTable[2] == encounterID
end

function EarlyPull:IsMySyncTable(syncTable)
    return syncTable[5] == self.myName and syncTable[6] == self.myRealm
end

function EarlyPull:OnSync(prefix, message, channel, sender)
    if not self.groupChannelTest[channel] then return end
    local entry = self:AdvanceLog(self.syncLog)
    entry.time = GetTime()
    entry.message = message
end

function EarlyPull:SendSync(message, channel)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(self.syncPrefix, message, channel)
    end
    -- Midnight: the CHAT_MSG_ADDON echo to the sender is unreliable, so
    -- log our own entry directly to guarantee the sync coordination loop
    -- sees us. (A duplicate echo, if it does arrive, is harmless.)
    local entry = self:AdvanceLog(self.syncLog)
    entry.time = GetTime()
    entry.message = message
end

-- Midnight (12.0+): COMBAT_LOG_EVENT_UNFILTERED is silently disabled inside
-- restricted contexts (raid encounters, M+, PvP). Use the Blizzard-provided
-- damage-meter API to identify the puller instead. Returns the actor with
-- the highest non-zero damage in the current session, or nil if the API
-- isn't ready or no players have damage yet.
-- Read who the boss is targeting at this moment. The boss targets whoever
-- has highest threat, and at the very start of an encounter that's the
-- person who pulled (typically the tank). Different API surface than CLEU
-- and the damage meter — may bypass Midnight's restricted-state filters.
function EarlyPull:GetPullerFromBossTarget()
    for i = 1, 8 do
        local unit = "boss"..i.."target"
        local exists = UnitExists(unit)
        local isPlayer = exists and UnitIsPlayer(unit)
        local name, realm = (exists and UnitName(unit)) or nil, nil
        if exists and self.autoPrintDetails and not self._btDumped then
            self._btDumped = true
            self:Print(format("BT scan: %s exists=%s isPlayer=%s name=%s",
                unit, tostring(exists), tostring(isPlayer), tostring(name)))
        end
        if isPlayer and name and name ~= UNKNOWN and not issecretvalue(name) then
            local _, classFile = UnitClass(unit)
            return {
                name = realm and realm ~= "" and (name.."-"..realm) or name,
                classFilename = classFile,
                sourceGUID = safeUnitGUID(unit),
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
    if not ctx or ctx.puller then return end
    -- Prefer boss target (= tank = puller) over damage-meter heuristic.
    local actor = self:GetPullerFromBossTarget() or self:GetPullerFromDamageMeter()
    if not actor then return end
    ctx.puller = actor
    ctx.message = ctx.pullDesc.." by "..self:FormatPullerName(actor).."."
    self:Announce(ctx.announceChannel, ctx.message)
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

    if self.autoPrintDetails then
        self:Print(format("DM selection: bestActor=%s bestTotal=%s cmpErrors=%d sources=%d",
            bestActor and tostring(bestActor.name) or "nil",
            tostring(bestTotal), cmpErrors, #session.combatSources))
    end
    return bestActor
end

function EarlyPull:FormatPullerName(actor)
    if not actor then return "[Unknown]" end
    local ok, formatted = pcall(function()
        local name = actor.name or "[Unknown]"
        local class = safeKey(actor.classFilename)
        if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
            local c = RAID_CLASS_COLORS[class]
            return format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, name)
        end
        return tostring(name)
    end)
    if ok and formatted then return formatted end
    return "[Unknown]"
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
        self.pullContext.message = pullDesc.." by "..self:FormatPullerName(immediate).."."
        self:Announce(announceChannel, self.pullContext.message)
    end

    C_Timer.After(kPollDelays[1], function()
        self:EARLY_PULL_AFTER_PULL(self.id, now, 1)
    end)

    self:ScanAllBosses()
end

function EarlyPull:INSTANCE_ENCOUNTER_ENGAGE_UNIT()
    self:ScanAllBosses()
end

function EarlyPull:FindPetOwner(guid)
    local summoner = self.summons[guid] or self.summons2[guid]
    if summoner then return summoner end

    if self.inRaid then
        local raid = self.unitList.raid
        local raidpet = self.unitList.raidpet
        for i = 1, self.raidSize do
            if safeUnitGUID(raidpet[i]) == guid then
                return GetUnitName(raid[i])
            end
        end
    else
        if self.inParty then
            local party = self.unitList.party
            local partypet = self.unitList.partypet
            for i = 1, self.partySize do
                if safeUnitGUID(partypet[i]) == guid then
                    return GetUnitName(party[i])
                end
            end
        end
        if safeUnitGUID("pet") == guid then
            return GetUnitName("player")
        end
    end
end

function EarlyPull:FinalizeCandidate(cand)
    if not cand then return end

    local entry = cand.combatLogEntry
    if entry then
        cand.name = entry.name
        if cand.combatLogScore >= self.spellBlameCutoff then
            if self.combatLogSwingEventTest[entry.event] then
                cand.spellID = 6603 -- Auto Attack
            else
                cand.spellID = entry.spellID
            end
        end
    end

    cand.name = (cand.name
        or (cand.threatEntry and cand.threatEntry.name)
        or (cand.targetLogEntry and cand.targetLogEntry.name))

    local guid = cand.guid
    if guid and type(guid) == "string" and not guid:find("^Player") and not guid:find("^name:") then
        cand.petOwner = self:FindPetOwner(guid)
    end
end

function EarlyPull:GetBlameDesc(bestCand, secondCand)
    local blameDesc = " by unknown cause"
    if bestCand then
        local name = bestCand.name or "[Unknown]"
        local spellID = bestCand.spellID
        local petOwner = bestCand.petOwner

        if petOwner then
            blameDesc = " by "..petOwner.."'s pet "..name
        else
            blameDesc = " by "..name
        end

        if spellID then
            blameDesc = blameDesc.." "..(GetSpellLink(spellID) or "[spell:"..spellID.."]")
        end

        if bestCand.score - (secondCand and secondCand.score or 0) < self.lowCertaintyCutoff then
            blameDesc = blameDesc.." (?)"
        end
    end
    return blameDesc
end

function EarlyPull:DetermineBlame(ctx)
    local pullTime = ctx.pullTime
    local cwBeginTime = pullTime + self.criticalWindowBegin
    local cwEndTime = pullTime + self.criticalWindowEnd

    local timelinessCenter = pullTime + self.timelinessOffset
    local timelinessDecayRate = self.timelinessDecayRate
    local function getTimelinessPenalty(entry)
        return 1 - timelinessDecayRate * abs(entry.time - timelinessCenter)
    end

    local candidates = {}

    local function getCandidate(guid)
        local cand = candidates[guid] or {guid = guid, combatLogScore = 0, threatScore = 0, targetScore = 0}
        candidates[guid] = cand
        return cand
    end

    local bosses = {}

    for _, entry in self:IterateLogWindow(self.bossLog, cwBeginTime, cwEndTime) do
        if entry.guid then
            bosses[entry.guid] = true
        end
    end

    for _, entry in self:IterateLogWindow(self.combatLog, cwBeginTime, cwEndTime) do
        if entry.guid then
            local score = self.combatLogBaseScore * getTimelinessPenalty(entry)
            if not self.combatLogDamageEventTest[entry.event] then
                score = score * self.combatLogNonDamagePenalty
            end
            if entry.event == "SPELL_CAST_SUCCESS" then
                score = score * self.combatLogSpellCastPenalty
            end
            if not (entry.destGUID and bosses[entry.destGUID]) then
                score = score * self.combatLogNonBossTargetPenalty
            end

            local cand = getCandidate(entry.guid)
            if score > cand.combatLogScore then
                cand.combatLogScore = score
                cand.combatLogEntry = entry
            end
        end
    end

    local earliestThreatTable

    for _, entry in self:IterateLogWindow(self.threatLog, cwBeginTime, cwEndTime) do
        local threatEntries = entry.threatEntries
        local count = threatEntries.count
        if count > 0 then
            earliestThreatTable = earliestThreatTable or entry.time

            local highestThreatValue = 0
            for j = 1, count do
                highestThreatValue = max(highestThreatValue, threatEntries[j].threatValue or 0)
            end

            local notEarliestPenalty = (entry.time == earliestThreatTable) and 1 or self.threatLogNotEarliestPenalty
            for j = 1, count do
                local threatEntry = threatEntries[j]

                local score = self.threatLogBaseScore * getTimelinessPenalty(entry) * notEarliestPenalty
                if not threatEntry.isTanking then
                    if threatEntry.threatValue == highestThreatValue then
                        score = score * self.threatLogOffTankPenalty
                    else
                        score = score * self.threatLogNonTankPenalty
                    end
                end

                local cand = getCandidate(threatEntry.guid)
                if score > cand.threatScore then
                    cand.threatScore = score
                    cand.threatEntry = threatEntry
                end
            end
        end
    end

    local earliestTarget

    for _, entry in self:IterateLogWindow(self.targetLog, cwBeginTime, cwEndTime) do
        earliestTarget = earliestTarget or entry.time

        local notEarliestPenalty = (entry.time == earliestTarget) and 1 or self.targetLogNotEarliestPenalty

        local score = self.targetLogBaseScore * getTimelinessPenalty(entry) * notEarliestPenalty

        local cand = getCandidate(entry.guid)
        if score > cand.targetScore then
            cand.targetScore = score
            cand.targetLogEntry = entry
        end
    end

    local bestScore, bestCand = 0, nil
    local secondScore, secondCand = 0, nil

    for _, cand in pairs(candidates) do
        local score = cand.combatLogScore + cand.threatScore + cand.targetScore
        cand.score = score
        if score > bestScore then
            secondScore, secondCand = bestScore, bestCand
            bestScore, bestCand = score, cand
        elseif score > secondScore then
            secondScore, secondCand = score, cand
        end
    end

    self:FinalizeCandidate(bestCand)
    self:FinalizeCandidate(secondCand)

    return bestCand, secondCand
end

function EarlyPull:EARLY_PULL_AFTER_PULL(id, pullTime, afterPullIndex)
    local ctx = self.pullContext
    if id ~= self.id or not ctx or pullTime ~= ctx.pullTime then
        return
    end

    -- Resolve the puller and fire the banner with the full message. Boss
    -- target is preferred (= tank = actual puller). Damage meter is a fallback
    -- but biases toward burst-DPS classes due to Midnight's secret-wrapped
    -- damage values that can't be sorted accurately.
    local actor = self:GetPullerFromBossTarget() or self:GetPullerFromDamageMeter()
    if actor then
        ctx.puller = actor
        ctx.message = ctx.pullDesc.." by "..self:FormatPullerName(actor).."."
        self:Announce(ctx.announceChannel, ctx.message)
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
        -- All polls exhausted; fire banner with no-name fallback.
        ctx.message = ctx.pullDesc.." by [Unknown]."
        self:Announce(ctx.announceChannel, ctx.message)
        if self.autoPrintDetails then
            self:PrintPullDetails()
        end
    end
end

function EarlyPull:Announce(announceChannel, message)
    if announceChannel == "BANNER" then
        if RaidNotice_AddMessage and RaidWarningFrame then
            local info = ChatTypeInfo and ChatTypeInfo["RAID_WARNING"]
            RaidNotice_AddMessage(RaidWarningFrame, message, info or {r = 1, g = 0.3, b = 0.3})
        else
            self:Print(message)
        end
        return true
    elseif announceChannel == "CHAT" then
        self:Print(message)
        return true
    end
    return false
end

function EarlyPull:PrintCandidateDetails(cand, intro)
    local petOwnerSuffix = cand.petOwner and " (petOwner="..tostring(cand.petOwner)..")" or ""
    local spellDesc = cand.spellID and GetSpellLink(cand.spellID) or "[spell:"..tostring(cand.spellID).."]"
    self:Print(format("%s%s%s %s with score=%.2f (combatLog=%.2f, threat=%.2f, target=%.2f).",
        intro, tostring(cand.name), petOwnerSuffix, spellDesc,
        cand.score, cand.combatLogScore, cand.threatScore, cand.targetScore))
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
