local _, GGM = ...

local function text(parent, template, width)
    local label = parent:CreateFontString(nil, "OVERLAY", template)
    label:SetWidth(width)
    label:SetJustifyH("LEFT")
    return label
end

local function refresh(frame)
    if not frame.snapshot then frame:Hide(); return end
    frame.recipeName:SetText(frame.snapshot.name .. "  ×" .. frame.snapshot.amount)
    local titleHeight = math.max(18, frame.recipeName:GetStringHeight())
    local y = 0
    local model = GGM.BuildMaterialTrackingRows(frame.api, frame.snapshot)
    for index, material in ipairs(model) do
        local row = frame.rows[index]
        if not row then
            row = frame.api.CreateFrame("Frame", nil, frame.content)
            row:SetWidth(280)
            row.label = text(row, "GameFontHighlightSmall", 276)
            row.label:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -3)
            frame.rows[index] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, -y)
        row.label:SetText(material.name .. ": " .. (material.owned == nil and "?" or material.owned)
            .. " / " .. material.required)
        if material.complete then row.label:SetTextColor(0.3, 1, 0.3)
        else row.label:SetTextColor(0.94, 0.9, 0.8) end
        local height = math.max(24, row.label:GetStringHeight() + 10)
        row:SetHeight(height)
        row:Show()
        y = y + height
    end
    for index = #model + 1, #frame.rows do frame.rows[index]:Hide() end
    frame.content:SetHeight(math.max(1, y))
    frame.scroll:ClearAllPoints()
    frame.scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -48 - titleHeight)
    frame.scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 33)
    frame:SetHeight(81 + titleHeight + math.min(260, y))
    frame:Show()
end

local function createFrame(api)
    local frame = api.CreateFrame("Frame", "TheGuildBookMaterialTracker", api.UIParent)
    frame.api, frame.rows = api, {}
    frame:SetSize(324, 150)
    frame:SetPoint("TOPRIGHT", api.UIParent, "TOPRIGHT", -70, -250)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame.background = frame:CreateTexture(nil, "BACKGROUND")
    frame.background:SetAllPoints(frame)
    frame.background:SetColorTexture(0.07, 0.055, 0.04, 0.88)
    frame.heading = text(frame, "GameFontNormal", 200)
    frame.heading:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -14)
    frame.heading:SetText("MATERIAL TRACKER")
    frame.recipeName = text(frame, "GameFontNormal", 292)
    frame.recipeName:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -42)
    frame.footer = text(frame, "GameFontDisableSmall", 292)
    frame.footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 12)
    frame.footer:SetText("Bags only · Drag to move · Optional reagents excluded")
    frame.scroll = api.CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    frame.content = api.CreateFrame("Frame", nil, frame.scroll)
    frame.content:SetSize(280, 1)
    frame.scroll:SetScrollChild(frame.content)
    frame.untrackButton = api.CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.untrackButton:SetSize(76, 22)
    frame.untrackButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -9)
    frame.untrackButton:SetText("Untrack")
    frame.untrackButton:SetScript("OnClick", function()
        if GGM.SaveMaterialTracking(api, frame.db, nil) then
            frame.snapshot = nil
            frame:Hide()
        end
    end)
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if not self.snapshot or not self.GetLeft or not self.GetTop then return end
        local position = { x = self:GetLeft(), y = self:GetTop() }
        local candidate = GGM.ValidateMaterialTrackingSnapshot(api, {
            recipeID = self.snapshot.recipeID, name = self.snapshot.name, amount = self.snapshot.amount,
            materials = self.snapshot.materials, position = position,
        })
        if candidate and candidate.position then
            self.snapshot = candidate
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", api.UIParent, "BOTTOMLEFT", position.x, position.y)
            GGM.SaveMaterialTracking(api, self.db, candidate)
        end
    end)
    for _, event in ipairs({ "BAG_UPDATE_DELAYED", "CURRENCY_DISPLAY_UPDATE", "PLAYER_ENTERING_WORLD",
        "PLAYER_REGEN_ENABLED", "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT" }) do
        -- Some supported clients do not expose every modern item/currency event.
        pcall(frame.RegisterEvent, frame, event)
    end
    frame:SetScript("OnEvent", function(self)
        if self.snapshot then refresh(self) end
    end)
    frame:Hide()
    return frame
end

local function showSnapshot(api, db, snapshot)
    local frame = GGM.materialTrackerFrame or createFrame(api)
    GGM.materialTrackerFrame = frame
    frame.db, frame.snapshot = db, snapshot
    frame:ClearAllPoints()
    if snapshot.position then
        frame:SetPoint("TOPLEFT", api.UIParent, "BOTTOMLEFT", snapshot.position.x, snapshot.position.y)
    else
        frame:SetPoint("TOPRIGHT", api.UIParent, "TOPRIGHT", -70, -250)
    end
    frame.scroll:SetVerticalScroll(0)
    refresh(frame)
    return frame
end

function GGM.TrackRecipeMaterials(api, db, recipeID, name, amount, model)
    local saved = GGM.CreateMaterialTrackingSnapshot(api, recipeID, name, amount, model)
    if not saved then return false end
    local previous = GGM.LoadMaterialTracking(api, db)
    saved.position = previous and previous.position
    if not GGM.SaveMaterialTracking(api, db, saved) then return false end
    showSnapshot(api, db, saved)
    return true
end

function GGM.RestoreMaterialTracker(api, db)
    local saved = GGM.LoadMaterialTracking(api, db)
    if saved then return showSnapshot(api, db, saved) end
    if GGM.materialTrackerFrame then
        GGM.materialTrackerFrame.snapshot = nil
        GGM.materialTrackerFrame:Hide()
    end
end
