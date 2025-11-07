--[[ 
Reretarget (SuperWoW + GUID Integration - Hunter Only)
IMPROVEMENT: UNIT_CASTEVENT-based Feign Death detection
- ONLY tracks Hunters (Rogues removed - retarget makes no sense for Vanish)
- Instant detection: Cast event = Feign Death, No cast = Real death
- NO MORE TIMERS - instant reaction!
- FIXED: Race condition when Hunter re-casts FD immediately after standing up
- FIXED: Target check for FD when selecting dead Hunter
- FIXED: Memory leak in lastDeathWasFD table
]]

-- ===== PERFORMANCE: Cache global functions =====
local strfind = string.find
local strlower = string.lower
local strformat = string.format
local GetTime = GetTime
local UnitExists = UnitExists
local UnitIsPlayer = UnitIsPlayer
local UnitName = UnitName
local UnitClass = UnitClass
local UnitIsDead = UnitIsDead
local UnitPlayerControlled = UnitPlayerControlled

-- ===== GLOBALS =====
local debugPrefix = "|cff9966ff[Retarget]|r"
local TargetCheck = CreateFrame("Frame")
local GuidCollector = CreateFrame("Frame")

-- Minimale Speicherung - nur aktuelles Tracking-Ziel
local trackedGUID = nil
local trackedName = nil

-- Feign Death Cast Tracking
local feignDeathCastDetected = {}  -- guid -> timestamp
local feignDeathStandUpTime = {}   -- guid -> timestamp when hunter stood up
local lastDeathWasFD = {}          -- guid -> boolean (remembers if last death was FD)
local FEIGN_DEATH_CLEANUP_WINDOW = 5.0  -- Clean up old entries after 5s
local FD_RECAST_WINDOW = 0.5  -- 0.5 seconds buffer for re-casts after standing up

local lastDebugMessage = ""
local lastDebugTime = 0

-- GUID Cache
local GUIDCache = {}
local NameToGUID = {}

-- Debug mode
local debugMode = false

-- Stats
local Stats = {
    retargetsAttempted = 0,
    retargetsSuccessful = 0,
    guidsCollected = 0,
    feignDeathCastsDetected = 0,
    realDeathsDetected = 0,
}

-- ===== Spell IDs für Detection =====
local FEIGN_DEATH_SPELL_IDS = {
    [5384] = true,  -- Feign Death (Rank 1)
    [5385] = true,  -- Feign Death (Rank 2)
}

-- ===== SUPERWOW CHECK =====
local function CheckSuperWoW()
    local hasSuperWoW = (_G.TargetUnit ~= nil and _G.UnitExists ~= nil and _G.SpellInfo ~= nil)
    
    if not hasSuperWoW then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000============================================|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Retarget] CRITICAL ERROR: SuperWoW NOT DETECTED!|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00This addon REQUIRES SuperWoW to function.|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Without SuperWoW, GUID-based retargeting will not work.|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Please install SuperWoW from:|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00https://github.com/balakethelock/SuperWoW|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Retarget addon has been DISABLED.|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Please reload UI after installing SuperWoW.|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000============================================|r")
        
        -- Block slash command
        SlashCmdList["RT"] = function()
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Retarget]|r Retarget is DISABLED - SuperWoW not detected!")
            DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Please install SuperWoW and reload UI.|r")
        end
        SLASH_RT1 = "/rt"
        
        -- Disable all frames
        if TargetCheck then
            TargetCheck:Hide()
            TargetCheck:SetScript("OnUpdate", nil)
        end
        
        if GuidCollector then
            GuidCollector:UnregisterAllEvents()
            GuidCollector:Hide()
            GuidCollector:SetScript("OnEvent", nil)
        end
        
        return false
    end
    
    return true
end

