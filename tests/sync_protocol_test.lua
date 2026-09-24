local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/SyncProtocol.lua", GGM)
    return GGM
end

local function makeIdentity(name, realm, guid)
    return { key = name .. "-" .. realm, name = name, realm = realm, guid = guid }
end

local function makeSnapshot(GGM)
    local snapshot = { complete = true, capturedAt = 1700001000, slots = {} }
    for index, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        snapshot.slots[trackedSlot.key] = {
            inventorySlotID = index,
            itemID = 5000 + index,
            itemLink = "|Hitem:" .. tostring(5000 + index) .. ":0:0|h[Test:" .. trackedSlot.key .. "]|h",
        }
    end
    snapshot.slots.OFF_HAND.itemID = false
    snapshot.slots.OFF_HAND.itemLink = false
    return snapshot
end

T.test("slot update protocol round trips explicit bounded fields", function()
    local GGM = loadModules()
    local identity = makeIdentity("Alice", "Silvermoon", "Player-1234-AAAA")
    local slotValue = { inventorySlotID = 1, itemID = 9001, itemLink = "|Hitem:9001:1:2:3|h[Colon: Pipe | Value]|h" }
    local payload, encodeErr = GGM.EncodeSyncSlotUpdate(identity, 4, "HEAD", slotValue, 1700001200)
    T.assertNil(encodeErr)
    T.assertNotNil(payload)
    local message, decodeErr = GGM.DecodeSyncMessage(payload)
    T.assertNil(decodeErr)
    T.assertEqual(message.type, "SLOT_UPDATE")
    T.assertEqual(message.identity.key, identity.key)
    T.assertEqual(message.confirmedSequence, 4)
    T.assertEqual(message.slotKey, "HEAD")
    T.assertEqual(message.slotValue.inventorySlotID, 1)
    T.assertEqual(message.slotValue.itemID, 9001)
    T.assertEqual(message.slotValue.itemLink, slotValue.itemLink)
    T.assertEqual(message.confirmedAt, 1700001200)
end)

T.test("snapshot request protocol round trips requester and exactly one target", function()
    local GGM = loadModules()
    local requester = makeIdentity("Bob", "Silvermoon", "Player-1234-BBBB")
    local target = makeIdentity("Alice", "Silvermoon", nil)
    local payload = assert(GGM.EncodeSyncSnapshotRequest(requester, target, "000001"))
    local message, err = GGM.DecodeSyncMessage(payload)
    T.assertNil(err)
    T.assertEqual(message.type, "SNAPSHOT_REQUEST")
    T.assertEqual(message.requester.key, requester.key)
    T.assertEqual(message.target.key, target.key)
    T.assertNil(message.target.guid)
    T.assertEqual(message.requestID, "000001")
end)

T.test("snapshot response claim protocol round trips the election identities", function()
    local GGM = loadModules()
    local requester = makeIdentity("Bob", "Silvermoon", "Player-1234-BBBB")
    local target = makeIdentity("Alice", "Silvermoon", "Player-1234-AAAA")
    local responder = makeIdentity("Carol", "Silvermoon", "Player-1234-CCCC")
    local payload = assert(GGM.EncodeSyncSnapshotResponseClaim(target, requester, responder, 7, "000001"))
    T.assertTrue(#payload <= GGM.SYNC_FRAME_CHUNK_BYTES)
    local message, err = GGM.DecodeSyncMessage(payload)
    T.assertNil(err)
    T.assertEqual(message.type, "SNAPSHOT_RESPONSE_CLAIM")
    T.assertEqual(message.target.key, target.key)
    T.assertEqual(message.requester.key, requester.key)
    T.assertEqual(message.responder.key, responder.key)
    T.assertEqual(message.confirmedSequence, 7)
    T.assertEqual(message.requestID, "000001")
end)

T.test("complete snapshot response round trips every tracked slot and sequence", function()
    local GGM = loadModules()
    local requester = makeIdentity("Bob", "Silvermoon", "Player-1234-BBBB")
    local target = makeIdentity("Alice", "Silvermoon", "Player-1234-AAAA")
    local payload = assert(GGM.EncodeSyncSnapshotResponse(target, requester, makeIdentity("Carol", "Silvermoon", "Player-1234-CCCC"), makeSnapshot(GGM), 12, "000001"))
    local message, err = GGM.DecodeSyncMessage(payload)
    T.assertNil(err)
    T.assertEqual(message.type, "SNAPSHOT_RESPONSE")
    T.assertEqual(message.target.key, target.key)
    T.assertEqual(message.requester.key, requester.key)
    T.assertEqual(message.responder.key, "Carol-Silvermoon")
    T.assertEqual(message.requestID, "000001")
    T.assertEqual(message.confirmedSequence, 12)
    T.assertEqual(message.snapshot.capturedAt, 1700001000)
    T.assertEqual(message.snapshot.slots.HEAD.itemID, 5001)
    T.assertEqual(message.snapshot.slots.OFF_HAND.itemID, false)
    T.assertEqual(message.snapshot.slots.OFF_HAND.itemLink, false)
end)

T.test("protocol rejects identity keys that do not match name and realm", function()
    local GGM = loadModules()
    local identity = makeIdentity("Alice", "Silvermoon", "Player-1234-AAAA")
    identity.key = "Mallory-Silvermoon"
    local payload, err = GGM.EncodeSyncSnapshotRequest(identity, makeIdentity("Bob", "Silvermoon", nil), "000001")
    T.assertNil(payload)
    T.assertEqual(err, "sync-identity-key-mismatch")
end)

T.test("protocol rejects oversized item links before transport", function()
    local GGM = loadModules()
    local identity = makeIdentity("Alice", "Silvermoon", "Player-1234-AAAA")
    local slotValue = { inventorySlotID = 1, itemID = 9001, itemLink = string.rep("x", GGM.SYNC_MAX_ITEM_LINK_BYTES + 1) }
    local payload, err = GGM.EncodeSyncSlotUpdate(identity, 1, "HEAD", slotValue, 1700001200)
    T.assertNil(payload)
    T.assertEqual(err, "sync-item-link-too-long")
end)

T.test("protocol rejects unsupported versions and unknown message types", function()
    local GGM = loadModules()
    local versionMessage, versionErr = GGM.DecodeSyncMessage("9U")
    T.assertNil(versionMessage)
    T.assertEqual(versionErr, "sync-protocol-version-unsupported")
    local typeMessage, typeErr = GGM.DecodeSyncMessage("1X")
    T.assertNil(typeMessage)
    T.assertEqual(typeErr, "sync-message-type-unknown")
end)

T.test("protocol rejects malformed length prefixes and trailing data", function()
    local GGM = loadModules()
    local malformed, malformedErr = GGM.DecodeSyncMessage("1Qx:abc")
    T.assertNil(malformed)
    T.assertEqual(malformedErr, "sync-field-length-invalid")
    local valid = assert(GGM.EncodeSyncSnapshotRequest(makeIdentity("Bob", "Silvermoon", "Player-1234-BBBB"), makeIdentity("Alice", "Silvermoon", nil), "000001"))
    local trailing, trailingErr = GGM.DecodeSyncMessage(valid .. "junk")
    T.assertNil(trailing)
    T.assertEqual(trailingErr, "sync-payload-trailing-data")
end)

T.test("protocol rejects logical payloads above the configured bound", function()
    local GGM = loadModules()
    local message, err = GGM.DecodeSyncMessage(string.rep("x", GGM.SYNC_MAX_LOGICAL_BYTES + 1))
    T.assertNil(message)
    T.assertEqual(err, "sync-payload-too-large")
end)
