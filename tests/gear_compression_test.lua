local T = require("tests.testlib")

local function load()
    local G = {}
    local env = setmetatable({ strmatch = string.match }, { __index = _G }); env._G = env
    for _, name in ipairs({ "Libs/LibStub/LibStub", "Libs/LibDeflate/LibDeflate", "Constants",
        "GearData", "GearSnapshot", "SyncProtocol", "GearCompression", "SyncTransport" }) do
        local chunk = assert(loadfile("The Guild Book gear/" .. name .. ".lua"))
        setfenv(chunk, env)("The Guild Book gear", G)
    end
    return G, env.LibStub("LibDeflate"), env
end

local function record(G)
    local function identity(name)
        return { key = name .. "-Silvermoon", name = name, realm = "Silvermoon", guid = "Player-1-" .. name }
    end
    local target, requester, responder = identity("Alice"), identity("Bob"), identity("Carol")
    local snapshot = { complete = true, capturedAt = 1700001000, slots = {}, slotObservedAt = {} }
    for index, slot in ipairs(G.TRACKED_SLOTS) do
        snapshot.slots[slot.key] = { inventorySlotID = slot.inventorySlotID, itemID = 5000 + index,
            itemLink = "|cffa335ee|Hitem:" .. (5000 + index) .. ":0:0:0:0:0:0:0:80:0:0:0:0|h[Tempered Steel " .. slot.key .. "]|h|r" }
        snapshot.slotObservedAt[slot.inventorySlotID] = snapshot.capturedAt - index + 1
    end
    return assert(G.EncodeSyncSnapshotResponse(target, requester, responder, snapshot, 42, "000001"))
end

local function envelope(lib, payload, suffix)
    return "Z1|" .. #payload .. "|" .. lib:Adler32(payload) .. "|" ..
        lib:EncodeForWoWAddonChannel(lib:CompressDeflate(payload, {level=1}) .. (suffix or ""))
end

