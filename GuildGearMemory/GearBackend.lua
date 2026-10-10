local _, GGM = ...

-- This adapter exposes backend helpers to the existing presentation code.
-- Runtime state and all gear operations remain owned by DysgearMemory.
-- The empty browser still needs its paper-doll layout when the backend is
-- disabled. These are presentation positions, never a capture/sync fallback.
GGM.TRACKED_SLOTS = {
    { key = "HEAD", inventoryName = "HeadSlot", inventorySlotID = 1 }, { key = "NECK", inventoryName = "NeckSlot", inventorySlotID = 2 },
    { key = "SHOULDER", inventoryName = "ShoulderSlot", inventorySlotID = 3 }, { key = "BACK", inventoryName = "BackSlot", inventorySlotID = 15 },
    { key = "CHEST", inventoryName = "ChestSlot", inventorySlotID = 5 }, { key = "SHIRT", inventoryName = "ShirtSlot", inventorySlotID = 4 },
    { key = "TABARD", inventoryName = "TabardSlot", inventorySlotID = 19 }, { key = "WRIST", inventoryName = "WristSlot", inventorySlotID = 9 },
    { key = "HANDS", inventoryName = "HandsSlot", inventorySlotID = 10 }, { key = "WAIST", inventoryName = "WaistSlot", inventorySlotID = 6 },
    { key = "LEGS", inventoryName = "LegsSlot", inventorySlotID = 7 }, { key = "FEET", inventoryName = "FeetSlot", inventorySlotID = 8 },
    { key = "FINGER_1", inventoryName = "Finger0Slot", inventorySlotID = 11 }, { key = "FINGER_2", inventoryName = "Finger1Slot", inventorySlotID = 12 },
    { key = "TRINKET_1", inventoryName = "Trinket0Slot", inventorySlotID = 13 }, { key = "TRINKET_2", inventoryName = "Trinket1Slot", inventorySlotID = 14 },
    { key = "MAIN_HAND", inventoryName = "MainHandSlot", inventorySlotID = 16 }, { key = "OFF_HAND", inventoryName = "SecondaryHandSlot", inventorySlotID = 17 },
    { key = "RANGED", inventoryName = "RangedSlot", inventorySlotID = 18 },
}
GGM.SYNC_PREFIX = "GC_GEAR"
GGM.GetCharacterRecord = function() return nil, "database-invalid" end
GGM.IsLocalCharacter = function() return false end

function GGM.RefreshGearBackendState()
    local backend = GGM.gearBackend
    GGM.guildSync = backend and backend.guildSync or nil
    GGM.gearTracker = backend and backend.gearTracker or nil
    GGM.lastSyncError = backend and backend.lastSyncError or GGM.gearStartupError
    GGM.lastSyncReceiveError = backend and backend.lastSyncReceiveError or nil
    GGM.lastGearTrackingError = backend and backend.lastGearTrackingError or GGM.gearStartupError
    GGM.lastCaptureError = backend and backend.lastCaptureError or nil
end

local companion = _G.DysgearMemoryAPI
if type(companion) == "table" and companion.schemaVersion == 2 and type(companion.GetBackend) == "function" then
    local ok, backend = pcall(companion.GetBackend)
    if ok and type(backend) == "table" then
        GGM.gearBackend = backend
        for key, value in pairs(backend) do
            if key ~= "BuildPlayerIdentity" and (type(value) == "function" or key:match("^[A-Z_]+$")) then
                GGM[key] = value
            end
        end
    end
end

_G.GuildGearMemoryGearChanged = GGM.RefreshGearBackendState
GGM.RefreshGearBackendState()
