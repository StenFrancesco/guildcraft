local T = require("tests.testlib")

local function loadModule()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/CharacterIdentity.lua", GGM)
    return GGM
end

T.test("player identity uses name and realm as the storage key", function()
    local GGM = loadModule()
    local api = {
        UnitFullName = function(unit)
            T.assertEqual(unit, "player")
            return "Alice", "Silvermoon"
        end,
        GetRealmName = function()
            return "FallbackRealm"
        end,
        UnitGUID = function(unit)
            T.assertEqual(unit, "player")
            return "Player-1234-ABCDEF"
        end,
    }

    local identity, err = GGM.BuildPlayerIdentity(api)

    T.assertNil(err)
    T.assertEqual(identity.key, "Alice-Silvermoon")
    T.assertEqual(identity.name, "Alice")
    T.assertEqual(identity.realm, "Silvermoon")
    T.assertEqual(identity.guid, "Player-1234-ABCDEF")
end)

T.test("player identity falls back to GetRealmName when UnitFullName has no realm", function()
    local GGM = loadModule()
    local api = {
        UnitFullName = function()
            return "Alice", nil
        end,
        GetRealmName = function()
            return "Silvermoon"
        end,
        UnitGUID = function()
            return "Player-1234-ABCDEF"
        end,
    }

    local identity, err = GGM.BuildPlayerIdentity(api)

    T.assertNil(err)
    T.assertEqual(identity.key, "Alice-Silvermoon")
end)

T.test("player identity fails closed when name is unavailable", function()
    local GGM = loadModule()
    local api = {
        UnitFullName = function()
            return nil, nil
        end,
        GetRealmName = function()
            return "Silvermoon"
        end,
        UnitGUID = function()
            return "Player-1234-ABCDEF"
        end,
    }

    local identity, err = GGM.BuildPlayerIdentity(api)

    T.assertNil(identity)
    T.assertEqual(err, "player-name-unavailable")
end)

T.test("player identity fails closed when realm is unavailable", function()
    local GGM = loadModule()
    local api = {
        UnitFullName = function()
            return "Alice", nil
        end,
        GetRealmName = function()
            return nil
        end,
        UnitGUID = function()
            return "Player-1234-ABCDEF"
        end,
    }

    local identity, err = GGM.BuildPlayerIdentity(api)

    T.assertNil(identity)
    T.assertEqual(err, "player-realm-unavailable")
end)