-- ===== UTILITIES =====
local function Debug(msg)
    if debugMode and DEFAULT_CHAT_FRAME then
        local now = GetTime()
        if msg ~= lastDebugMessage or (now - lastDebugTime) > 1 then
            DEFAULT_CHAT_FRAME:AddMessage(debugPrefix .. " " .. msg)
            lastDebugMessage = msg
            lastDebugTime = now
        end
    end
end

-- ===== TOOLTIP SCANNER für Feign Death Buff =====
local RetargetBuffScanner = CreateFrame("GameTooltip", "RetargetBuffScanner", nil, "GameTooltipTemplate")
RetargetBuffScanner:SetOwner(WorldFrame, "ANCHOR_NONE")

local function ScanBuffName(unit, buffIndex)
    if not unit then return nil end
    RetargetBuffScanner:ClearLines()
    RetargetBuffScanner:SetOwner(WorldFrame, "ANCHOR_NONE")
    RetargetBuffScanner:SetUnitBuff(unit, buffIndex)
    
    local buffName = _G["RetargetBuffScannerTextLeft1"]
    if buffName and buffName:IsVisible() then
        local text = buffName:GetText()
        return text
    end
    return nil
end

local function HasFeignDeath(unit)
    for i = 1, 32 do
        local buff = ScanBuffName(unit, i)
        if buff then
            local buffLower = strlower(tostring(buff))
            if strfind(buffLower, "feign death") or strfind(buffLower, "totstellen") then
                return true
            end
        end
    end
    return false
end

-- ===== GUID COLLECTION =====
local function AddUnit(unit)
    local _, guid = UnitExists(unit)
    if not guid then return end
    
    -- Pet-Filter
    local isPlayer = UnitIsPlayer(guid)
    local isControlled = UnitPlayerControlled(guid)
    local isPet = not isPlayer and isControlled
    
    if isPet then return end
    
    -- Nur echte Spieler
    if isPlayer then
        local class = UnitClass(guid)
        if not class then return end
        
        local isNew = GUIDCache[guid] == nil
        local name = UnitName(guid)
        local _, classToken = UnitClass(guid)
        
        if name then
            GUIDCache[guid] = {
                name = name,
                class = classToken,
                time = GetTime()
            }
            
            NameToGUID[name] = guid
            
            if isNew then
                Stats.guidsCollected = Stats.guidsCollected + 1
                Debug(strformat("GUID collected: %s (%s)", name, classToken or "?"))
            end
        end
    end
end

-- ===== CHECK: Ist Unit ein Pet? =====
local function IsPet(unit)
    if not UnitExists(unit) then return false end
    local _, guid = UnitExists(unit)
    if not guid then return false end
    
    local isPlayer = UnitIsPlayer(guid)
    local isControlled = UnitPlayerControlled(guid)
    
    return (not isPlayer and isControlled)
end

-- ===== Feign Death Tracking =====
local function HasFeignDeathCast(hunterGUID)
    return feignDeathCastDetected[hunterGUID] ~= nil
end

local function MarkFeignDeathCast(hunterGUID)
    local now = GetTime()
    local previousCast = feignDeathCastDetected[hunterGUID]
    
    feignDeathCastDetected[hunterGUID] = now
    feignDeathStandUpTime[hunterGUID] = nil  -- Clear stand-up time on new cast
    Stats.feignDeathCastsDetected = Stats.feignDeathCastsDetected + 1
    
    local name = UnitName(hunterGUID) or "Unknown"
    
    if previousCast then
        local timeSince = now - previousCast
        Debug(strformat("|cffff0000FEIGN DEATH CAST!|r %s (%.2fs since last cast)", name, timeSince))
    else
        Debug(strformat("|cffff0000FEIGN DEATH CAST!|r %s (first cast)", name))
    end
end

local function ClearFeignDeathCast(hunterGUID)
    feignDeathCastDetected[hunterGUID] = nil
    feignDeathStandUpTime[hunterGUID] = nil
end

