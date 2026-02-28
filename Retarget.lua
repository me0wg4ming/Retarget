--[[
Retarget (Nampower - Hunter Only)
- Tracks enemy Hunters and retargets after Feign Death
- Uses GetUnitField("health") for instant FD detection - no tooltip scan needed
- UNIT_CASTEVENT for instant FD cast detection
- Requires Nampower (no SuperWoW needed)
]]

-- ===== PERFORMANCE: Cache global functions =====
local strformat = string.format
local GetTime = GetTime
local UnitExists = UnitExists
local UnitIsPlayer = UnitIsPlayer
local UnitName = UnitName
local UnitClass = UnitClass
local UnitPlayerControlled = UnitPlayerControlled

-- ===== GLOBALS =====
local debugPrefix = "|cff9966ff[Retarget]|r"
local TargetCheck = CreateFrame("Frame")
local GuidCollector = CreateFrame("Frame")

-- Tracking
local trackedGUID = nil
local trackedName = nil

-- Feign Death tracking
local feignDeathCastDetected = {}  -- guid -> timestamp
local feignDeathStandUpTime = {}   -- guid -> timestamp when hunter stood up
local lastDeathWasFD = {}          -- guid -> boolean
local FEIGN_DEATH_CLEANUP_WINDOW = 5.0
local FD_RECAST_WINDOW = 0.5

local lastDebugMessage = ""
local lastDebugTime = 0

-- GUID Cache
local GUIDCache = {}
local NameToGUID = {}

local debugMode = false

local Stats = {
  retargetsAttempted = 0,
  retargetsSuccessful = 0,
  guidsCollected = 0,
  feignDeathCastsDetected = 0,
  realDeathsDetected = 0,
}

local FEIGN_DEATH_SPELL_IDS = {
  [5384] = true,  -- Feign Death (Rank 1)
  [5385] = true,  -- Feign Death (Rank 2)
}

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

-- ===== HEALTH CHECK via Nampower =====
-- Returns true if unit is alive (including Feign Death)
-- Returns false if unit is really dead
local function IsUnitAlive(guid)
  if not GetUnitField then return nil end
  local hp = GetUnitField(guid, "health")
  return hp and hp > 0
end

-- ===== GUID COLLECTION =====
local function AddUnit(unit)
  local _, guid = UnitExists(unit)
  if not guid then return end

  local isPlayer = UnitIsPlayer(guid)
  local isControlled = UnitPlayerControlled(guid)
  local isPet = not isPlayer and isControlled
  if isPet then return end

  if isPlayer then
    local _, classToken = UnitClass(guid)
    if classToken ~= "HUNTER" then return end
    if not UnitCanAttack("player", guid) then return end
    if not UnitIsPVP(guid) then return end

    local isNew = GUIDCache[guid] == nil
    local name = UnitName(guid)

    if name then
      GUIDCache[guid] = { name = name, class = classToken, time = GetTime() }
      NameToGUID[name] = guid
      if isNew then
        Stats.guidsCollected = Stats.guidsCollected + 1
        Debug(strformat("GUID collected: %s (HUNTER, PvP)", name))
      end
    end
  end
end

local function IsPet(unit)
  if not UnitExists(unit) then return false end
  local _, guid = UnitExists(unit)
  if not guid then return false end
  return not UnitIsPlayer(guid) and UnitPlayerControlled(guid)
end

-- ===== Feign Death Tracking =====
local function HasFeignDeathCast(hunterGUID)
  return feignDeathCastDetected[hunterGUID] ~= nil
end

local function MarkFeignDeathCast(hunterGUID)
  local now = GetTime()
  local previousCast = feignDeathCastDetected[hunterGUID]
  feignDeathCastDetected[hunterGUID] = now
  feignDeathStandUpTime[hunterGUID] = nil
  Stats.feignDeathCastsDetected = Stats.feignDeathCastsDetected + 1
  local name = UnitName(hunterGUID) or "Unknown"
  if previousCast then
    Debug(strformat("|cffff0000FEIGN DEATH CAST!|r %s (%.2fs since last)", name, now - previousCast))
  else
    Debug(strformat("|cffff0000FEIGN DEATH CAST!|r %s", name))
  end
