local _, GGM = ...

local MAX_BYTES, MIN_COMPRESS_BYTES = GGM.SYNC_MAX_LOGICAL_BYTES, 1024
local lib = LibStub and LibStub:GetLibrary("LibDeflate", true)

local function isRecord(payload)
    return payload:sub(1, 2) == tostring(GGM.SYNC_PROTOCOL_VERSION) .. "S"
end

function GGM.IsGearCompressionAvailable()
    return type(lib) == "table" and type(lib.CompressDeflate) == "function"
        and type(lib.EncodeForWoWAddonChannel) == "function" and type(lib.DecodeForWoWAddonChannel) == "function"
        and type(lib.Adler32) == "function" and type(GGM.DecompressBoundedDeflate) == "function"
end

function GGM.EncodeGearPayload(payload)
    if type(payload) ~= "string" or #payload == 0 then return nil, "sync-payload-invalid" end
    if #payload > MAX_BYTES then return nil, "sync-payload-too-large" end
    if not GGM.IsGearCompressionAvailable() then return nil, "sync-compression-unavailable" end
    if #payload < MIN_COMPRESS_BYTES or not isRecord(payload) then return payload end
    -- Level 1 avoids expensive high-ratio searches for short-lived gear snapshots.
    local ok, result = pcall(function()
        local compressed = lib:CompressDeflate(payload, { level = 1 })
        return "Z1|" .. #payload .. "|" .. lib:Adler32(payload) .. "|" .. lib:EncodeForWoWAddonChannel(compressed)
    end)
    if not ok or type(result) ~= "string" then return nil, "sync-compression-failed" end
    if #result < #payload then return result end
    return payload
end

function GGM.DecodeGearPayload(payload)
    if type(payload) ~= "string" or #payload == 0 then return nil, "sync-payload-invalid" end
    if #payload > MAX_BYTES then return nil, "sync-payload-too-large" end
    if payload:sub(1, 1) ~= "Z" then return payload end
    if not GGM.IsGearCompressionAvailable() then return nil, "sync-compression-unavailable" end
    local lengthText, checksumText, start = payload:match("^Z1|(%d+)|(%d+)|()")
    local length, checksum = tonumber(lengthText), tonumber(checksumText)
    if not length or #lengthText > 5 or length < 1 or length > MAX_BYTES
        or not checksum or #checksumText > 10 or checksum > 4294967295 then
        return nil, "sync-compressed-envelope-invalid"
    end
    local ok, decoded = pcall(function()
        local compressed = lib:DecodeForWoWAddonChannel(payload:sub(start))
        if not compressed or #compressed == 0 then return nil end
        local result, remaining = GGM.DecompressBoundedDeflate(compressed, length)
        if not result or remaining ~= 0 or #result ~= length or not isRecord(result)
            or lib:Adler32(result) ~= checksum then return nil end
        return result
    end)
    if not ok or not decoded then return nil, "sync-compressed-payload-invalid" end
    return decoded
end
