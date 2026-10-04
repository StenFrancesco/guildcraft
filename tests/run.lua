package.path = "./?.lua;./?/init.lua;" .. package.path

local suites = {
    "tests.constants_test",
    "tests.character_identity_test",
    "tests.gear_data_test",
    "tests.gear_snapshot_test",
    "tests.storage_test",
    "tests.local_gear_memory_test",
    "tests.snapshot_test_ui_test",
    "tests.stable_gear_tracker_test",
    "tests.sync_protocol_test",
    "tests.sync_transport_test",
    "tests.guild_sync_test",
    "tests.profession_snapshot_test",
    "tests.profession_index_test",
    "tests.profession_link_save_test",
    "tests.main_test",
    "tests.saved_character_model_test",
    "tests.recipe_details_test",
}

for _, moduleName in ipairs(suites) do
    require(moduleName)
end

local T = require("tests.testlib")
T.run()
