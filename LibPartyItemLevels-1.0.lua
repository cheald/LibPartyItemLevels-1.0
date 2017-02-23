assert(LibStub, "LibDataBroker-1.1 requires LibStub")
assert(LibStub:GetLibrary("CallbackHandler-1.0", true), "LibDataBroker-1.1 requires CallbackHandler-1.0")

local lib, oldminor = LibStub:NewLibrary("LibPartyItemLevels-1.0", 1)
lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)

local cache = {}
local inspectQueue = {}
local eventHandler = CreateFrame("Frame")
local SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }
local inspecting = false
local inspectingUnit, inspectingUnitGUID

hooksecurefunc("NotifyInspect", function(unit)
  inspecting = true
  inspectingUnit = unit
  inspectingUnitGUID = UnitGUID(unit)

  -- back-to-front iteration so that we can remove during iteration
  for i = #inspectQueue, 1, -1 do
    if UnitIsUnit(inspectQueue[i], unit) then
      table.remove(inspectQueue, i)
    end
  end
end)

local function getCacheKey(unit)
  if unit and UnitExists(unit) then
    return UnitGUID(unit)
  else
    return nil
  end
end

local function getItemSlotItemLevel(unit, slot)
  local link = GetInventoryItemLink(unit, slot)
  if link then
    local name, _, _, ilvl = GetItemInfo(link)
    return ilvl
  else
    return nil
  end
end

local function queueForInspect(unit)
  if not unit then return end

  -- Don't inspect any unit which has an existing cache key less than 5m old
  local e = cache[getCacheKey(unit) or "none"]
  if e and GetTime() - e.time < 600 then
    return
  end

  for _, u in ipairs(inspectQueue) do
    if UnitIsUnit(u, unit) then
      return
    end
  end
  table.insert(inspectQueue, unit)
end

local function stillInspecting()
  local e = inspectingUnit and cache[getCacheKey(inspectingUnit)]
  return inspectingUnit and UnitGUID(inspectingUnit) == inspectingUnitGUID and e and e.items < 12
end

local function startInspect(unit)
  if CheckInteractDistance(unit, 1) and CanInspect(unit) then
    NotifyInspect(unit)
    return true
  end
  return false
end

local function inspectNextUnit()
  local hasInspectUnit = (InspectFrame and (InspectFrame.unit or InspectFrame:IsShown()))
  if not (inspecting or UnitAffectingCombat("player") or #inspectQueue == 0 or hasInspectUnit) then
    local unit = table.remove(inspectQueue, 1)
    if startInspect(unit) then
      return true
    else
      queueForInspect(unit)
      return false
    end
  end
  return false
end

local function updateItemLevelFor(unit)
  local items = 0
  local total = 0
  local key = getCacheKey(unit)
  if UnitIsUnit(unit, "player") then
    local _, ilvl, _ = GetAverageItemLevel()
    items = 99
    total = ilvl * items
  else
    if not key then return end
    for _, slot in ipairs(SLOTS) do
      local ilvl = getItemSlotItemLevel(unit, slot)
      if ilvl then
        total = total + ilvl
        items = items + 1
      end
    end
    -- We only use the highest ilvl weapon slot, since off-slot weapons are 750
    local mh = getItemSlotItemLevel(unit, 16)
    local oh = getItemSlotItemLevel(unit, 17)
    local weapon = (mh and not oh and mh) or (oh and not mh and oh) or (mh and oh and mh > oh and mh or oh)
    if weapon then
      total = total + weapon
      items = items + 1
      if mh and oh then
        total = total + weapon
        items = items + 1
      end
    end
  end

  if not cache[key] or cache[key].items <= items then
    cache[key] = {
      total = total,
      items = items,
      ilvl = total / items,
      time = GetTime()
    }
    lib.callbacks:Fire("ItemLevelUpdated", unit, cache[key].ilvl)
  end
end

eventHandler:RegisterEvent("INSPECT_READY")
eventHandler:RegisterEvent("GROUP_ROSTER_UPDATE")
eventHandler:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventHandler:RegisterEvent("PLAYER_TARGET_CHANGED")
eventHandler:RegisterEvent("UNIT_INVENTORY_CHANGED")

function eventHandler:PLAYER_TARGET_CHANGED()
  if CheckInteractDistance("target", 1) and CanInspect("target") then
    queueForInspect("target")
  end
end

function eventHandler:PLAYER_EQUIPMENT_CHANGED()
  updateItemLevelFor("player")
end

function eventHandler:UNIT_INVENTORY_CHANGED(unit)
  updateItemLevelFor(unit)
end

function eventHandler:INSPECT_READY(...)
  local u = inspectingUnit
  local guid = select(1, ...)
  if guid == UnitGUID(u) then
    if u == "mouseover" then return end
    updateItemLevelFor(u)
    inspecting = false
  end
end

function eventHandler:GROUP_ROSTER_UPDATE(self, ...)
  local prefix = IsInRaid() and "raid" or "party"
  local rnum = GetNumGroupMembers()
  for i = 1, rnum do
    local unit = prefix .. i
    if not cache[getCacheKey(unit) or "none"] then
      queueForInspect(unit)
    end
  end
end

eventHandler:SetScript("OnEvent", function(self, event, ...)
  eventHandler[event](self, ...)
end)

do
  local lastReinspect = 0
  eventHandler:SetScript("OnUpdate", function()
    local t = GetTime()
    if t - lastReinspect > 1 then
      lastReinspect = t
      if stillInspecting() then
        updateItemLevelFor(inspectingUnit)
      else
        inspectNextUnit()
      end
    end
  end)
end

function lib:GetItemLevel(unit)
  local key = getCacheKey(unit)
  if key then
    queueForInspect(unit)
    if cache[key] then
      return cache[key].ilvl
    else
      return -1
    end
  end
end