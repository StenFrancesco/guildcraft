local ADDON_NAME, GGM = ...

local PREFIX = "TGB_VERSION1"
local URL = "https://github.com/StenFrancesco/guildcraft"

local function parseVersion(value)
    if type(value) ~= "string" or #value > 40 then return nil end
    local a, b, c, suffix = value:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
    if not a or (suffix ~= "" and not suffix:match("^%-[%w%.%-]+$")) then return nil end
    a, b, c = tonumber(a), tonumber(b), tonumber(c)
    if not a or not b or not c or a > 999999 or b > 999999 or c > 999999 then return nil end
    return { a, b, c }
end

local function compare(a, b)
    for i = 1, 3 do
        if a[i] ~= b[i] then return a[i] > b[i] and 1 or -1 end
    end
    return 0
end

function GGM.CreateUpdateNotice(api, version)
    local localVersion = parseVersion(version)
    local notice = { api = api, version = version, parsed = localVersion, available = false }
    function notice:RefreshButton()
        local button = GGM.guildGearBrowserFrame and GGM.guildGearBrowserFrame.updateButton
        if button then
            button:SetEnabled(self.available)
        end
    end
    function notice:Send(kind, channel, target)
        if not self.registered or not self.parsed or not api.ChatThrottleLib then return end
        pcall(api.ChatThrottleLib.SendAddonMessage, api.ChatThrottleLib, "NORMAL", PREFIX,
            kind .. ":" .. self.version, channel, target, PREFIX)
    end
    function notice:Announce()
        if not self.registered or type(api.IsInGuild) ~= "function" or not api.IsInGuild() then
            self.guild = nil
            return
        end
        local guild = type(api.GetGuildInfo) == "function" and api.GetGuildInfo("player")
        if not guild or guild == self.guild then return end
        self.guild = guild
        self.replies = {}
        self:Send("Q", "GUILD")
    end
    function notice:Receive(prefix, message, channel, sender)
        if not self.registered or prefix ~= PREFIX or type(message) ~= "string"
            or (channel ~= "GUILD" and channel ~= "WHISPER") or type(sender) ~= "string" or sender == "" then return end
        local kind, versionText = message:match("^([QR]):(.+)$")
        local remote = parseVersion(versionText)
        if not remote or not self.parsed or (kind == "Q" and channel ~= "GUILD")
            or (kind == "R" and channel ~= "WHISPER") or not kind then return end
        local order = compare(remote, self.parsed)
        if order > 0 then
            self.available = true
            self:RefreshButton()
        elseif order < 0 and kind == "Q" then
            self.replies = self.replies or {}
            if self.replies[sender] or (self.replyCount or 0) >= 128 then return end
            self.replies[sender] = true
            self.replyCount = (self.replyCount or 0) + 1
            self:Send("R", "WHISPER", sender)
        end
    end
    return notice
end

function GGM.ShowUpdateLink(api)
    if not api.StaticPopupDialogs or type(api.StaticPopup_Show) ~= "function" then return end
    api.StaticPopupDialogs.THE_GUILD_BOOK_UPDATE = {
        text = "Copy this link to update The Guild Book:", button1 = "Close", hasEditBox = true,
        editBoxWidth = 300, timeout = 0, whileDead = true, hideOnEscape = true,
        OnShow = function(dialog)
            local editBox = dialog.editBox or dialog.EditBox
            if editBox then editBox:SetText(URL); editBox:SetFocus(); editBox:HighlightText() end
        end,
        EditBoxOnEscapePressed = function(editBox) editBox:GetParent():Hide() end,
    }
    api.StaticPopup_Show("THE_GUILD_BOOK_UPDATE")
end

local metadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
local version = type(metadata) == "function" and metadata(ADDON_NAME, "Version")
local notice = GGM.CreateUpdateNotice(_G, version)
GGM.updateNotice = notice
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        if C_ChatInfo and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
            local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
            notice.registered = ok and result ~= false
        end
        notice:Announce()
    elseif event == "CHAT_MSG_ADDON" then
        notice:Receive(...)
    else
        notice:Announce()
    end
end)


