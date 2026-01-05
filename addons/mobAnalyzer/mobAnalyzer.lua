local addonName, addonTable = ...

-- --- Configuration ---
-- Initial Window Size
local WINDOW_WIDTH = 250
local WINDOW_HEIGHT = 200

-- --- Variables ---
local playerDPS_Pred = 0
local mobDPS_Pred = 0
local combatStartTime = 0
local initialMobHealth = 0
local initialPlayerHealth = 0
local damageDoneToTarget = 0
local damageTakenFromMob = 0
local lastHitDamage = 0
local inCombatWithTarget = false
local currentTargetGUID = nil

-- --- UI Creation ---
-- Reusing the style from timeUntilLevelUp
local MainFrame = CreateFrame("Frame", "MobAnalyzer_MainFrame", UIParent, "BackdropTemplate")
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
MainFrame:SetBackdropColor(0, 0, 0, 0.8)

-- Title
local TitleText = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
TitleText:SetPoint("TOP", 0, -10)
TitleText:SetText("Mob Analyzer")

-- FontString Helper
local function CreateLabel(offsetY, text)
    local fs = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 10, offsetY)
    fs:SetText(text)
    return fs
end

local NameText = CreateLabel(-30, "Mob: None")
local LevelStateText = CreateLabel(-45, "Diff: N/A")
local SpeedText = CreateLabel(-60, "Speed: N/A")
local CanHoldText = CreateLabel(-75, "Can Hold: N/A")
local TTK_P_M_Text = CreateLabel(-90, "TTK (You->Mob): N/A")
local TTK_M_P_Text = CreateLabel(-105, "TTK (Mob->You): N/A")
local LastHitText = CreateLabel(-120, "Last Hit: 0")
local HitsToDieText = CreateLabel(-135, "Hits Left: N/A")
local StoredTTKText = CreateLabel(-150, "History TTK: N/A")

-- --- Helper Functions ---

local function GetPlayerPredictedDPS()
    local minDmg, maxDmg, offMin, offMax, posMin, posMax, percent = UnitDamage("player")
    local speed, offhandSpeed = UnitAttackSpeed("player")
    
    local avgDmg = (minDmg + maxDmg) / 2
    local dps = 0
    if speed and speed > 0 then
        dps = avgDmg / speed
    end
    
    -- Add offhand if exists (simplified)
    if offhandSpeed and offhandSpeed > 0 then
        local avgOff = (offMin + offMax) / 2
        dps = dps + (avgOff / offhandSpeed)
    end
    
    -- Crude multiplier for stats/crit/ap roughly if not included in UnitDamage (UnitDamage includes AP)
    -- Just raw white hit DPS estimate.
    return dps
end

local function GetMobPredictedDPS(mobLevel)
    -- Very rough estimate as we can't inspect mob stats directly easily without add-on generic DB
    -- Assuming a mob deals damage roughly 2-3x its level per second on average for normal mobs? 
    -- Or we can just use a placeholder.
    if not mobLevel or mobLevel == -1 then mobLevel = UnitLevel("player") + 2 end -- Boss or unknown
    -- Arbitrary formula: Level * 1.5
    return mobLevel * 1.5
end

local function FormatTime(seconds)
    if seconds == math.huge then return "Inf" end
    if seconds <= 0 then return "0s" end
    return string.format("%.1fs", seconds)
end

