local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("DysgearMemory/Constants.lua", GGM)
    T.loadAddonFile("DysgearMemory/GearData.lua", GGM)
    T.loadAddonFile("DysgearMemory/GearSnapshot.lua", GGM)
    T.loadAddonFile("DysgearMemory/SyncProtocol.lua", GGM)
    return GGM
end

local function makeIdentity(name, realm, guid)
    return { key = name .. "-" .. realm, name = name, realm = realm, guid = guid }
end

local function makeSnapshot(GGM)
    local snapshot = { complete = true, capturedAt = 1700001000, slots = {} }
    for index, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        snapshot.slots[trackedSlot.key] = {
            inventorySlotID = trackedSlot.inventorySlotID,
            itemID = 5000 + index,
            itemLink = "|Hitem:" .. tostring(5000 + index) .. ":0:0|h[Test:" .. trackedSlot.key .. "]|h",
        }
    end
    snapshot.slots.OFF_HAND.itemID = false
    snapshot.slots.OFF_HAND.itemLink = false
    return snapshot
end

local function parseFields(payload)
    local fields, cursor = {}, 3
    while cursor <= #payload do
        local colon = assert(payload:find(":", cursor, true))
        local length = tonumber(payload:sub(cursor, colon - 1))
        local first = colon + 1
        fields[#fields + 1] = payload:sub(first, first + length - 1)
        cursor = first + length
    end
    return payload:sub(1, 2), fields
end

local function buildPayload(header, fields)
    local parts = { header }
    for _, field in ipairs(fields) do
        field = tostring(field)
        parts[#parts + 1] = tostring(#field) .. ":" .. field
    end
    return table.concat(parts)
end

local function copyFields(fields)
    local copied = {}
    for index, field in ipairs(fields) do copied[index] = field end
    return copied
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
    local decodedItemString, decodedItemID = GGM.ExtractItemString(message.slotValue.itemLink)
    T.assertEqual(decodedItemString, "item:9001:1:2:3")
    T.assertEqual(decodedItemID, message.slotValue.itemID)
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
    target.raceID, target.sex, target.displayID = 1, 3, 12345
    local snapshot = makeSnapshot(GGM)
    snapshot.slots.RANGED = { unavailable = true }
    local payload = assert(GGM.EncodeSyncSnapshotResponse(target, requester, makeIdentity("Carol", "Silvermoon", "Player-1234-CCCC"), snapshot, 12, "000001"))
    local message, err = GGM.DecodeSyncMessage(payload)
    T.assertNil(err)
    T.assertEqual(message.type, "SNAPSHOT_RESPONSE")
    T.assertEqual(message.target.key, target.key)
    T.assertEqual(message.target.raceID, 1)
    T.assertEqual(message.target.sex, 3)
    T.assertEqual(message.target.displayID, 12345)
    T.assertEqual(message.requester.key, requester.key)
    T.assertEqual(message.responder.key, "Carol-Silvermoon")
    T.assertEqual(message.requestID, "000001")
    T.assertEqual(message.confirmedSequence, 12)
    T.assertEqual(message.snapshot.capturedAt, 1700001000)
    T.assertEqual(message.snapshot.slots.HEAD.itemID, 5001)
    T.assertEqual(message.snapshot.slots.OFF_HAND.itemID, false)
    T.assertEqual(message.snapshot.slots.OFF_HAND.itemLink, false)
    local _, fields = parseFields(payload)
    for index, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local offset = 19 + (index - 1) * 4
        T.assertEqual(fields[offset], trackedSlot.key)
        if trackedSlot.key == "RANGED" then
            T.assertTrue(message.snapshot.slots.RANGED.unavailable)
        else
            T.assertEqual(message.snapshot.slots[trackedSlot.key].inventorySlotID, trackedSlot.inventorySlotID)
        end
        if not message.snapshot.slots[trackedSlot.key].unavailable
            and message.snapshot.slots[trackedSlot.key].itemID ~= false then
            local _, decodedItemID = GGM.ExtractItemString(message.snapshot.slots[trackedSlot.key].itemLink)
            T.assertEqual(decodedItemID, message.snapshot.slots[trackedSlot.key].itemID)
        end
    end
end)

T.test("snapshot response preserves race and sex when display id is unavailable", function()
    local GGM = loadModules()
    local target = makeIdentity("Alice", "Silvermoon", nil)
    target.raceID, target.sex = 2, 2
    local payload = assert(GGM.EncodeSyncSnapshotResponse(target, makeIdentity("Bob", "Silvermoon", "B"), makeIdentity("Carol", "Silvermoon", "C"), makeSnapshot(GGM), 1, "000001"))
    local message = assert(GGM.DecodeSyncMessage(payload))
    T.assertEqual(message.target.raceID, 2)
    T.assertEqual(message.target.sex, 2)
    T.assertNil(message.target.displayID)
end)

T.test("snapshot response encodes an absent race and sex pair as zero trio", function()
    local GGM = loadModules()
    local target = makeIdentity("Alice", "Silvermoon", nil)
    target.displayID = 12345
    local payload = assert(GGM.EncodeSyncSnapshotResponse(target, makeIdentity("Bob", "Silvermoon", "B"), makeIdentity("Carol", "Silvermoon", "C"), makeSnapshot(GGM), 1, "000001"))
    local _, fields = parseFields(payload)
    T.assertEqual(fields[16], "0")
    T.assertEqual(fields[17], "0")
    T.assertEqual(fields[18], "0")
    local message = assert(GGM.DecodeSyncMessage(payload))
    T.assertNil(message.target.raceID)
    T.assertNil(message.target.sex)
    T.assertNil(message.target.displayID)
end)

T.test("snapshot response rejects malformed target model fields and trailing fields", function()
    local GGM = loadModules()
    local base = assert(GGM.EncodeSyncSnapshotResponse(makeIdentity("Alice", "Silvermoon", nil), makeIdentity("Bob", "Silvermoon", "B"), makeIdentity("Carol", "Silvermoon", "C"), makeSnapshot(GGM), 1, "000001"))
    local header, original = parseFields(base)
    local malformed = {
        { "1", "0", "0" }, -- half-present pair
        { "x", "3", "1" }, -- nonnumeric race
        { "1", "x", "1" }, -- nonnumeric sex
        { "1", "3", "x" }, -- nonnumeric display id
        { "256", "3", "1" }, -- race out of range
        { "1", "4", "1" }, -- sex out of range
        { "1", "3", "2147483648" }, -- display id out of range
        { "0", "0", "1" }, -- display id without a race/sex pair
    }
    for _, trio in ipairs(malformed) do
        local fields = copyFields(original)
        fields[16], fields[17], fields[18] = trio[1], trio[2], trio[3]
        local message, err = GGM.DecodeSyncMessage(buildPayload(header, fields))
        T.assertNil(message)
        T.assertNotNil(err)
    end
    local extra = copyFields(original)
    extra[#extra + 1] = "unexpected"
    local extraMessage, extraErr = GGM.DecodeSyncMessage(buildPayload(header, extra))
    T.assertNil(extraMessage)
    T.assertEqual(extraErr, "sync-payload-trailing-data")
end)

T.test("snapshot response retains bounded framing shapes for existing message types", function()
    local GGM = loadModules()
    T.assertEqual(GGM.SYNC_PROTOCOL_VERSION, 5)
    local identity = makeIdentity("Alice", "Silvermoon", "A")
    local update = assert(GGM.EncodeSyncSlotUpdate(identity, 1, "HEAD", { inventorySlotID = 1, itemID = 5, itemLink = "|Hitem:5|h[Test]|h" }, 1))
    local request = assert(GGM.EncodeSyncSnapshotRequest(identity, makeIdentity("Bob", "Silvermoon", "B"), "000001"))
    local claim = assert(GGM.EncodeSyncSnapshotResponseClaim(identity, makeIdentity("Bob", "Silvermoon", "B"), makeIdentity("Carol", "Silvermoon", "C"), 1, "000001"))
    local response = assert(GGM.EncodeSyncSnapshotResponse(identity, makeIdentity("Bob", "Silvermoon", "B"), makeIdentity("Carol", "Silvermoon", "C"), makeSnapshot(GGM), 1, "000001"))
    local updateHeader, updateFields = parseFields(update)
    local requestHeader, requestFields = parseFields(request)
    local claimHeader, claimFields = parseFields(claim)
    local responseHeader, responseFields = parseFields(response)
    T.assertEqual(updateHeader, "5U")
    T.assertEqual(#updateFields, 10)
    T.assertEqual(requestHeader, "5Q")
    T.assertEqual(#requestFields, 9)
    T.assertEqual(claimHeader, "5C")
    T.assertEqual(#claimFields, 5)
    T.assertEqual(responseHeader, "5S")
    T.assertEqual(#responseFields, 18 + 4 * #GGM.TRACKED_SLOTS)
    T.assertTrue(#response <= GGM.SYNC_MAX_LOGICAL_BYTES)
    T.assertTrue(math.ceil(#response / GGM.SYNC_FRAME_CHUNK_BYTES) <= GGM.SYNC_MAX_FRAME_COUNT)
    local configuredMaximum = GGM.SYNC_MAX_LOGICAL_BYTES
    GGM.SYNC_MAX_LOGICAL_BYTES = #response - 1
    local oversized, err = GGM.EncodeSyncSnapshotResponse(identity, makeIdentity("Bob", "Silvermoon", "B"), makeIdentity("Carol", "Silvermoon", "C"), makeSnapshot(GGM), 1, "000001")
    GGM.SYNC_MAX_LOGICAL_BYTES = configuredMaximum
    T.assertNil(oversized)
    T.assertEqual(err, "sync-payload-too-large")
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
    local slotValue = {
        inventorySlotID = 1,
        itemID = 9001,
        itemLink = "|Hitem:9001|h" .. string.rep("x", GGM.SYNC_MAX_ITEM_LINK_BYTES + 1) .. "|h",
    }
    local payload, err = GGM.EncodeSyncSlotUpdate(identity, 1, "HEAD", slotValue, 1700001200)
    T.assertNil(payload)
    T.assertEqual(err, "sync-item-link-too-long")
end)

T.test("protocol rejects unsupported versions and unknown message types", function()
    local GGM = loadModules()
    local versionMessage, versionErr = GGM.DecodeSyncMessage("9U")
    T.assertNil(versionMessage)
    T.assertEqual(versionErr, "sync-protocol-version-unsupported")
    local typeMessage, typeErr = GGM.DecodeSyncMessage(tostring(GGM.SYNC_PROTOCOL_VERSION) .. "X")
    T.assertNil(typeMessage)
    T.assertEqual(typeErr, "sync-message-type-unknown")
end)

T.test("protocol rejects malformed length prefixes and trailing data", function()
    local GGM = loadModules()
    local malformed, malformedErr = GGM.DecodeSyncMessage(tostring(GGM.SYNC_PROTOCOL_VERSION) .. "Qx:abc")
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

T.test("protocol version five rejects version two snapshot payloads", function()
    local GGM = loadModules()
    T.assertEqual(GGM.SYNC_PROTOCOL_VERSION, 5)
    local payload = assert(GGM.EncodeSyncSnapshotResponse(
        makeIdentity("Alice", "Silvermoon", "A"),
        makeIdentity("Bob", "Silvermoon", "B"),
        makeIdentity("Carol", "Silvermoon", "C"),
        makeSnapshot(GGM), 1, "000001"
    ))
    local message, err = GGM.DecodeSyncMessage("2" .. payload:sub(2))
    T.assertNil(message)
    T.assertEqual(err, "sync-protocol-version-unsupported")
end)
