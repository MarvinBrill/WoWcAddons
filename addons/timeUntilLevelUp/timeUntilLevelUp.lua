local addonName, addonTable = ...

-- --- Configuration ---
-- Initial Window Size
local WINDOW_WIDTH = 250
local WINDOW_HEIGHT = 150

-- --- Variables ---
local lastXP = 0
local timerRunning = false
local startTime = 0
local startXP = 0

-- --- UI Creation ---
local MainFrame = CreateFrame("Frame", "TULU_MainFrame", UIParent, "BackdropTemplate")
MainFrame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
MainFrame:SetPoint("CENTER")
MainFrame:SetClampedToScreen(true)
MainFrame:EnableMouse(true)
MainFrame:SetMovable(true)
MainFrame:RegisterForDrag("LeftButton")
MainFrame:SetScript("OnDragStart", MainFrame.StartMoving)
MainFrame:SetScript("OnDragStop", MainFrame.StopMovingOrSizing)

-- Background (Dark Transparent)
MainFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
})
MainFrame:SetBackdropColor(0, 0, 0, 0.8) -- R, G, B, Alpha (0.8 = Dark Transparent)

-- Title
local TitleText = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
TitleText:SetPoint("TOP", 0, -10)
TitleText:SetText("Time Until Level Up")

-- Last XP Gain Text
local LastXPText = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
LastXPText:SetPoint("TOPLEFT", 10, -40)
LastXPText:SetText("Last XP: N/A")

-- Chunks Remaining Text
local ChunksText = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ChunksText:SetPoint("TOPLEFT", 10, -60)
ChunksText:SetText("Chunks Left: N/A")

-- Time Until Level Up Text
local TimeText = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
TimeText:SetPoint("TOPLEFT", 10, -80)
TimeText:SetText("Time Left: N/A")

-- XP/Hour Text
local RateText = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
RateText:SetPoint("TOPLEFT", 10, -100)
RateText:SetText("XP/Hr: N/A")

-- Start/Stop Button
local TimerButton = CreateFrame("Button", nil, MainFrame, "GameMenuButtonTemplate")
TimerButton:SetSize(100, 25)
TimerButton:SetPoint("BOTTOM", 0, 10)
TimerButton:SetText("Start Timer")

-- --- Functions ---

local function FormatTime(seconds)
    if seconds <= 0 then return "00:00" end
    local hours = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    if hours > 0 then
        return string.format("%dh %02dm", hours, mins)
    else
        return string.format("%02dm %02ds", mins, math.floor(seconds % 60))
    end
end

local function UpdateXPChunks()
    local currentXP = UnitXP("player")
    local maxXP = UnitXPMax("player")
    local neededXP = maxXP - currentXP
    
    if lastXP == 0 then
        -- First run or just reloaded
        LastXPText:SetText("Last XP: N/A")
        ChunksText:SetText("Chunks Left: N/A")
    else
        local diff = currentXP - lastXP
        if diff > 0 then
            local chunks = math.ceil(neededXP / diff)
            LastXPText:SetText(string.format("Last XP: %d", diff))
            ChunksText:SetText(string.format("Chunks Left: %d", chunks))
        end
    end
    -- Update lastXP for next event, BUT only if we actually gained XP or init
    -- We'll handle the update logic in the event handler to be precise
end

local function OnTimerUpdate()
    if not timerRunning then return end
    
    local currentTime = GetTime()
    local currentXP = UnitXP("player")
    local xpGained = currentXP - startXP
    
    -- Handle Level Up edge case (XP loop) - Simple version: stop buffer if level up happens or just ignore negative
    -- If player leveled up, startXP would be greater than currentXP potentially.
    -- For simplicity, if xpGained < 0, implies level up, we might Reset or just show "Level Up!"
    
    if xpGained < 0 then
         -- Player leveled up likely
         TimeText:SetText("Time Left: Level Up!")
         RateText:SetText("XP/Hr: Done")
         return
    end

    local timeElapsed = currentTime - startTime
    
    if timeElapsed > 0 and xpGained > 0 then
        local xpPerSec = xpGained / timeElapsed
        local maxXP = UnitXPMax("player")
        local remainingXP = maxXP - currentXP
        local secondsLeft = remainingXP / xpPerSec
        
        local xpPerHour = xpPerSec * 3600
        
        TimeText:SetText(string.format("Time Left: %s", FormatTime(secondsLeft)))
        RateText:SetText(string.format("XP/Hr: %d", math.floor(xpPerHour)))
    elseif timeElapsed > 0 then
        TimeText:SetText("Time Left: ...")
        RateText:SetText("XP/Hr: 0")
    end
end

-- --- Event Handlers ---

MainFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        lastXP = UnitXP("player")
    elseif event == "PLAYER_XP_UPDATE" then
        local currentXP = UnitXP("player")
        if currentXP > lastXP then
            -- We gained XP
            UpdateXPChunks()
        end
        -- Always update lastXP after processing
        lastXP = currentXP
    end
end)
MainFrame:RegisterEvent("PLAYER_XP_UPDATE")
MainFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

MainFrame:SetScript("OnUpdate", function(self, elapsed)
    -- Update timer display every 0.5s or so (optional optimization)
    -- For now, every frame is fine but we can throttle
    self.TimeSinceLastUpdate = (self.TimeSinceLastUpdate or 0) + elapsed
    if self.TimeSinceLastUpdate > 0.5 then
        OnTimerUpdate()
        self.TimeSinceLastUpdate = 0
    end
end)

TimerButton:SetScript("OnClick", function()
    if timerRunning then
        -- Stop/Reset
        timerRunning = false
        TimerButton:SetText("Start Timer")
        TimeText:SetText("Time Left: Paused")
    else
        -- Start
        timerRunning = true
        startTime = GetTime()
        startXP = UnitXP("player")
        TimerButton:SetText("Stop Timer")
        TimeText:SetText("Time Left: Calculating...")
        RateText:SetText("XP/Hr: Calculating...")
    end
end)
