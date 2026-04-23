local ADDON_NAME, ns = ...
local EarlyPull = ns.EarlyPull

local function makeGetter(key)
    return function() return EarlyPullDB[key] end
end

local function makeSetter(key)
    return function(value)
        EarlyPullDB[key] = value
        EarlyPull:ReloadConfig()
    end
end

local announceValues = {
    {1, "Banner"},
    {2, "Chat"},
    {3, "None"},
}

local function addDropdown(category, key, name, tooltip, values, default)
    local setting = Settings.RegisterProxySetting(category, "EP_"..key,
        Settings.VarType.Number, name, default, makeGetter(key), makeSetter(key))
    local function GetOptions()
        local container = Settings.CreateControlTextContainer()
        for _, v in ipairs(values) do
            container:Add(v[1], v[2])
        end
        return container:GetData()
    end
    Settings.CreateDropdown(category, setting, GetOptions, tooltip)
end

local function addSlider(category, key, name, tooltip, minV, maxV, step, default, format)
    local setting = Settings.RegisterProxySetting(category, "EP_"..key,
        Settings.VarType.Number, name, default, makeGetter(key), makeSetter(key))
    local options = Settings.CreateSliderOptions(minV, maxV, step)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
        format or function(value) return tostring(value) end)
    Settings.CreateSlider(category, setting, options, tooltip)
end

local function addCheckbox(category, key, name, tooltip, default)
    local setting = Settings.RegisterProxySetting(category, "EP_"..key,
        Settings.VarType.Boolean, name, default, makeGetter(key), makeSetter(key))
    Settings.CreateCheckbox(category, setting, tooltip)
end

local function addHeader(layout, title)
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(title))
end

local function BuildPanel()
    local category, layout = Settings.RegisterVerticalLayoutCategory(ADDON_NAME)
    if not layout then
        -- Older/alternate API: fetch layout from panel.
        layout = SettingsPanel:GetLayout(category)
    end

    addHeader(layout, "Announce Options")
    addDropdown(category, "announceEarlyPull",   "Early Pull",   "How to display early pulls. Banner = center-screen raid-warning style; Chat = local chat line; None = disabled.",   announceValues, 1)
    addDropdown(category, "announceOnTimePull",  "On-Time Pull", "How to display on-time pulls.", announceValues, 1)
    addDropdown(category, "announceLatePull",    "Late Pull",    "How to display late pulls.",    announceValues, 1)
    addDropdown(category, "announceUntimedPull", "Untimed Pull", "How to display untimed pulls.", announceValues, 1)
    addSlider(category, "pullTimeDiffDecimals", "Pull Time Diff Decimals",
        "Decimal places to round the pull time diff.", 1, 3, 1, 2,
        function(v) return tostring(v) end)
    addSlider(category, "pullOnTimeWindow", "On-Time Window (seconds)",
        "Two-sided window around 0 considered on-time.", 0, 1, 0.005, 0.005,
        function(v) return format("%.3fs", v) end)
    addSlider(category, "maxPullTimeDiff", "Max Pull Time Diff (seconds)",
        "Maximum pull time diff to announce; otherwise the pull is untimed.", 1, 30, 1, 10,
        function(v) return format("%ds", v) end)
    addCheckbox(category, "autoPrintDetails", "Auto-Print Details",
        "Also print pull blame scores to local chat after each pull.", false)

    Settings.RegisterAddOnCategory(category)
    EarlyPull.settingsCategoryID = category:GetID()
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    if Settings and Settings.RegisterVerticalLayoutCategory then
        BuildPanel()
    end
end)
