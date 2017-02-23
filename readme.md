# LibPartyItemLevels-1.0

Performs inspection of raid, party, and target units, computes average item level,
and caches for future querying without additional inspect delays.

## Usage

    local libpil = LibStub:GetLibrary("LibPartyItemLevels-1.0", true)

    -- Define a callback to handle ItemLevelUpdated
    libpil.RegisterCallback(yourAddon, "ItemLevelUpdated")
    function yourAddon:ItemLevelUpdated(unit, level)

    end

    --[[
    Will fire off an inspect, which can take several seconds to resolve.
    This is an idempotent operation, you can call it multiple times safely.

    If an ilvl for a unit is already cached, GetItemLevel will return the cached
    value, but you shouldn't assume that it's always available.
    ]]--
    libpil:GetItemLevel("player")