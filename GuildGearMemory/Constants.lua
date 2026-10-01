local _, GGM = ...

GGM.SCHEMA_VERSION = 5
GGM.DEFAULT_STABILITY_DELAY_SECONDS = 300

GGM.PROFESSION_MAX_RECIPES = 4096
GGM.PROFESSION_MAX_NAME_BYTES = 128
GGM.PROFESSION_SOURCE_GUILD_LINK = "guild-profession-link"
GGM.PROFESSION_SOURCE_PLAYER = "player"
GGM.PROFESSION_CACHE_STATUS = "cached"
GGM.PROFESSION_RECIPE_INDEX_VERSION = 3

GGM.SYNC_PROTOCOL_VERSION = 5
GGM.SYNC_PREFIX = "DysGuildGear"
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
    { key = "HEAD", inventoryName = "HeadSlot" },
    { key = "NECK", inventoryName = "NeckSlot" },
    { key = "SHOULDER", inventoryName = "ShoulderSlot" },
    { key = "BACK", inventoryName = "BackSlot" },
    { key = "CHEST", inventoryName = "ChestSlot" },
    { key = "SHIRT", inventoryName = "ShirtSlot" },
    { key = "TABARD", inventoryName = "TabardSlot" },
    { key = "WRIST", inventoryName = "WristSlot" },
    { key = "HANDS", inventoryName = "HandsSlot" },
    { key = "WAIST", inventoryName = "WaistSlot" },
    { key = "LEGS", inventoryName = "LegsSlot" },
    { key = "FEET", inventoryName = "FeetSlot" },
    { key = "FINGER_1", inventoryName = "Finger0Slot" },
    { key = "FINGER_2", inventoryName = "Finger1Slot" },
    { key = "TRINKET_1", inventoryName = "Trinket0Slot" },
    { key = "TRINKET_2", inventoryName = "Trinket1Slot" },
    { key = "MAIN_HAND", inventoryName = "MainHandSlot" },
    { key = "OFF_HAND", inventoryName = "SecondaryHandSlot" },
    { key = "RANGED", inventoryName = "RangedSlot" },
}

-- Some WoW variants expose a ranged equipment slot and others do not. Keep it
-- available when the client provides it, but do not require it for a snapshot.
GGM.OPTIONAL_TRACKED_SLOTS = {
    RANGED = true,
}