end

local function ClearFeignDeathCast(hunterGUID)
  feignDeathCastDetected[hunterGUID] = nil
  feignDeathStandUpTime[hunterGUID] = nil
end

-- ===== RETARGET =====
local function TryReTarget()
  if not trackedGUID then return false end
  Stats.retargetsAttempted = Stats.retargetsAttempted + 1
  Debug(strformat("Trying re-target: %s [%s]", trackedName or "?", trackedGUID))
  TargetUnit(trackedGUID)
  if UnitExists("target") then
    local _, afterGUID = UnitExists("target")
    if afterGUID == trackedGUID then
      Stats.retargetsSuccessful = Stats.retargetsSuccessful + 1
      Debug("|cff00ff00Re-target successful!|r")
      return true
    end
  end
  Debug("Re-target failed.")
  return false
end

-- ===== GUID CLEANUP =====
local cleanupTimer = 0
local CLEANUP_INTERVAL = 30

local function CleanupOldGUIDs()
  local now = GetTime()
  for guid in pairs(GUIDCache) do
    if not UnitExists(guid) then GUIDCache[guid] = nil end
  end
  for guid, castTime in pairs(feignDeathCastDetected) do
    if (now - castTime) > FEIGN_DEATH_CLEANUP_WINDOW then feignDeathCastDetected[guid] = nil end
  end
  for guid, standUpTime in pairs(feignDeathStandUpTime) do
    if (now - standUpTime) > FEIGN_DEATH_CLEANUP_WINDOW then feignDeathStandUpTime[guid] = nil end
  end
  for guid in pairs(lastDeathWasFD) do
    if not GUIDCache[guid] then lastDeathWasFD[guid] = nil end
  end
end

