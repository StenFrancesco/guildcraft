local _, GGM = ...

GGM.SCHEMA_VERSION = 7
GGM.DEFAULT_STABILITY_DELAY_SECONDS = 300
GGM.GEAR_MAX_ITEM_STRING_BYTES = 320
GGM.GEAR_MAX_ITEM_ID = 2147483647

GGM.SYNC_PROTOCOL_VERSION = 5
GGM.SYNC_PREFIX = "GC_GEAR"
GGM.SYNC_CHAT_TYPE = "GUILD"

GGM.SYNC_MAX_ADDON_MESSAGE_BYTES = 255
GGM.SYNC_FRAME_CHUNK_BYTES = 230
GGM.SYNC_MAX_FRAME_COUNT = 32
GGM.SYNC_MAX_LOGICAL_BYTES = GGM.SYNC_FRAME_CHUNK_BYTES * GGM.SYNC_MAX_FRAME_COUNT
GGM.SYNC_SEND_INTERVAL_SECONDS = 1.05
GGM.SYNC_SNAPSHOT_RESPONSE_DELAY_STEP_SECONDS = 0.25
GGM.SYNC_SNAPSHOT_RESPONSE_DELAY_BUCKETS = 8
GGM.SYNC_SNAPSHOT_RESPONSE_MAX_DELAY_SECONDS = GGM.SYNC_SNAPSHOT_RESPONSE_DELAY_STEP_SECONDS
    * GGM.SYNC_SNAPSHOT_RESPONSE_DELAY_BUCKETS
-- Keep the election open for the full range of possible response-claim delays.
GGM.SYNC_SNAPSHOT_RESPONSE_OFFER_SETTLE_SECONDS = GGM.SYNC_SNAPSHOT_RESPONSE_MAX_DELAY_SECONDS
    + GGM.SYNC_SEND_INTERVAL_SECONDS
GGM.SYNC_REASSEMBLY_TTL_SECONDS = 90
GGM.SYNC_MAX_INBOUND_ASSEMBLIES = 32
GGM.SYNC_MAX_OUTBOUND_FRAMES = 64
GGM.SYNC_SNAPSHOT_RESPONSE_COOLDOWN_SECONDS = 60
GGM.SYNC_MAX_SNAPSHOT_RESPONSE_COOLDOWN_ENTRIES = 64
GGM.SYNC_MAX_PENDING_SNAPSHOT_RESPONSES = 16
-- Keep a request live through bounded request, claim, and snapshot queue
-- phases, including the one-frame request and claim and maximum-size snapshot.
GGM.SYNC_SNAPSHOT_REQUEST_TTL_SECONDS = GGM.SYNC_SNAPSHOT_RESPONSE_MAX_DELAY_SECONDS
    + GGM.SYNC_SNAPSHOT_RESPONSE_OFFER_SETTLE_SECONDS
    + (3 * GGM.SYNC_MAX_OUTBOUND_FRAMES + GGM.SYNC_MAX_FRAME_COUNT + 2) * GGM.SYNC_SEND_INTERVAL_SECONDS
GGM.SYNC_SNAPSHOT_REQUEST_COOLDOWN_SECONDS = 5
GGM.SYNC_MAX_SNAPSHOT_REQUEST_COOLDOWN_ENTRIES = 64
GGM.SYNC_MAX_PENDING_SNAPSHOT_REQUESTS = 16

GGM.SYNC_MAX_IDENTITY_KEY_BYTES = 80
GGM.SYNC_MAX_NAME_BYTES = 32
GGM.SYNC_MAX_REALM_BYTES = 32
GGM.SYNC_MAX_GUID_BYTES = 64
GGM.SYNC_MAX_SLOT_KEY_BYTES = 16
GGM.SYNC_MAX_ITEM_LINK_BYTES = 320
GGM.SYNC_MAX_CONFIRMED_SEQUENCE = 2147483647
GGM.SYNC_MAX_TIMESTAMP = 4294967295
GGM.SYNC_MAX_RACE_ID = 255
GGM.SYNC_MAX_DISPLAY_ID = 2147483647

GGM.TRACKED_SLOTS = {
    { key = "HEAD", inventoryName = "HeadSlot", inventorySlotID = 1 },
    { key = "NECK", inventoryName = "NeckSlot", inventorySlotID = 2 },
    { key = "SHOULDER", inventoryName = "ShoulderSlot", inventorySlotID = 3 },
    { key = "BACK", inventoryName = "BackSlot", inventorySlotID = 15 },
    { key = "CHEST", inventoryName = "ChestSlot", inventorySlotID = 5 },
    { key = "SHIRT", inventoryName = "ShirtSlot", inventorySlotID = 4 },
    { key = "TABARD", inventoryName = "TabardSlot", inventorySlotID = 19 },
    { key = "WRIST", inventoryName = "WristSlot", inventorySlotID = 9 },
    { key = "HANDS", inventoryName = "HandsSlot", inventorySlotID = 10 },
    { key = "WAIST", inventoryName = "WaistSlot", inventorySlotID = 6 },
    { key = "LEGS", inventoryName = "LegsSlot", inventorySlotID = 7 },
    { key = "FEET", inventoryName = "FeetSlot", inventorySlotID = 8 },
    { key = "FINGER_1", inventoryName = "Finger0Slot", inventorySlotID = 11 },
    { key = "FINGER_2", inventoryName = "Finger1Slot", inventorySlotID = 12 },
    { key = "TRINKET_1", inventoryName = "Trinket0Slot", inventorySlotID = 13 },
    { key = "TRINKET_2", inventoryName = "Trinket1Slot", inventorySlotID = 14 },
    { key = "MAIN_HAND", inventoryName = "MainHandSlot", inventorySlotID = 16 },
    { key = "OFF_HAND", inventoryName = "SecondaryHandSlot", inventorySlotID = 17 },
    { key = "RANGED", inventoryName = "RangedSlot", inventorySlotID = 18 },
}

-- Some WoW variants expose a ranged equipment slot and others do not. Keep it
-- available when the client provides it, but do not require it for a snapshot.
GGM.OPTIONAL_TRACKED_SLOTS = {
    RANGED = true,
}