-- ===== RETARGET LOGIC =====
local function TryReTarget()
    if not trackedGUID then return false end
    
    if not _G.TargetUnit then
        Debug("|cffff0000SuperWoW TargetUnit() not available!|r")
        return false
    end
    
    Stats.retargetsAttempted = Stats.retargetsAttempted + 1
    Debug(strformat("Versuche Re-Target: %s [%s]", trackedName or "?", trackedGUID))
    
    TargetUnit(trackedGUID)
    
    if UnitExists("target") then
        local _, afterGUID = UnitExists("target")
        
        if afterGUID == trackedGUID then
            Stats.retargetsSuccessful = Stats.retargetsSuccessful + 1
            Debug("|cff00ff00Re-Target erfolgreich!|r")
            return true
        end
    end
    
    Debug("Re-Target fehlgeschlagen.")
    return false
end

-- ===== GUID CLEANUP =====
local cleanupTimer = 0
local CLEANUP_INTERVAL = 30

local function CleanupOldGUIDs()
    local currentTime = GetTime()
    local removed = 0
    
    -- Cleanup GUIDs that no longer exist (unit is gone)
    for guid, data in pairs(GUIDCache) do
        if not UnitExists(guid) then
            GUIDCache[guid] = nil
            removed = removed + 1
        end
    end
    
    -- Cleanup old Feign Death cast entries
    for guid, castTime in pairs(feignDeathCastDetected) do
        if (currentTime - castTime) > FEIGN_DEATH_CLEANUP_WINDOW then
            feignDeathCastDetected[guid] = nil
        end
    end
    
    -- Cleanup old stand-up times
    for guid, standUpTime in pairs(feignDeathStandUpTime) do
        if (currentTime - standUpTime) > FEIGN_DEATH_CLEANUP_WINDOW then
            feignDeathStandUpTime[guid] = nil
        end
    end
    
    -- MEMORY LEAK FIX: Cleanup old lastDeathWasFD entries
    for guid, _ in pairs(lastDeathWasFD) do
        if not GUIDCache[guid] then
            lastDeathWasFD[guid] = nil
        end
    end
    
    if removed > 0 then
        Debug(strformat("Cleaned up %d old GUIDs", removed))
    end
end