local function UpdateStaticData()
    if not UnitExists("target") then 
        NameText:SetText("Mob: None")
        MainFrame:Hide()
        return 
    end
    
    MainFrame:Show()
    
    -- Name
    local name = UnitName("target")
    NameText:SetText("Mob: " .. (name or "Unknown"))
    
    -- Difficulty State
    local pLevel = UnitLevel("player")
    local tLevel = UnitLevel("target")
    local diffColor = "Gray"
    
    if tLevel == -1 then
        diffColor = "|cffff0000Boss/Skull|r"
    elseif tLevel >= pLevel + 5 then
        diffColor = "|cffff0000Impossible|r" -- Red
    elseif tLevel >= pLevel + 3 then
        diffColor = "|cffff7700Hard|r" -- Orange
    elseif tLevel >= pLevel - 2 then
         diffColor = "|cffffff00Medium|r" -- Yellow
    else
         diffColor = "|cff00ff00Easy|r" -- Green
    end
    LevelStateText:SetText("Diff: " .. diffColor)
    
    -- Speed %
    -- GetUnitSpeed returns current speed in yds/sec. Base run speed is ~7.
    local pCurrent, pRun, pFlight, pSwim = GetUnitSpeed("player")
    local tCurrent, tRun, tFlight, tSwim = GetUnitSpeed("target")
    
    if pCurrent > 0 then
        local pct = (tCurrent / pCurrent) * 100
        local speedStr = string.format("%.0f%%", pct)
        if pct > 100 then speedStr = "|cffff0000" .. speedStr .. " (Faster)|r"
        elseif pct < 100 then speedStr = "|cff00ff00" .. speedStr .. " (Slower)|r"
        else speedStr = "|cffffff00" .. speedStr .. " (Same)|r" end
        SpeedText:SetText("Speed: " .. speedStr)
    else
        SpeedText:SetText("Speed: ?")
    end
    
    -- Can Hold (Heuristic)
    -- Simplification: Humanoids often have nets/stuns. Spiders have webs.
    -- Better: Just check creature type.
    local cType = UnitCreatureType("target")
    local canHold = "No"
    if cType == "Humanoid" or cType == "Spider" or cType == "Beast" then
        -- This is a very loose guess as requested.
        -- Realistically need a DB of spells. 
        canHold = "|cffffff00Maybe|r" 
    end
    CanHoldText:SetText("Can Hold: " .. canHold)
    
    -- Reset Battle Data if target changed
    local guid = UnitGUID("target")
    if guid ~= currentTargetGUID then
        currentTargetGUID = guid
        inCombatWithTarget = false
        damageDoneToTarget = 0
        damageTakenFromMob = 0
        combatStartTime = 0
        lastHitDamage = 0
        LastHitText:SetText("Last Hit: 0")
        HitsToDieText:SetText("Hits Left: N/A")
        
        -- Predicted TTK (Initial)
        local tMaxHealth = UnitHealthMax("target")
        local pMaxHealth = UnitHealthMax("player")
        local pDPS = GetPlayerPredictedDPS()
        local mDPS = GetMobPredictedDPS(tLevel)
        
        local ttk_P_M = (pDPS > 0) and (tMaxHealth / pDPS) or 0
        local ttk_M_P = (mDPS > 0) and (pMaxHealth / mDPS) or 0
        
        TTK_P_M_Text:SetText(string.format("TTK (You->Mob): ~%s (Pred)", FormatTime(ttk_P_M)))
        TTK_M_P_Text:SetText(string.format("TTK (Mob->You): ~%s (Pred)", FormatTime(ttk_M_P)))
        
        -- Stored TTK
        if MobAnalyzerDB then
             -- Try to unify name/level key
             local tLevelKey = (tLevel > 0) and tostring(tLevel) or "?"
             local key = (UnitName("target") or "Unknown") .. ":" .. tLevelKey
             local stored = MobAnalyzerDB[key]
             if stored then
                 StoredTTKText:SetText(string.format("History TTK: %.1fs", stored))
             else
                 StoredTTKText:SetText("History TTK: N/A")
             end
        else
             StoredTTKText:SetText("History TTK: N/A")
        end
    end
end

local function UpdateLiveTTK()
    if not inCombatWithTarget then return end
    
    local currentTime = GetTime()
    local timeEngaged = currentTime - combatStartTime
    
    if timeEngaged <= 0 then return end
    
    -- TTK You -> Mob
    -- DPS = DamageDone / Time
    -- RemHealth / DPS = RemHealth / (Damage/Time) = (RemHealth * Time) / Damage
    local tHealth = UnitHealth("target")
    if damageDoneToTarget > 0 then
        local myRealDPS = damageDoneToTarget / timeEngaged
        local ttk = tHealth / myRealDPS
        TTK_P_M_Text:SetText(string.format("TTK (You->Mob): %s (Live)", FormatTime(ttk)))
    end
    
    -- TTK Mob -> You
    local pHealth = UnitHealth("player")
    if damageTakenFromMob > 0 then
        local mobRealDPS = damageTakenFromMob / timeEngaged
        local ttk = pHealth / mobRealDPS
        TTK_M_P_Text:SetText(string.format("TTK (Mob->You): %s (Live)", FormatTime(ttk)))
    end
end

-- --- Event Handlers ---

local EventFrame = CreateFrame("Frame")

