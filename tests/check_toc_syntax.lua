-- Compile all Lua sources actually listed by each addon TOC, without executing.
local count = 0
for _,addon in ipairs({"The Guild Book","The Guild Book gear","The Guild Book Bank"}) do
    for line in io.lines(addon .. "/" .. addon .. ".toc") do
        local path = line:match("^%s*(.-)%s*$")
        if path:match("%.lua$") and path:sub(1,1) ~= "#" then
            assert(loadfile(addon .. "/" .. path))
            count = count + 1
        end
    end
end
print(count .. " TOC-listed Lua sources compiled successfully")