-- ===== ONUPDATE LOOP =====
local function OnUpdateFrame(self, elapsed)
    elapsed = arg1 or 0.01
    
    cleanupTimer = cleanupTimer + elapsed
    if cleanupTimer >= CLEANUP_INTERVAL then
        cleanupTimer = 0
        CleanupOldGUIDs()
    end
    
    -- Fall 1: Kein Target vorhanden
    if not UnitExists("target") then
        if trackedGUID then
            -- INSTANT CHECK: Was FD casted?
            if HasFeignDeathCast(trackedGUID) then
                -- YES: Feign Death → INSTANT re-target
                Debug("✅ FD Cast detected → INSTANT re-target!")
                
                -- Mark this death as FD
                lastDeathWasFD[trackedGUID] = true
                
                if TryReTarget() then
                    -- Verify it's really FD by checking buff
                    local isDead = UnitIsDead("target")
                    local hasFD = HasFeignDeath("target")
                    
                    Debug(strformat("Re-Target Check: isDead=%s, hasFD=%s", tostring(isDead), tostring(hasFD)))
                    
                    if isDead and hasFD then
                        Debug("FD confirmed, keeping target")
                    else
                        -- FD ended or wasn't real FD
                        Debug(strformat("|cffffcc00WARNING:|r No FD buff found! isDead=%s, hasFD=%s", tostring(isDead), tostring(hasFD)))
                        ClearFeignDeathCast(trackedGUID)
                        lastDeathWasFD[trackedGUID] = nil
                        trackedGUID = nil
                        trackedName = nil
                        TargetUnit("player")
                        ClearTarget()
                    end
                else
                    -- Re-target failed
                    Debug("Re-target failed, clearing tracking")
                    ClearFeignDeathCast(trackedGUID)
                    lastDeathWasFD[trackedGUID] = nil
                    trackedGUID = nil
                    trackedName = nil
                end
            else
                -- NO FD cast detected
                -- BUT: Check if last death was FD (edge case: stood up quickly then died again)
                if lastDeathWasFD[trackedGUID] then
                    Debug("|cffffcc00EDGE CASE:|r No FD cast flag, but lastDeathWasFD=true")
                    Debug(strformat("  trackedGUID: %s", trackedGUID or "nil"))
                    Debug(strformat("  trackedName: %s", trackedName or "nil"))
                    Debug("  Reason: FD flag was cleared but death occurred shortly after")
                    Debug("  Trying re-target anyway to verify...")
                    
                    if TryReTarget() then
                        local isDead = UnitIsDead("target")
                        local hasFD = HasFeignDeath("target")
                        
                        if isDead and hasFD then
                            Debug("FD confirmed (via edge case), keeping target")
                        else
                            -- Really dead this time
                            Stats.realDeathsDetected = Stats.realDeathsDetected + 1
                            Debug("|cffff0000❌ Really dead this time!|r")
                            lastDeathWasFD[trackedGUID] = nil
                            trackedGUID = nil
                            trackedName = nil
                            TargetUnit("player")
                            ClearTarget()
                        end
                    else
                        Stats.realDeathsDetected = Stats.realDeathsDetected + 1
                        Debug("|cffff0000❌ Re-target failed, really dead|r")
                        lastDeathWasFD[trackedGUID] = nil
                        trackedGUID = nil
                        trackedName = nil
                        TargetUnit("player")
                        ClearTarget()
                    end
                else
                    -- NO: Real death → INSTANT stop tracking
                    Stats.realDeathsDetected = Stats.realDeathsDetected + 1
                    Debug("|cffff0000❌ No FD cast → REAL DEATH, stop tracking|r")
                    trackedGUID = nil
                    trackedName = nil
                end
            end
        end
        return
    end
    
    -- Fall 2: Target vorhanden
    local _, targetGUID = UnitExists("target")
    if not targetGUID then return end
    
    AddUnit("target")
    
    -- Pet check
    if IsPet("target") then
        if trackedGUID and HasFeignDeathCast(trackedGUID) then
            Debug("Pet detected during FD, returning to Hunter")
            TryReTarget()
        end
        return
    end
    
    -- Player check
    local isPlayer = UnitIsPlayer(targetGUID)
    if not isPlayer then
        if trackedGUID then
            Debug("NPC targeted, clearing tracking")
            trackedGUID = nil
            trackedName = nil
            ClearFeignDeathCast(targetGUID)
        end
        return
    end
    
    -- Fall 3: Spieler im Target
    local _, classToken = UnitClass("target")
    
    if targetGUID ~= trackedGUID then
        -- New target selected
        if trackedGUID then
            Debug("New target selected, clearing old tracking")
            ClearFeignDeathCast(trackedGUID)
        end
        
        -- Only track Hunters now!
        if classToken == "HUNTER" then
            local isDead = UnitIsDead("target")
            
            if not isDead then
                -- Hunter is alive → start normal tracking
                trackedGUID = targetGUID
                trackedName = UnitName("target")
                Debug(strformat("Tracking started: %s (HUNTER)", trackedName))
            else
                -- Hunter is dead → check if it's FD via buff scan
                local hasFD = HasFeignDeath("target")
                
                if hasFD then
                    -- Dead + FD Buff = Feign Death → start tracking!
                    trackedGUID = targetGUID
                    trackedName = UnitName("target")
                    Debug(strformat("Tracking started: %s (HUNTER in FD)", trackedName))
                else
                    -- Dead without FD buff = really dead
                    Debug("Target is dead (no FD buff), not starting tracking")
                    trackedGUID = nil
                    trackedName = nil
                end
            end
        else
            trackedGUID = nil
            trackedName = nil
        end
    else
        -- Same target as tracked (must be Hunter)
        local isDead = UnitIsDead("target")
        
        -- Hunter stood up?
        if not isDead and HasFeignDeathCast(trackedGUID) then
            if not feignDeathStandUpTime[trackedGUID] then
                Debug("Hunter stood up, marking stand-up time")
            end
            feignDeathStandUpTime[trackedGUID] = GetTime()
        end
        
        -- Check if we should clear old FD flags (with buffer time for re-casts)
        if feignDeathStandUpTime[trackedGUID] and not isDead then
            local timeSinceStandUp = GetTime() - feignDeathStandUpTime[trackedGUID]
            if timeSinceStandUp > FD_RECAST_WINDOW then
                -- Enough time passed, really stood up and not re-casting
                Debug(strformat("Clearing FD flags after %.2fs stand-up time", timeSinceStandUp))
                ClearFeignDeathCast(trackedGUID)
                lastDeathWasFD[trackedGUID] = nil
            end
        end
        
        -- Lost FD buff while dead = really dead
        if isDead and HasFeignDeathCast(trackedGUID) and not HasFeignDeath("target") then
            Debug("Lost FD buff while dead → really dead!")
            Stats.realDeathsDetected = Stats.realDeathsDetected + 1
            ClearFeignDeathCast(trackedGUID)
            lastDeathWasFD[trackedGUID] = nil
            trackedGUID = nil
            trackedName = nil
            TargetUnit("player")
            ClearTarget()
        end
    end
