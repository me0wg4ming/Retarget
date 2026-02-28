--[[
Retarget (Nampower - Hunter Only)
- UNIT_DIED fires on real death, NOT on Feign Death → perfect detection
- SPELL_GO_OTHER for FD cast detection (server-confirmed, requires NP_EnableSpellGoEvents=1)
- No tooltip scan, no HP polling needed
- Requires Nampower 3.0.0+
]]

-- ===== CACHE =====
local strformat = string.format
local GetTime = GetTime
local UnitExists = UnitExists
local UnitIsPlayer = UnitIsPlayer
local UnitName = UnitName
local UnitClass = UnitClass
local UnitPlayerControlled = UnitPlayerControlled

-- ===== GLOBALS =====
local debugPrefix = "|cff9966ff[Retarget]|r"
local GuidCollector = CreateFrame("Frame")

local trackedGUID = nil
local trackedName = nil

local feignDeathCastDetected = {}  -- guid -> timestamp
local FEIGN_DEATH_CLEANUP_WINDOW = 5.0

local lastDebugMessage = ""
local lastDebugTime = 0
local debugMode = false

local GUIDCache = {}

local Stats = {
  retargetsAttempted      = 0,
  retargetsSuccessful     = 0,
  guidsCollected          = 0,
  feignDeathCastsDetected = 0,
  realDeathsDetected      = 0,
}

local FEIGN_DEATH_SPELL_IDS = {
  [5384] = true,  -- Feign Death Rank 1
  [5385] = true,  -- Feign Death Rank 2
}

-- ===== UTILITIES =====
local function Debug(msg)
  if not debugMode then return end
  local now = GetTime()
  if msg ~= lastDebugMessage or (now - lastDebugTime) > 1 then
    DEFAULT_CHAT_FRAME:AddMessage(debugPrefix .. " " .. msg)
    lastDebugMessage = msg
    lastDebugTime = now
  end
end

-- ===== GUID COLLECTION =====
local function AddUnit(unit)
  local _, guid = UnitExists(unit)
  if not guid then return end
  if not UnitIsPlayer(guid) then return end

  local _, classToken = UnitClass(guid)
  if classToken ~= "HUNTER" then return end
  if not UnitCanAttack("player", guid) then return end
  if not UnitIsPVP(guid) then return end

  local name = UnitName(guid)
  if not name then return end

  if not GUIDCache[guid] then
    Stats.guidsCollected = Stats.guidsCollected + 1
    Debug(strformat("GUID collected: %s (HUNTER, PvP)", name))
  end
  GUIDCache[guid] = { name = name, time = GetTime() }
end

-- ===== RETARGET =====
local function TryReTarget()
  if not trackedGUID then return false end
  Stats.retargetsAttempted = Stats.retargetsAttempted + 1
  Debug(strformat("Trying re-target: %s [%s]", trackedName or "?", trackedGUID))
  TargetUnit(trackedGUID)
  local _, afterGUID = UnitExists("target")
  if afterGUID == trackedGUID then
    Stats.retargetsSuccessful = Stats.retargetsSuccessful + 1
    Debug("|cff00ff00Re-target successful!|r")
    return true
  end
  Debug("Re-target failed.")
  return false
end

-- ===== CLEANUP =====
local cleanupTimer = 0
local cleanupFrame = CreateFrame("Frame")
cleanupFrame:SetScript("OnUpdate", function()
  cleanupTimer = cleanupTimer + (arg1 or 0.01)
  if cleanupTimer < 30 then return end
  cleanupTimer = 0
  local now = GetTime()
  for guid in pairs(GUIDCache) do
    if not UnitExists(guid) then GUIDCache[guid] = nil end
  end
  for guid, castTime in pairs(feignDeathCastDetected) do
    if (now - castTime) > FEIGN_DEATH_CLEANUP_WINDOW then
      feignDeathCastDetected[guid] = nil
    end
  end
end)

-- ===== EVENTS =====
GuidCollector:RegisterEvent("PLAYER_TARGET_CHANGED")
GuidCollector:RegisterEvent("PLAYER_ENTERING_WORLD")
GuidCollector:RegisterEvent("SPELL_GO_OTHER")
GuidCollector:RegisterEvent("UNIT_DIED")

