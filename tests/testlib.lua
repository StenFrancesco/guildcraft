local TestLib = {
    tests = {},
}

function TestLib.test(name, fn)
    table.insert(TestLib.tests, {
        name = name,
        fn = fn,
    })
end

function TestLib.assertEqual(actual, expected, message)
    if actual ~= expected then
        error(message or ("expected " .. tostring(expected) .. ", got " .. tostring(actual)), 2)
    end
end

function TestLib.assertTrue(value, message)
    if value ~= true then
        error(message or ("expected true, got " .. tostring(value)), 2)
    end
end

function TestLib.assertFalse(value, message)
    if value ~= false then
        error(message or ("expected false, got " .. tostring(value)), 2)
    end
end

function TestLib.assertNil(value, message)
    if value ~= nil then
        error(message or ("expected nil, got " .. tostring(value)), 2)
    end
end

function TestLib.assertNotNil(value, message)
    if value == nil then
        error(message or "expected a non-nil value", 2)
    end
end

function TestLib.loadAddonFile(path, namespace)
    if path == "The Guild Book gear/SyncTransport.lua" then
        local env = setmetatable({ strmatch = string.match }, { __index = _G })
        env._G = env
        for _, dependency in ipairs({ "Libs/LibStub/LibStub", "Libs/LibDeflate/LibDeflate", "GearCompression" }) do
            local loadDependency = assert(loadfile("The Guild Book gear/" .. dependency .. ".lua"))
            setfenv(loadDependency, env)("The Guild Book gear", namespace)
        end
    end
    if path == "The Guild Book/ProfessionTransport.lua" then
        local env = setmetatable({ strmatch = string.match }, { __index = _G })
        env._G = env
        for _, dependency in ipairs({ "Libs/LibStub/LibStub", "Libs/LibDeflate/LibDeflate", "ProfessionCompression" }) do
            local loadDependency = assert(loadfile("The Guild Book/" .. dependency .. ".lua"))
            setfenv(loadDependency, env)("The Guild Book", namespace)
        end
    end
    local chunk = assert(loadfile(path))
    chunk(path:match("^([^/]+)/"), namespace)
end

-- Immediate CTL completion for legacy fixtures; dedicated tests delay it.
function TestLib.mockChatThrottle(api)
    api.ChatThrottleLib = {
        SendAddonMessage = function(_, priority, prefix, text, channel, target, queue, callback, arg)
            local result = select(-1, api.C_ChatInfo.SendAddonMessage(prefix, text, channel, target))
            callback(arg, result == 0 or result == true, result)
        end,
    }
end

-- Legacy unit fixtures exercise both domains in one namespace. Manifest tests
-- separately verify actual addon load order and independent namespaces.
function TestLib.loadUnitModule(name, namespace)
    local gear = { GearData = true, GearSnapshot = true, CharacterIdentity = true,
        StableGearTracker = true, LocalGearMemory = true, SyncProtocol = true,
        SyncTransport = true, GuildSync = true }
    TestLib.loadAddonFile((gear[name] and "The Guild Book gear/" or "The Guild Book/") .. name .. ".lua", namespace)
    if name == "Constants" or name == "Storage" then
        TestLib.loadAddonFile("The Guild Book gear/" .. name .. ".lua", namespace)
    end
end

function TestLib.initializeDatabase(namespace, existing)
    local db, err = namespace.InitializeDatabase(existing)
    if not db then return nil, err end
    if namespace.InitializeGearDatabase then
        local gear, gearErr = namespace.InitializeGearDatabase(existing)
        if not gear then return nil, gearErr end
        db.characters, db.localCharacters = gear.characters, gear.localCharacters
    end
    return db, nil
end

function TestLib.run()
    local passed = 0
    local failed = 0

    for _, testCase in ipairs(TestLib.tests) do
        local ok, err = pcall(testCase.fn)
        if ok then
            passed = passed + 1
            print("PASS " .. testCase.name)
        else
            failed = failed + 1
            print("FAIL " .. testCase.name)
            print("  " .. tostring(err))
        end
    end

    print(string.format("\n%d passed, %d failed", passed, failed))

    if failed > 0 then
        os.exit(1)
    end
end

return TestLib