end

-- ===== EVENT HANDLER =====
GuidCollector:RegisterEvent("PLAYER_TARGET_CHANGED")
GuidCollector:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
GuidCollector:RegisterEvent("PLAYER_ENTERING_WORLD")
GuidCollector:RegisterEvent("UNIT_COMBAT")
GuidCollector:RegisterEvent("UNIT_AURA")
GuidCollector:RegisterEvent("UNIT_CASTEVENT")

GuidCollector:SetScript("OnEvent", function()
    if event == "PLAYER_TARGET_CHANGED" then
        if UnitExists("target") then
            AddUnit("target")
        end
        if UnitExists("targettarget") then
            AddUnit("targettarget")
        end
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        if UnitExists("mouseover") then
            AddUnit("mouseover")
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        Debug("Addon loaded. GUID system active.")
        AddUnit("player")
    elseif event == "UNIT_CASTEVENT" then
        -- INSTANT Detection via UNIT_CASTEVENT
        local casterGUID, targetGUID, eventType, spellID, castDuration = arg1, arg2, arg3, arg4, arg5
        
        -- ✅ Debug: ALWAYS log Feign Death casts (even in non-debug mode)
        if FEIGN_DEATH_SPELL_IDS[spellID] then
            local casterName = UnitName(casterGUID) or "Unknown"
            local isOurTarget = (trackedGUID and casterGUID == trackedGUID)
            local guidMatch = trackedGUID and strformat("tracked=%s, caster=%s", trackedGUID, casterGUID) or "no tracking"
            
            --DEFAULT_CHAT_FRAME:AddMessage(strformat("|cffff00ff[FD CAST EVENT]|r %s | Type:%s | Match:%s | %s", 
                --casterName, eventType, tostring(isOurTarget), guidMatch))
        end
        
        -- Debug: Log ALL cast events in debug mode
        if debugMode and eventType and spellID then
            local casterName = UnitName(casterGUID) or "Unknown"
            local spellName = "Unknown"
            if SpellInfo then
                local name, rank = SpellInfo(spellID)
                spellName = name or "Unknown"
            end
            
            -- Mark if this is our tracked target
            local isTracked = (trackedGUID and casterGUID == trackedGUID)
            local marker = isTracked and " |cff00ff00[TRACKED]|r" or ""
            
            Debug(strformat("CAST EVENT: %s cast %s (ID:%d, Type:%s)%s", casterName, spellName, spellID, eventType, marker))
        end
        
        if eventType ~= "CAST" and eventType ~= "CHANNEL" then
            return
        end
        
        -- ✅ IMPORTANT: Only track Feign Death from our tracked Hunter!
        if FEIGN_DEATH_SPELL_IDS[spellID] then
            -- Check if this is from our tracked target
            if trackedGUID and casterGUID == trackedGUID then
                MarkFeignDeathCast(casterGUID)
            else
                -- Different hunter - ignore
                if debugMode then
                    local name = UnitName(casterGUID) or "Unknown"
                    Debug(strformat("|cffaaaaaa[IGNORED]|r %s cast FD (not tracked)", name))
                end
            end
        end
    else
        local unit = arg1
        if unit and UnitExists(unit) and UnitIsPlayer(unit) then
            AddUnit(unit)
        end
    end
end)