GuidCollector:SetScript("OnEvent", function()

  if event == "PLAYER_TARGET_CHANGED" then
    if UnitExists("target") then
      AddUnit("target")
      local _, guid = UnitExists("target")
      if guid and guid ~= trackedGUID then
        local _, classToken = UnitClass("target")
        if classToken == "HUNTER" and UnitCanAttack("player", "target") and UnitIsPVP("target") then
          if trackedGUID then feignDeathCastDetected[trackedGUID] = nil end
          -- Skip if already dead (HP = 0 and no FD cast detected)
          local hp = GetUnitField and GetUnitField(guid, "health")
          if hp == 0 and not feignDeathCastDetected[guid] then
            Debug("Target HP=0, no FD cast → already dead, not tracking")
            trackedGUID = nil
            trackedName = nil
          else
            trackedGUID = guid
            trackedName = UnitName("target")
            Debug(strformat("Tracking: %s", trackedName))
          end
        else
          if trackedGUID then feignDeathCastDetected[trackedGUID] = nil end
          trackedGUID = nil
          trackedName = nil
        end
      end
    else
      -- Target lost - FD cast detected = retarget
      if trackedGUID and feignDeathCastDetected[trackedGUID] then
        Debug("|cffff0000FD cast detected → retargeting!|r")
        feignDeathCastDetected[trackedGUID] = nil
        TryReTarget()
      end
    end

  elseif event == "PLAYER_ENTERING_WORLD" then
    AddUnit("player")

  elseif event == "SPELL_GO_OTHER" then
    -- arg1=itemId, arg2=spellId, arg3=casterGuid
    local spellID = arg2
    local casterGUID = arg3
    if not FEIGN_DEATH_SPELL_IDS[spellID] then return end
    if casterGUID ~= trackedGUID then return end

    local now = GetTime()
    local prev = feignDeathCastDetected[casterGUID]
    feignDeathCastDetected[casterGUID] = now
    Stats.feignDeathCastsDetected = Stats.feignDeathCastsDetected + 1

    if prev then
      Debug(strformat("|cffff0000FD CAST!|r %s (%.2fs since last)", trackedName or "?", now - prev))
    else
      Debug(strformat("|cffff0000FD CAST!|r %s", trackedName or "?"))
    end

  -- UNIT_DIED fires on real death, NOT on Feign Death
  elseif event == "UNIT_DIED" then
    local guid = arg1
    if guid ~= trackedGUID then return end
    Debug("|cffff0000UNIT_DIED → REAL DEATH, stop tracking|r")
    Stats.realDeathsDetected = Stats.realDeathsDetected + 1
    feignDeathCastDetected[guid] = nil
    trackedGUID = nil
    trackedName = nil
  end
end)

-- ===== SLASH COMMANDS =====
SlashCmdList["RT"] = function(msg)
  if not msg or msg == "" or msg == "status" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff========== Retarget Status ==========|r")
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Nampower:|r " .. (GetNampowerVersion and table.concat({GetNampowerVersion()}, ".") or "|cffff0000NOT FOUND|r"))
    local guidCount = 0
    for _ in pairs(GUIDCache) do guidCount = guidCount + 1 end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Cached GUIDs:|r " .. guidCount)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Stats:|r")
    DEFAULT_CHAT_FRAME:AddMessage("  GUIDs Collected: "         .. Stats.guidsCollected)
    DEFAULT_CHAT_FRAME:AddMessage("  Retargets Attempted: "     .. Stats.retargetsAttempted)
    DEFAULT_CHAT_FRAME:AddMessage("  Retargets Successful: "    .. Stats.retargetsSuccessful)
    DEFAULT_CHAT_FRAME:AddMessage("  Feign Death Casts: "       .. Stats.feignDeathCastsDetected)
    DEFAULT_CHAT_FRAME:AddMessage("  Real Deaths: "             .. Stats.realDeathsDetected)
    if trackedGUID then
      local fdStatus = feignDeathCastDetected[trackedGUID] and " [FD ACTIVE]" or ""
      DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Tracking:|r " .. (trackedName or "?") .. " (HUNTER)" .. fdStatus)
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Tracking:|r None")
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff======================================|r")

  elseif msg == "debug" then
    debugMode = not debugMode
    DEFAULT_CHAT_FRAME:AddMessage(debugPrefix .. " Debug " .. (debugMode and "|cff00ff00ENABLED|r" or "|cffff0000DISABLED|r"))

  elseif msg == "clear" then
    GUIDCache = {}
    trackedGUID = nil
    trackedName = nil
    feignDeathCastDetected = {}
    Stats.guidsCollected = 0
    Stats.retargetsAttempted = 0
    Stats.retargetsSuccessful = 0
    Stats.feignDeathCastsDetected = 0
    Stats.realDeathsDetected = 0
    DEFAULT_CHAT_FRAME:AddMessage(debugPrefix .. " All data cleared!")

  elseif msg == "help" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff========== Retarget Commands ==========|r")
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/rt status|r - Show status")
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/rt debug|r  - Toggle debug mode")
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/rt clear|r  - Clear all data")
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/rt help|r   - Show this help")
  else
    DEFAULT_CHAT_FRAME:AddMessage(debugPrefix .. " Unknown command. Use /rt help")
  end
end
SLASH_RT1 = "/rt"

-- ===== INIT =====
if GetNampowerVersion then
  local a, b, c = GetNampowerVersion()
  DEFAULT_CHAT_FRAME:AddMessage(strformat("|cff9966ff[Retarget]|r Loaded. Nampower v%d.%d.%d", a, b, c))
  if GetCVar("NP_EnableSpellGoEvents") ~= "1" then
    SetCVar("NP_EnableSpellGoEvents", "1")
    DEFAULT_CHAT_FRAME:AddMessage("|cff9966ff[Retarget]|r NP_EnableSpellGoEvents enabled.")
  end
else
  DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Retarget]|r WARNING: Nampower not found!")
end