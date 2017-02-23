assert(LibStub, "LibDataBroker-1.1 requires LibStub")
assert(LibStub:GetLibrary("CallbackHandler-1.0", true), "LibDataBroker-1.1 requires CallbackHandler-1.0")

local lib, oldminor = LibStub:NewLibrary("LibPartyItemLevels-1.0", 1)
lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)

local SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }
local MAIN_HAND = 16
local OFF_HAND = 17

local cache = {}
local inspectQueue = {}
local inspecting = false
local inspectingUnit, inspectingUnitGUID
local eventHandler = CreateFrame("Frame")
local lastNotifyInspect = 0

--[[
  We'll hook every inspect request so that we can profit even from the ones
  that we didn't initiate.
]]
hooksecurefunc("NotifyInspect", function(unit)
  lastNotifyInspect = GetTime()
  inspecting = true
  inspectingUnit = unit
  inspectingUnitGUID = UnitGUID(unit)

  -- back-to-front iteration so that we can remove during iteration
  for i = #inspectQueue, 1, -1 do
    if inspectingUnitGUID == inspectQueue[i].guid then
      table.remove(inspectQueue, i)
    end
  end
end)

--[[
  Get a cache key suitable for a given unit.
  Accepts:
    unit: Unit identifier
  Returns: String or nil if unable to derive a key
]]
local function getCacheKey(unit)
  if unit and UnitExists(unit) then
    return UnitGUID(unit)
  else
    return nil
  end
end

--[[
  Get the ilvl of an item in an item slot.
  Accepts:
    unit: unit identifier, must be player or the current inspect unit
    slot: The numeric slot identifier per http://wowwiki.wikia.com/wiki/InventorySlotId
  Returns:
    numeric item level, or nil if no item was available
]]
local function getItemSlotItemLevel(unit, slot)
  local link = GetInventoryItemLink(unit, slot)
  if link then
    local name, _, _, ilvl = GetItemInfo(link)
    return ilvl
  else
    return nil
  end
end


--[[
  Queue a unit for inspection. This doesn't actually fire off the inspect, but rather
  pushes the unit into a queue for inspection during the next available inspection window.
  Is idempotent; if a unit is already qeueued, it will not re-queue them. Additionally, it
  will fail to queue if the unit already has a cache entry that is less than 5m old.

  Accepts:
    unit: Unit identifier to inspect. Given the delayed nature of the lookup, this probably
          should never be a super-transient unit like `mouseover`.
  Returns:
    nil
]]
local function queueForInspect(unit)
  if not unit then return end

  -- Don't inspect any unit which has an existing cache key less than 5m old
  local e = cache[getCacheKey(unit) or "none"]
  if e and GetTime() - e.time < 600 then
    return
  end

  for _, u in ipairs(inspectQueue) do
    if UnitGUID(unit) == u.guid then
      return
    end
  end
  table.insert(inspectQueue, {unit = unit, guid = UnitGUID(unit)})
end

--[[
  Determine if we should continue to attempt to inspect the currently-inspecting unit. We have to
  re-inspect periodically because WoW returns partial information for an inspect, and it may take
  several seconds for full inspect data to show up.

  Accepts: None
  Returns: Boolean
]]
local function stillInspecting()
  local e = inspectingUnit and cache[getCacheKey(inspectingUnit)]
  return inspectingUnit and UnitGUID(inspectingUnit) == inspectingUnitGUID and e and e.items < 12
end

--[[
  Actually begin inspection of a unit if we are eligible to inspect them.
  Accepts:
    unit: Unit identifier
  Returns:
    Boolean indicating whether inspection was successful
]]
local function startInspect(unit)
  if CheckInteractDistance(unit, 1) and CanInspect(unit) then
    NotifyInspect(unit)
    return true
  end
  return false
end

--[[
  Shift the next unit off the queue and request inspection. If inspection fails, the unit is pushed back
  onto the queue.

  Accepts: None
  Returns: Boolean indicating whether a unit was inspected
]]
local function inspectNextUnit()
  local hasInspectUnit = (InspectFrame and (InspectFrame.unit or InspectFrame:IsShown()))
  if not (inspecting or UnitAffectingCombat("player") or #inspectQueue == 0 or hasInspectUnit) then
    local unit = table.remove(inspectQueue, 1)
    if UnitGUID(unit.unit) ~= unit.guid or not CanInspect(unit.unit) then
      -- The unit we queued is not what this unit is anymore. Just drop it.
      return false
    elseif startInspect(unit.unit) then
      return true
    else
      queueForInspect(unit.unit)
      return false
    end
  end
  return false
end

--[[
  Determines the average item level for the player or inspected unit.
  Accepts:
    unit: Unit identifier. Must be player or the unit currently being inspected.
  Returns:
    nil
  Fires:
    ItemLevelUpdated(unit, itemLevel)
]]
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
    local mh = getItemSlotItemLevel(unit, MAIN_HAND)
    local oh = getItemSlotItemLevel(unit, OFF_HAND)
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

--[[
  Event handling
]]
eventHandler:RegisterEvent("INSPECT_READY")
eventHandler:RegisterEvent("GROUP_ROSTER_UPDATE")
eventHandler:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventHandler:RegisterEvent("PLAYER_TARGET_CHANGED")
eventHandler:RegisterEvent("UNIT_INVENTORY_CHANGED")

-- Queue the target for inspection when our target changes
function eventHandler:PLAYER_TARGET_CHANGED()
  if CheckInteractDistance("target", 1) and CanInspect("target") then
    queueForInspect("target")
  end
end

-- Queue the player for inspection when the player changes equipment
function eventHandler:PLAYER_EQUIPMENT_CHANGED()
  updateItemLevelFor("player")
end

-- Queue the inspected unit for inspection when inventory changes
function eventHandler:UNIT_INVENTORY_CHANGED(unit)
  updateItemLevelFor(unit)
end

--[[
  Update item level for the inspected unit when inspection succeeds and the server
  has returned a response. It's worth noting that this doesn't actually indicate
  that full inspection data has been returned, just that SOME has. We'll use this to
  know when to start polling, but we'll continue to poll for inspection information
  until we heuristically believe that we've gotten it all.
]]
function eventHandler:INSPECT_READY(...)
  local u = inspectingUnit
  local guid = select(1, ...)
  if guid == UnitGUID(u) then
    updateItemLevelFor(u)
    inspecting = false
  end
end

--[[
  Queue all party or raid members for inspection when the group composition changes.
]]
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
  local THROTTLE = 0.25
  local INSPECT_THROTTLE = 3.0
  local lastReinspect = 0
  eventHandler:SetScript("OnUpdate", function()
    local t = GetTime()
    if t - lastReinspect > THROTTLE then
      lastReinspect = t
      if stillInspecting() then
        updateItemLevelFor(inspectingUnit)
      elseif t - lastNotifyInspect > INSPECT_THROTTLE then
        inspectNextUnit()
      end
    end
  end)
end

--[[
  Public API
]]

--[[
  Fetch the item level for a given unit. This will immediately return the item level
  if a value is already cached, but in many cases, will return -1 as we don't have an
  item level for them yet. In that case, consuming applications should register for the
  ItemLevelUpdated(unit, itemLevel) event on the library.

  Accepts:
    unit: unit identifier
  Returns:
    - numeric item level if a cached value is present
    - -1 if the unit is valid, but no cached value is present
    - nil if the unit is not valid
]]
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