-- ===== ONUPDATE =====
local function OnUpdateFrame(self, elapsed)
  elapsed = arg1 or 0.01

  cleanupTimer = cleanupTimer + elapsed
  if cleanupTimer >= CLEANUP_INTERVAL then
    cleanupTimer = 0
    CleanupOldGUIDs()
  end

  -- No target
  if not UnitExists("target") then
    if trackedGUID then
      if HasFeignDeathCast(trackedGUID) then
        -- FD cast detected - check health via GetUnitField
        local alive = IsUnitAlive(trackedGUID)

        if alive then
          -- HP > 0 = Feign Death confirmed
          Debug("✅ FD confirmed via HP check → re-targeting!")
          lastDeathWasFD[trackedGUID] = true
          TryReTarget()
        elseif alive == false then
          -- HP = 0 = really dead
          Debug("|cffff0000HP = 0 → REALLY DEAD!|r")
          Stats.realDeathsDetected = Stats.realDeathsDetected + 1
          ClearFeignDeathCast(trackedGUID)
          lastDeathWasFD[trackedGUID] = nil
          trackedGUID = nil
          trackedName = nil
        else
          -- GetUnitField returned nil (unit gone from client)
          -- Fall back to retarget attempt
          if TryReTarget() then
            local hp = GetUnitField and GetUnitField(trackedGUID, "health")
            if hp and hp > 0 then
              Debug("FD confirmed after retarget")
              lastDeathWasFD[trackedGUID] = true
            else
              Debug("|cffff0000No HP after retarget → REALLY DEAD|r")
              Stats.realDeathsDetected = Stats.realDeathsDetected + 1
              ClearFeignDeathCast(trackedGUID)
              lastDeathWasFD[trackedGUID] = nil
              trackedGUID = nil
              trackedName = nil
              ClearTarget()
            end
          else
            Stats.realDeathsDetected = Stats.realDeathsDetected + 1
            ClearFeignDeathCast(trackedGUID)
            lastDeathWasFD[trackedGUID] = nil
            trackedGUID = nil
            trackedName = nil
          end
        end

      elseif lastDeathWasFD[trackedGUID] then
        -- Edge case: stood up quickly then died again
        Debug("|cffffcc00EDGE CASE:|r checking HP directly")
        local alive = IsUnitAlive(trackedGUID)
        if alive then
          Debug("HP > 0 → FD again, re-targeting")
          TryReTarget()
        else
          Stats.realDeathsDetected = Stats.realDeathsDetected + 1
          lastDeathWasFD[trackedGUID] = nil
          trackedGUID = nil
          trackedName = nil
        end
      else
        -- No FD cast, no history - check if still alive (manual detarget vs real death)
        local alive = IsUnitAlive(trackedGUID)
        if alive then
          Debug("|cffffcc00Target manually cleared, stopping tracking|r")
        else
          Stats.realDeathsDetected = Stats.realDeathsDetected + 1
          Debug("|cffff0000No FD cast → REAL DEATH|r")
        end
        trackedGUID = nil
        trackedName = nil
      end
    end
    return
  end

  -- Target exists
  local _, targetGUID = UnitExists("target")
  if not targetGUID then return end

  AddUnit("target")

  if IsPet("target") then
    if trackedGUID and HasFeignDeathCast(trackedGUID) then
      Debug("Pet detected during FD, returning to Hunter")
      TryReTarget()
    end
    return
  end

  if not UnitIsPlayer(targetGUID) then
    if trackedGUID then
      Debug("NPC targeted, clearing tracking")
      trackedGUID = nil
      trackedName = nil
      ClearFeignDeathCast(targetGUID)
    end
    return
  end

  local _, classToken = UnitClass("target")

  if targetGUID ~= trackedGUID then
    if trackedGUID then ClearFeignDeathCast(trackedGUID) end

    if classToken == "HUNTER" then
      if not UnitCanAttack("player", "target") then trackedGUID = nil trackedName = nil return end
      if not UnitIsPVP("target") then Debug("Hunter not PvP-flagged") trackedGUID = nil trackedName = nil return end

      -- Use HP to check if alive or FD
      local hp = GetUnitField and GetUnitField(targetGUID, "health")
      local alive = hp and hp > 0

      if alive then
        trackedGUID = targetGUID
        trackedName = UnitName("target")
        Debug(strformat("Tracking started: %s (HUNTER, PvP)", trackedName))
      elseif alive == false then
        -- HP = 0, check if FD cast was detected
        if HasFeignDeathCast(targetGUID) then
          trackedGUID = targetGUID
          trackedName = UnitName("target")
          Debug(strformat("Tracking started: %s (HUNTER in FD - cast detected)", trackedName))
        else
          Debug("Target HP=0, no FD cast → really dead, not tracking")
          trackedGUID = nil
          trackedName = nil
        end
      end
    else
      trackedGUID = nil
      trackedName = nil
    end
  else
    -- Same tracked target
    local hp = GetUnitField and GetUnitField(trackedGUID, "health")

    if hp == 0 and HasFeignDeathCast(trackedGUID) then
      -- HP dropped to 0 but FD was cast - this is FD, not death
      -- Wait for target to disappear (handled in no-target block above)
      Debug("HP=0 with FD cast active, waiting for detarget")
    elseif hp and hp > 0 then
      -- Hunter stood up
      if HasFeignDeathCast(trackedGUID) then
        if not feignDeathStandUpTime[trackedGUID] then
          Debug("Hunter stood up, marking stand-up time")
          feignDeathStandUpTime[trackedGUID] = GetTime()
        end
        local timeSinceStandUp = GetTime() - feignDeathStandUpTime[trackedGUID]
        if timeSinceStandUp > FD_RECAST_WINDOW then
          Debug(strformat("Clearing FD flags after %.2fs stand-up", timeSinceStandUp))
          ClearFeignDeathCast(trackedGUID)
          lastDeathWasFD[trackedGUID] = nil
        end
      end
    end
  end
end

-- ===== EVENTS =====
GuidCollector:RegisterEvent("PLAYER_TARGET_CHANGED")
GuidCollector:RegisterEvent("PLAYER_ENTERING_WORLD")
GuidCollector:RegisterEvent("UNIT_CASTEVENT")