TargetCheck:SetScript("OnUpdate", OnUpdateFrame)

-- ===== SLASH COMMANDS =====
SlashCmdList["RT"] = function(msg)
    if not msg or msg == "" or msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff========== Retarget Status ==========|r")
        
        local hasSuperWoW = (_G.TargetUnit ~= nil)
        if hasSuperWoW then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00SuperWoW:|r |cff00ff00AVAILABLE|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00SuperWoW:|r |cffff0000NOT AVAILABLE|r")
        end
        
        local guidCount = 0
        for _ in pairs(GUIDCache) do
            guidCount = guidCount + 1
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Cached GUIDs:|r " .. guidCount)
        
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Statistics:|r")
        DEFAULT_CHAT_FRAME:AddMessage("  GUIDs Collected: " .. Stats.guidsCollected)
        DEFAULT_CHAT_FRAME:AddMessage("  Retargets Attempted: " .. Stats.retargetsAttempted)
        DEFAULT_CHAT_FRAME:AddMessage("  Retargets Successful: " .. Stats.retargetsSuccessful)
        DEFAULT_CHAT_FRAME:AddMessage("  Feign Death Casts: " .. Stats.feignDeathCastsDetected)
        DEFAULT_CHAT_FRAME:AddMessage("  Real Deaths: " .. Stats.realDeathsDetected)
        
        if trackedGUID then
            local status = ""
            if HasFeignDeathCast(trackedGUID) then
                status = " [FD ACTIVE]"
            end
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Currently Tracking:|r " .. (trackedName or "?") .. " (HUNTER)" .. status)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Currently Tracking:|r None")
        end
        
        DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff======================================|r")
    elseif msg == "debug" then
        debugMode = not debugMode
        if debugMode then
            DEFAULT_CHAT_FRAME:AddMessage(debugPrefix .. " Debug mode |cff00ff00ENABLED|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage(debugPrefix .. " Debug mode |cffff0000DISABLED|r")
        end
    elseif msg == "clear" then
        GUIDCache = {}
        NameToGUID = {}
        trackedGUID = nil
        trackedName = nil
        feignDeathCastDetected = {}
        feignDeathStandUpTime = {}
        lastDeathWasFD = {}
        Stats.guidsCollected = 0
        Stats.retargetsAttempted = 0
        Stats.retargetsSuccessful = 0
        Stats.feignDeathCastsDetected = 0
        Stats.realDeathsDetected = 0
        DEFAULT_CHAT_FRAME:AddMessage(debugPrefix .. " All data cleared!")
    elseif msg == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff========== Retarget Commands ==========|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/rt status|r - Show addon status")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/rt debug|r - Toggle debug mode")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/rt clear|r - Clear all cached data")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/rt help|r - Show this help")
    else
        DEFAULT_CHAT_FRAME:AddMessage(debugPrefix .. " Unknown command. Use /rt help")
    end
end
SLASH_RT1 = "/rt"

-- ===== INITIALIZATION =====
if CheckSuperWoW() then
    DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff[Retarget]|r Loaded. SuperWoW GUID integration active.")
    DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff[Retarget]|r Use /rt status to check system.")
else
    -- Addon disabled due to missing SuperWoW
    -- Error message already shown in CheckSuperWoW()
end