local function api()
    local calls, timers = {}, {}
    local a = { C_ChatInfo = { RegisterAddonMessagePrefix = function() return 0 end,
        SendAddonMessage = function(prefix, text, channel)
            calls[#calls+1] = {prefix=prefix, text=text, channel=channel}; return 0
        end }, GetTime = function() return 100 end,
        C_Timer = { NewTimer = function(delay, callback) timers[#timers+1] = callback; return {} end } }
    T.mockChatThrottle(a)
    local function drain()
        local index = 1
        while timers[index] do timers[index](); index=index+1 end
    end
    return a, calls, drain
end

T.test("gear compresses real equipment snapshots and restores every protocol field", function()
    local G = load()
    local original = record(G)
    local encoded = assert(G.EncodeGearPayload(original))
    T.assertTrue(#original >= 1024)
    T.assertEqual(encoded:sub(1,3), "Z1|")
    T.assertTrue(#encoded < #original / 2)
    T.assertEqual(G.DecodeGearPayload(encoded), original)
    T.assertTrue(not encoded:find("%z"))
    local message = assert(G.DecodeSyncMessage(assert(G.DecodeGearPayload(encoded))))
    T.assertEqual(message.confirmedSequence, 42)
    T.assertEqual(message.snapshot.capturedAt, 1700001000)
    for index, slot in ipairs(G.TRACKED_SLOTS) do
        T.assertEqual(message.snapshot.slots[slot.key].itemID, 5000+index)
        T.assertEqual(G.GetGearSlotObservedAt(message.snapshot, slot.inventorySlotID), 1700001001-index)
    end
end)

T.test("gear keeps small snapshots and coordination or slot updates plain", function()
    local G = load()
    for _, payload in ipairs({"7Ssmall", "7U" .. string.rep("slot",300), "7Qrequest", "7Cclaim", "arbitrary"}) do
        T.assertEqual(G.EncodeGearPayload(payload), payload)
        T.assertEqual(G.DecodeGearPayload(payload), payload)
    end
    local bytes, seed = {}, 12345
    for i=1,4000 do seed=(seed*48271)%2147483647; bytes[i]=string.char(seed%256) end
    local incompressible = "7S" .. table.concat(bytes)
    T.assertEqual(G.EncodeGearPayload(incompressible), incompressible)
end)

T.test("gear rejects malformed compressed envelopes and enforces original and wire limits", function()
    local G, lib = load()
    local encoded = assert(G.EncodeGearPayload(record(G)))
    for _, bad in ipairs({"Z1|", "Z2|10|0|bad", "Z1|0|0|x", "Z1|7361|0|x", "Z1|000001|0|x",
        "Z1|10|4294967296|x", "Z1|10|0|" .. string.char(0), encoded:sub(1,-3),
        encoded:gsub("^Z1|%d+|", "Z1|1|"), encoded:gsub("^(Z1|%d+|)%d+|", "%10|"),
        envelope(lib, record(G), "trailing"), envelope(lib, "7Q" .. string.rep("x",2000)),
        envelope(lib, "6S" .. string.rep("x",2000)), envelope(lib, "P5|D|" .. string.rep("x",2000)),
        string.rep("Z",G.SYNC_MAX_LOGICAL_BYTES+1)}) do
        T.assertNil(G.DecodeGearPayload(bad))
    end
    T.assertNil(G.EncodeGearPayload("7S" .. string.rep("x",G.SYNC_MAX_LOGICAL_BYTES)))
    T.assertNil(G.EncodeGearPayload(false))
    T.assertNil(G.DecodeGearPayload(""))
end)

T.test("gear inflation stops stored fixed and dynamic expansion at the declared length", function()
    local G, lib = load()
    for _, config in ipairs({{level=0}, {level=1,strategy="fixed"}, {level=6,strategy="dynamic"}}) do
        local compressed = lib:CompressDeflate(string.rep("x",20000),config)
        local result, status = G.DecompressBoundedDeflate(compressed, G.SYNC_MAX_LOGICAL_BYTES)
        T.assertNil(result); T.assertEqual(status,-100)
    end
    local exact = "7S" .. string.rep("x",G.SYNC_MAX_LOGICAL_BYTES-2)
    T.assertEqual(G.DecodeGearPayload(envelope(lib,exact)),exact)
    local over = exact .. "x"
    local compressed = lib:CompressDeflate(over,{level=1})
    T.assertNil(G.DecodeGearPayload("Z1|7360|" .. lib:Adler32(over) .. "|" .. lib:EncodeForWoWAddonChannel(compressed)))
end)

local function emptyBlocks(count, payload)
    local bits = string.rep("0100000000",count) .. "100"
    bits = bits .. string.rep("0",(8-#bits%8)%8)
    local bytes = {}
    for i=1,#bits,8 do
        local value=0
        for b=0,7 do if bits:sub(i+b,i+b)=="1" then value=value+2^b end end
        bytes[#bytes+1]=string.char(value)
    end
    local n=#payload; local complement=65535-n
    return table.concat(bytes) .. string.char(n%256,math.floor(n/256),complement%256,math.floor(complement/256)) .. payload
end

T.test("gear rejects excessive DEFLATE blocks before dispatch and resets its work budget", function()
    local G, lib = load()
    local payload="7Srecord"
    local accepted=emptyBlocks(127,payload)
    T.assertEqual(G.DecompressBoundedDeflate(accepted,#payload),payload)
    local result,status=G.DecompressBoundedDeflate(emptyBlocks(128,payload),#payload)
    T.assertNil(result); T.assertEqual(status,-101)
    T.assertEqual(G.DecompressBoundedDeflate(accepted,#payload),payload)
    local a=api(); local called=0
    local transport=assert(G.CreateSyncTransport(a,function() called=called+1 end))
    local wire="Z1|" .. #payload .. "|" .. lib:Adler32(payload) .. "|" .. lib:EncodeForWoWAddonChannel(emptyBlocks(128,payload))
    local total=math.ceil(#wire/G.SYNC_FRAME_CHUNK_BYTES)
    local state,err
    for i=1,total do
        state,err=G.HandleSyncTransportMessage(transport,G.SYNC_PREFIX,string.format("F1|000001|%02d|%02d|%s",i,total,wire:sub((i-1)*230+1,i*230)),"GUILD","Alice-Silvermoon")
    end
    T.assertNil(state); T.assertEqual(err,"sync-compressed-payload-invalid")
    T.assertEqual(called,0); T.assertNil(next(transport.inboundAssemblies))
end)

T.test("gear transport reduces snapshot frames and bytes and dispatches only after full decode", function()
    local G=load(); local a,calls,drain=api(); local received,done=0,0
    local original=record(G)
    local transport=assert(G.CreateSyncTransport(a,function(sender,payload)
        received=received+1; T.assertEqual(sender,"Alice-Silvermoon"); T.assertEqual(payload,original); return "received"
    end))
    T.assertTrue(G.SendSyncPayload(transport,original,function(sent) T.assertTrue(sent); done=done+1 end))
    drain(); T.assertEqual(done,1)
    local bytes=0
    for i,call in ipairs(calls) do
        bytes=bytes+#call.text
        T.assertTrue(#call.text<=G.SYNC_MAX_ADDON_MESSAGE_BYTES)
        local state,err=G.HandleSyncTransportMessage(transport,call.prefix,call.text,call.channel,"Alice-Silvermoon")
        T.assertNil(err); T.assertEqual(state,i==#calls and "received" or "partial")
        T.assertEqual(received,i==#calls and 1 or 0)
    end
    local plainFrames=math.ceil(#original/G.SYNC_FRAME_CHUNK_BYTES)
    T.assertTrue(#calls<plainFrames); T.assertTrue(bytes<#original+17*plainFrames)
    print(string.format("GEAR TRAFFIC: %d bytes/%d frames plain -> %d bytes/%d frames compressed (including frame headers)",#original+17*plainFrames,plainFrames,bytes,#calls))
end)

T.test("gear protocol seven isolates old peers and rejects version six logical messages", function()
    local G=load(); local a=api(); local called=0
    local transport=assert(G.CreateSyncTransport(a,function() called=called+1 end))
    T.assertEqual(G.SYNC_PROTOCOL_VERSION,7); T.assertEqual(G.SYNC_PREFIX,"GC_GEAR7")
    T.assertEqual(G.HandleSyncTransportMessage(transport,"GC_GEAR","F1|000001|01|01|6Q","GUILD","Alice-Silvermoon"),"ignored")
    local result,err=G.DecodeSyncMessage("6" .. record(G):sub(2))
    T.assertNil(result); T.assertEqual(err,"sync-protocol-version-unsupported"); T.assertEqual(called,0)
end)

T.test("gear sync fails closed when its compression dependency is missing", function()
    local G=load(); G.DecompressBoundedDeflate=nil
    T.assertFalse(G.IsGearCompressionAvailable())
    local a=api(); local transport,err=G.CreateSyncTransport(a,function() end)
    T.assertNil(transport); T.assertEqual(err,"sync-compression-unavailable")
    T.assertNil(G.EncodeGearPayload("7Qrequest")); T.assertNil(G.DecodeGearPayload("Z1|1|0|x"))
end)

T.test("gear and profession libraries share registration and retain private decoders in both load orders", function()
    for _, folders in ipairs({{"The Guild Book","The Guild Book gear"},{"The Guild Book gear","The Guild Book"}}) do
        local env=setmetatable({strmatch=string.match},{__index=_G}); env._G=env
        local shared,sharedDecode,namespaces=nil,nil,{}
        for _,folder in ipairs(folders) do
            local G={}; namespaces[folder]=G
            local files={"Libs/LibStub/LibStub","Libs/LibDeflate/LibDeflate"}
            if folder=="The Guild Book gear" then files[#files+1]="Constants"; files[#files+1]="GearCompression"
            else files[#files+1]="ProfessionCompression" end
            for _,file in ipairs(files) do setfenv(assert(loadfile(folder .. "/" .. file .. ".lua")),env)(folder,G) end
            if not shared then shared=env.LibStub("LibDeflate"); sharedDecode=shared.DecompressDeflate
            else T.assertTrue(shared==env.LibStub("LibDeflate")); T.assertTrue(sharedDecode==shared.DecompressDeflate) end
        end
        local gear,prof=namespaces["The Guild Book gear"],namespaces["The Guild Book"]
        local payload="7S" .. string.rep("snapshot",300)
        T.assertEqual(gear.DecodeGearPayload(assert(gear.EncodeGearPayload(payload))),payload)
        local recipe="P5|D|" .. string.rep("recipe",300)
        T.assertEqual(prof.DecodeProfessionPayload(assert(prof.EncodeProfessionPayload(recipe))),recipe)
    end
end)
