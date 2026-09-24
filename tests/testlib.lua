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
    local chunk = assert(loadfile(path))
    chunk("GuildGearMemory", namespace)
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