GuidCollector:SetScript("OnEvent", function()
  if event == "PLAYER_TARGET_CHANGED" then
    if UnitExists("target") then AddUnit("target") end
  elseif event == "PLAYER_ENTERING_WORLD" then
    Debug("Addon loaded.")
    AddUnit("player")
  elseif event == "UNIT_CASTEVENT" then
    local casterGUID, targetGUID, eventType, spellID = arg1, arg2, arg3, arg4
    if not FEIGN_DEATH_SPELL_IDS[spellID] then return end
    if eventType ~= "CAST" and eventType ~= "CHANNEL" then return end
    if trackedGUID and casterGUID == trackedGUID then
      MarkFeignDeathCast(casterGUID)
    end
  end
end)

TargetCheck:SetScript("OnUpdate", OnUpdateFrame)

-- ===== SLASH COMMANDS =====
SlashCmdList["RT"] = function(msg)
  if not msg or msg == "" or msg == "status" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff========== Retarget Status ==========|r")
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Nampower HP check:|r " .. (GetUnitField and "|cff00ff00ACTIVE|r" or "|cffff0000NOT AVAILABLE|r"))
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Nampower version:|r " .. (GetNampowerVersion and table.concat({GetNampowerVersion()}, ".") or "|cffff0000NOT FOUND|r"))
    local guidCount = 0
    for _ in pairs(GUIDCache) do guidCount = guidCount + 1 end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Cached GUIDs:|r " .. guidCount)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Stats:|r")
    DEFAULT_CHAT_FRAME:AddMessage("  GUIDs Collected: " .. Stats.guidsCollected)
    DEFAULT_CHAT_FRAME:AddMessage("  Retargets Attempted: " .. Stats.retargetsAttempted)
    DEFAULT_CHAT_FRAME:AddMessage("  Retargets Successful: " .. Stats.retargetsSuccessful)
    DEFAULT_CHAT_FRAME:AddMessage("  Feign Death Casts: " .. Stats.feignDeathCastsDetected)
    DEFAULT_CHAT_FRAME:AddMessage("  Real Deaths: " .. Stats.realDeathsDetected)
    if trackedGUID then
      local status = HasFeignDeathCast(trackedGUID) and " [FD ACTIVE]" or ""
      DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Tracking:|r " .. (trackedName or "?") .. " (HUNTER)" .. status)
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Tracking:|r None")
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff======================================|r")
  elseif msg == "debug" then
    debugMode = not debugMode
    DEFAULT_CHAT_FRAME:AddMessage(debugPrefix .. " Debug " .. (debugMode and "|cff00ff00ENABLED|r" or "|cffff0000DISABLED|r"))
  elseif msg == "clear" then
    GUIDCache = {} NameToGUID = {} trackedGUID = nil trackedName = nil
    feignDeathCastDetected = {} feignDeathStandUpTime = {} lastDeathWasFD = {}
    Stats.guidsCollected = 0 Stats.retargetsAttempted = 0 Stats.retargetsSuccessful = 0
    Stats.feignDeathCastsDetected = 0 Stats.realDeathsDetected = 0
    DEFAULT_CHAT_FRAME:AddMessage(debugPrefix .. " All data cleared!")
  elseif msg == "help" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff========== Retarget Commands ==========|r")
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/rt status|r - Show status")
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/rt debug|r - Toggle debug mode")
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/rt clear|r - Clear all data")
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/rt help|r - Show this help")
  else
    DEFAULT_CHAT_FRAME:AddMessage(debugPrefix .. " Unknown command. Use /rt help")
  end
end
SLASH_RT1 = "/rt"

-- ===== INIT =====
if GetUnitField and GetNampowerVersion then
  local a, b, c = GetNampowerVersion()
  DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff[Retarget]|r Loaded. Nampower v" .. a .. "." .. b .. "." .. c .. " detected.")
elseif GetUnitField then
  DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff[Retarget]|r Loaded. Nampower detected.")
else
  DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Retarget]|r WARNING: Nampower not found - addon will not function!")
end