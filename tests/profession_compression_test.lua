local T = require("tests.testlib")

local function load()
    local G = {}
    local env = setmetatable({ strmatch = string.match }, { __index = _G })
    env._G = env
    for _, file in ipairs({ "Libs/LibStub/LibStub", "Libs/LibDeflate/LibDeflate", "ProfessionCompression" }) do
        local chunk = assert(loadfile("The Guild Book/" .. file .. ".lua"))
        setfenv(chunk, env)("The Guild Book", G)
    end
    return G, env.LibStub("LibDeflate")
end

local function record(n)
    return "P5|D|Bob-Realm|000001|164|" .. string.rep("12345:Tempered%20Steel%20Sword:98765,", n or 200)
end

T.test("compression uses real LibDeflate and restores the exact large record", function()
    local G = load()
    local original = record()
    local encoded = assert(G.EncodeProfessionPayload(original))
    T.assertTrue(encoded:sub(1, 3) == "Z1|")
    T.assertTrue(#encoded < #original / 2)
    T.assertEqual(assert(G.DecodeProfessionPayload(encoded)), original)
    T.assertTrue(not encoded:find("%z"))
end)

T.test("compression leaves small and coordination payloads unchanged", function()
    local G = load()
    for _, payload in ipairs({ "P5|D|Bob|1|164|short", "P5|M|" .. string.rep("manifest", 500), "arbitrary" }) do
        T.assertEqual(G.EncodeProfessionPayload(payload), payload)
        T.assertEqual(G.DecodeProfessionPayload(payload), payload)
    end
end)

T.test("compressed envelopes reject malformed lengths encoding and checksums", function()
    local G = load()
    local encoded = assert(G.EncodeProfessionPayload(record()))
    for _, bad in ipairs({ "Z1|", "Z2|10|0|bad", "Z1|65537|0|bad", "Z1|0|0|bad",
        encoded:gsub("^Z1|%d+|", "Z1|1|"), encoded:gsub("^(Z1|%d+|)%d+|", "%10|"), encoded:sub(1, -3) }) do
        T.assertNil(G.DecodeProfessionPayload(bad))
    end
end)

T.test("bounded inflater stops stored fixed and dynamic expansion before the output limit", function()
    local G, lib = load()
    for _, config in ipairs({ {level=0}, {level=1, strategy="fixed"}, {level=6, strategy="dynamic"} }) do
        local compressed = lib:CompressDeflate(string.rep("x", 200000), config)
        local result, status = G.DecompressProfessionDeflate(compressed, 65536)
        T.assertNil(result)
        T.assertEqual(status, -100)
    end
    local original = record()
    local encoded = lib:EncodeForWoWAddonChannel(lib:CompressDeflate(original))
    T.assertNil(G.DecodeProfessionPayload("Z1|1|0|" .. encoded))
end)

T.test("compressed envelopes reject trailing input and non-record output", function()
    local G, lib = load()
    local original = record()
    local function envelope(payload, suffix)
        return "Z1|" .. #payload .. "|" .. lib:Adler32(payload) .. "|" ..
            lib:EncodeForWoWAddonChannel(lib:CompressDeflate(payload) .. (suffix or ""))
    end
    T.assertNil(G.DecodeProfessionPayload(envelope(original, "trailing")))
    T.assertNil(G.DecodeProfessionPayload(envelope("P5|M|" .. string.rep("x", 2000))))
    T.assertNil(G.EncodeProfessionPayload(string.rep("x", 65537)))
end)

T.test("bounded inflation accepts the exact limit and rejects one extra byte across blocks", function()
    local G, lib = load()
    for _, size in ipairs({ 65536, 65537, 200000 }) do
        local compressed = lib:CompressDeflate(string.rep("abcd", math.floor(size / 4)) .. string.rep("x", size % 4), {level=1})
        local result, status = G.DecompressProfessionDeflate(compressed, 65536)
        if size == 65536 then T.assertEqual(#assert(result), size)
        else T.assertNil(result); T.assertEqual(status, -100) end
    end
    local stored = lib:CompressDeflate(string.rep("x", 60000), {level=0})
    local result, status = G.DecompressProfessionDeflate(stored, 59999)
    T.assertNil(result); T.assertEqual(status, -100)
    T.assertEqual(#assert(G.DecompressProfessionDeflate(stored, 60000)), 60000)
end)

T.test("corrupt compressed recipe records preserve the saved snapshot without acknowledgement", function()
    local bus = require("tests.profession_sync_fixture")()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local ids = {}
    for i=1,1000 do ids[i]=i end
    a:save(a.identity, ids, 1700000001)
    b:save(a.identity, {1,2,3}, 1700000000)
    a:ready(); b:ready()
    local decode, rejected = b.G.DecodeProfessionPayload, 0
    b.G.DecodeProfessionPayload = function(payload)
        if payload:sub(1,3) == "Z1|" then
            rejected = rejected + 1
            payload = payload:gsub("^(Z1|%d+|)%d+|", "%10|")
        end
        return decode(payload)
    end
    assert(b.G.RequestProfessionSync(b.sync,164,"manual")); bus:advance(45)
    T.assertTrue(rejected > 0)
    local saved = assert(b.G.GetProfessionSyncRecord(b.db,a.identity.guid,164))
    T.assertEqual(#saved.recipes,3)
    T.assertEqual(saved.capturedAt,1700000000)
    T.assertEqual(bus:count("K", b.identity.key),0)
end)

T.test("an existing shared LibDeflate remains registered while the private bounded decoder loads", function()
    local G = {}
    local env = setmetatable({ strmatch = string.match }, { __index = _G }); env._G = env
    local function run(file, namespace)
        local chunk = assert(loadfile("The Guild Book/" .. file .. ".lua"))
        setfenv(chunk, env)("The Guild Book", namespace)
    end
    run("Libs/LibStub/LibStub", {})
    run("Libs/LibDeflate/LibDeflate", {})
    local shared = env.LibStub("LibDeflate")
    local decompress = shared.DecompressDeflate
    run("Libs/LibDeflate/LibDeflate", G)
    run("ProfessionCompression", G)
    T.assertTrue(env.LibStub("LibDeflate") == shared)
    T.assertTrue(shared.DecompressDeflate == decompress)
    T.assertEqual(assert(G.DecodeProfessionPayload(assert(G.EncodeProfessionPayload(record())))), record())
    local bomb = shared:CompressDeflate(string.rep("x", 100000))
    local result, status = G.DecompressProfessionDeflate(bomb, 100)
    T.assertNil(result); T.assertEqual(status,-100)
end)

T.test("incompressible records stay plain and codec limits apply before decoding", function()
    local G = load()
    local bytes, seed = {}, 12345
    for i=1,4000 do
        seed = (seed * 48271) % 2147483647
        bytes[i] = string.char(seed % 256)
    end
    local original = "P5|D|" .. table.concat(bytes)
    T.assertEqual(G.EncodeProfessionPayload(original), original)
    T.assertNil(G.DecodeProfessionPayload(string.rep("Z",65537)))
    G.DecompressProfessionDeflate = nil
    T.assertFalse(G.IsProfessionCompressionAvailable())
    T.assertNil(G.EncodeProfessionPayload(record()))
    T.assertNil(G.DecodeProfessionPayload("Z1|1|1|x"))
end)

-- Build valid DEFLATE with empty non-final fixed blocks, then a final stored
-- block. Bits are packed least-significant first, including the stored padding.
local function emptyBlockStream(count, payload)
    local bits = string.rep("0100000000", count) .. "100"
    bits = bits .. string.rep("0", (8 - #bits % 8) % 8)
    local bytes = {}
    for i = 1, #bits, 8 do
        local byte = 0
        for bit = 0, 7 do
            if bits:sub(i + bit, i + bit) == "1" then byte = byte + 2 ^ bit end
        end
        bytes[#bytes + 1] = string.char(byte)
    end
    local length = #payload
    local complement = 65535 - length
    return table.concat(bytes) .. string.char(length % 256, math.floor(length / 256),
        complement % 256, math.floor(complement / 256)) .. payload
end

local function compressedEnvelope(lib, compressed, payload)
    return "Z1|" .. #payload .. "|" .. lib:Adler32(payload) .. "|" .. lib:EncodeForWoWAddonChannel(compressed)
end

T.test("private inflater rejects excessive zero-output blocks within the wire limit", function()
    local G, lib = load()
    local payload = "P5|D|Bob|1|164|test"
    local compressed = emptyBlockStream(43000, payload)
    local envelope = compressedEnvelope(lib, compressed, payload)
    T.assertTrue(#envelope <= 65536)
    -- The shared upstream API establishes that this is valid DEFLATE, not a
    -- malformed fixture, and remains unaffected by the private work budget.
    T.assertEqual(lib:DecompressDeflate(compressed), payload)
    local result, status = G.DecompressProfessionDeflate(compressed, #payload)
    T.assertNil(result)
    T.assertEqual(status, -101)
    T.assertNil(G.DecodeProfessionPayload(envelope))
end)

T.test("private block budget accepts 128 blocks rejects 129 and resets per record", function()
    local G, lib = load()
    local payload = "P5|D|Bob|1|164|test"
    local allowed = emptyBlockStream(127, payload)
    T.assertEqual(G.DecompressProfessionDeflate(allowed, #payload), payload)
    local result, status = G.DecompressProfessionDeflate(emptyBlockStream(128, payload), #payload)
    T.assertNil(result)
    T.assertEqual(status, -101)
    T.assertEqual(G.DecodeProfessionPayload(compressedEnvelope(lib, allowed, payload)), payload)
end)

T.test("excessive-block envelopes never reach the transport payload handler", function()
    local G, lib = load()
    T.loadAddonFile("The Guild Book/ProfessionTransport.lua", G)
    local client = require("tests.profession_sync_fixture")():client("Alice")
    local called = 0
    local transport = assert(G.CreateProfessionTransport(client.api, function() called = called + 1 end))
    local payload = "P5|D|Bob|1|164|test"
    local envelope = compressedEnvelope(lib, emptyBlockStream(43000, payload), payload)
    local total = math.ceil(#envelope / 222)
    local state, err
    for i = 1, total do
        local frame = string.format("F1|000001|%03d|%03d|%s", i, total, envelope:sub((i-1)*222+1,i*222))
        state, err = G.ReceiveProfessionFrame(transport,"GC_PROF5",frame,"WHISPER","Bob-Realm")
    end
    T.assertNil(state)
    T.assertEqual(err, "profession-compressed-payload-invalid")
    T.assertEqual(called, 0)
    T.assertNil(next(transport.inboundAssemblies))
end)

return { load = load, record = record }