-- Redefine handler for correct CombatLog parsing
-- Redefine handler for correct CombatLog parsing
EventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == "MobAnalyzer" then
             if not MobAnalyzerDB then MobAnalyzerDB = {} end
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        UpdateStaticData()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, arg12, arg13, arg14, arg15, arg16 = CombatLogGetCurrentEventInfo()
        
        -- Handle Mob Death (Record TTK)
        if subevent == "UNIT_DIED" then
            if currentTargetGUID and destGUID == currentTargetGUID and inCombatWithTarget then
                local duration = GetTime() - combatStartTime
                if duration > 0 then
                    local name = destName
                    -- If destName is nil/unknown, fallback to cached target name?
                    -- Usually destName is reliable in log.
                    local level = UnitLevel("target") 
                    -- UnitLevel("target") might be 0 if dead. 
                    
                    if not name or name == "Unknown" then name = UnitName("target") end
                    
                    if name and level then
                        if not MobAnalyzerDB then MobAnalyzerDB = {} end
                        -- If unit is dead, UnitLevel might be 0, but usually we can still get it or it's unavailable.
                        -- If level is 0/nil, we might skip saving or use a '?' 
                        local levelKey = (level > 0) and tostring(level) or "?"
                        
                        local key = name .. ":" .. levelKey
                        MobAnalyzerDB[key] = duration
                        if StoredTTKText then StoredTTKText:SetText(string.format("History TTK: %.1fs (Saved)", duration)) end
                        print(string.format("MobAnalyzer: Recorded kill for %s (Lvl %s) in %.1fs", name, level, duration))
                    end
                end
                inCombatWithTarget = false
                combatStartTime = 0 
            end
        end

        if not currentTargetGUID then return end
        
        local isSrcPlayer = (sourceGUID == UnitGUID("player"))
        local isDstPlayer = (destGUID == UnitGUID("player"))
        local isSrcTarget = (sourceGUID == currentTargetGUID)
        local isDstTarget = (destGUID == currentTargetGUID)
        
        local amount = 0
        if subevent == "SWING_DAMAGE" then
            amount = arg12
        elseif subevent == "RANGE_DAMAGE" or subevent == "SPELL_DAMAGE" then
            amount = arg15
        end
        
        if amount and amount > 0 then
            -- Player -> Target
            if isSrcPlayer and isDstTarget then
                if not inCombatWithTarget then
                    inCombatWithTarget = true
                    combatStartTime = GetTime()
                end
                damageDoneToTarget = damageDoneToTarget + amount
                lastHitDamage = amount
                LastHitText:SetText("Last Hit: " .. amount)
                
                -- Update Hits to Die
                local tHealth = UnitHealth("target")
                local hitsLeft = math.ceil(tHealth / lastHitDamage)
                HitsToDieText:SetText("Hits Left: " .. hitsLeft)
                
                UpdateLiveTTK()
            
            -- Target -> Player
            elseif isSrcTarget and isDstPlayer then
                if not inCombatWithTarget then
                    inCombatWithTarget = true
                    combatStartTime = GetTime()
                end
                damageTakenFromMob = damageTakenFromMob + amount
                UpdateLiveTTK()
            end
        end
    end
end)

EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
EventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

-- OnUpdate for Live TTK smoothing (optional, doing it on event is cheaper but less frequent updates if DoT/fast attacks vary)
-- But user asked for 'approximate', event based is fine. 
-- However, 'TimeEngaged' logic needs time to pass. Only updating on damage means if I stop attacking, stats freeze. 
-- Let's update TTK every second if in combat.
local timer = 0
EventFrame:SetScript("OnUpdate", function(self, elapsed)
    timer = timer + elapsed
    if timer > 0.5 then
        UpdateLiveTTK()
        timer = 0
    end
end)

-- --- Scaling Feature ---
MainFrame:EnableMouseWheel(true)
MainFrame:SetScript("OnMouseWheel", function(self, delta)
    if IsControlKeyDown() then
        local currentScale = self:GetScale()
        local newScale = currentScale + (delta * 0.1)
        if newScale < 0.5 then newScale = 0.5 end
        if newScale > 3.0 then newScale = 3.0 end
        self:SetScale(newScale)
    end
end)

-- --- Slash Commands ---
SLASH_MOBANALYZER1 = "/ma"
SLASH_MOBANALYZER2 = "/mobanalyzer"
SlashCmdList["MOBANALYZER"] = function(msg)
    local command, rest = msg:match("^(%S*)%s*(.-)$")
    
    if command == "scale" and rest ~= "" then
        local scale = tonumber(rest)
        if scale and scale >= 0.5 and scale <= 3.0 then
            MainFrame:SetScale(scale)
            print("MobAnalyzer: Scale set to " .. scale)
        else
            print("MobAnalyzer: Invalid scale. Use a number between 0.5 and 3.0")
        end
    else
        print("MobAnalyzer Commands:")
        print("  /ma scale <number> - Set the window scale (0.5 to 3.0)")
        print("  Or hold CTRL and scroll mouse wheel over the window.")
    end
end

-- Initial Check
UpdateStaticData()
