local addonName, addonTable = ...

-- --- Configuration ---
local WINDOW_WIDTH = 250
local WINDOW_HEIGHT = 180

-- --- Variables ---
local combatStartTime = 0
local damageDoneToTarget = 0
local damageTakenFromMob = 0
local lastHitDamage = 0
local inCombatWithTarget = false
local currentTargetGUID = nil
local currentSessionDPS = 0

-- --- UI Creation ---
local MainFrame = CreateFrame("Frame", "MobAnalyzer_MainFrame", UIParent, "BackdropTemplate")
MainFrame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
MainFrame:SetPoint("CENTER")
MainFrame:SetClampedToScreen(true)
MainFrame:EnableMouse(true)
MainFrame:SetMovable(true)
MainFrame:RegisterForDrag("LeftButton")
MainFrame:SetScript("OnDragStart", MainFrame.StartMoving)
MainFrame:SetScript("OnDragStop", MainFrame.StopMovingOrSizing)

-- Background
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
    fs:SetText(text or "")
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
local DPSLineText = CreateLabel(-150, "DPS: N/A")

local DPSResetButton = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
DPSResetButton:SetSize(40, 18)
DPSResetButton:SetPoint("LEFT", DPSLineText, "RIGHT", 10, 0)
DPSResetButton:SetText("Reset")

-- --- Helper Functions ---

local function FormatTime(seconds)
    if seconds == math.huge then return "Inf" end
    if seconds <= 0 then return "0s" end
    return string.format("%.1fs", seconds)
end

local function GetPlayerPredictedDPS(targetUnit)
    local minDmg, maxDmg, offMin, offMax, posMin, posMax, percent = UnitDamage("player")
    local speed, offhandSpeed = UnitAttackSpeed("player")
    local avgDmg = (minDmg + maxDmg) / 2
    local dps = (speed and speed > 0) and (avgDmg / speed) or 0
    if offhandSpeed and offhandSpeed > 0 then
        local avgOff = (offMin + offMax) / 2
        dps = dps + (avgOff / offhandSpeed)
    end
    
    -- Ability Multiplier (Auto-Attack is ~40% of standard leveling DPS)
    dps = dps * 2.5

    if targetUnit and UnitExists(targetUnit) then
        local pLevel = UnitLevel("player")
        local tLevel = UnitLevel(targetUnit)
        if tLevel == -1 then tLevel = pLevel + 3 end

        -- 1. Level Difference Impact
        local diff = tLevel - pLevel
        if diff > 0 then
            -- Penalty for glancing blows and misses against higher level
            dps = dps * (1 - (diff * 0.12)) 
        elseif diff < 0 then
            -- Bonus against lower levels
            dps = dps * (1 + (math.min(math.abs(diff), 10) * 0.04))
        end

        -- 2. Armor Mitigation Estimate
        local cType = UnitCreatureType(targetUnit)
        local mitigation = 0.30 -- 30% default
        if cType == "Elemental" or cType == "Mechanical" or cType == "Dragonkin" then
            mitigation = 0.45 -- Higher armor types
        elseif cType == "Humanoid" or cType == "Beast" then
            mitigation = 0.35 -- Standard
        end

        local classification = UnitClassification(targetUnit)
        if classification == "elite" or classification == "worldboss" then
            mitigation = mitigation + 0.15
        end

        dps = dps * (1 - math.min(mitigation, 0.75))
    end

    return math.max(dps, 1)
end

local function GetMobPredictedDPS(targetUnit)
    local level = UnitLevel(targetUnit)
    if not level or level <= 0 then level = UnitLevel("player") end
    
    -- Basic formula: Level * 1.5
    local dps = level * 1.5
    
    local classification = UnitClassification(targetUnit)
    if classification == "elite" or classification == "worldboss" then
        dps = dps * 2.5
    elseif classification == "rare" or classification == "rareelite" then
        dps = dps * 1.5
    end
    
    return dps
end

local function UpdateLiveTTK()
    if not inCombatWithTarget then return end
    local currentTime = GetTime()
    local timeEngaged = currentTime - combatStartTime
    if timeEngaged <= 0 then return end

    -- You -> Mob
    local tHealth = UnitHealth("target")
    if damageDoneToTarget > 0 then
        local myRealDPS = damageDoneToTarget / timeEngaged
        local ttk = tHealth / myRealDPS
        TTK_P_M_Text:SetText(string.format("TTK (You->Mob): %s (Live)", FormatTime(ttk)))
        
        currentSessionDPS = myRealDPS
        DPSLineText:SetText(string.format("DPS: %.1f (Live)", currentSessionDPS))
    end

    -- Mob -> You
    local pHealth = UnitHealth("player")
    if damageTakenFromMob > 0 then
        local mobRealDPS = damageTakenFromMob / timeEngaged
        local ttk = pHealth / mobRealDPS
        TTK_M_P_Text:SetText(string.format("TTK (Mob->You): %s (Live)", FormatTime(ttk)))
    end
end

local function UpdateStaticData()
    if not UnitExists("target") then 
        NameText:SetText("Mob: None")
        MainFrame:Hide()
        return 
    end
    
    MainFrame:Show()
    
    local name = UnitName("target")
    NameText:SetText("Mob: " .. (name or "Unknown"))
    
    local pLevel = UnitLevel("player")
    local tLevel = UnitLevel("target")
    local diffColor = "Gray"
    
    if tLevel == -1 then
        diffColor = "|cffff0000Boss/Skull|r"
    elseif tLevel >= pLevel + 5 then
        diffColor = "|cffff0000Impossible|r"
    elseif tLevel >= pLevel + 3 then
        diffColor = "|cffff7700Hard|r"
    elseif tLevel >= pLevel - 2 then
         diffColor = "|cffffff00Medium|r"
    else
         diffColor = "|cff00ff00Easy|r"
    end
    LevelStateText:SetText("Diff: " .. diffColor)
    
    local pCurrent = GetUnitSpeed("player")
    local tCurrent = GetUnitSpeed("target")
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
    
    local cType = UnitCreatureType("target")
    local canHold = (cType == "Humanoid" or cType == "Spider" or cType == "Beast") and "|cffffff00Maybe|r" or "No"
    CanHoldText:SetText("Can Hold: " .. canHold)
    
    -- Target specific data change
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
        
        -- Predicted initial values
        local tMaxHealth = UnitHealthMax("target")
        local pMaxHealth = UnitHealthMax("player")
        local pDPS = GetPlayerPredictedDPS("target")
        local mDPS = GetMobPredictedDPS("target")
        
        local ttk_P_M = (pDPS > 0) and (tMaxHealth / pDPS) or 0
        local ttk_M_P = (mDPS > 0) and (pMaxHealth / mDPS) or 0
        
        TTK_M_P_Text:SetText(string.format("TTK (Mob->You): ~%s (Pred)", FormatTime(ttk_M_P)))
        
        -- Process History
        if MobAnalyzerDB and MobAnalyzerDB.mobs then
             local levelKey = (tLevel > 0) and tostring(tLevel) or "?"
             local key = (name or "Unknown") .. ":" .. levelKey
             local data = MobAnalyzerDB.mobs[key]
             
             if data then
                 -- TTK You -> Mob: Show (Last) if we have history
                 if data.ttk and data.ttk > 0 then
                    TTK_P_M_Text:SetText(string.format("TTK (You->Mob): ~%s (Last)", FormatTime(data.ttk)))
                 else
                    TTK_P_M_Text:SetText(string.format("TTK (You->Mob): ~%s (Pred)", FormatTime(ttk_P_M)))
                 end
                 
                 -- DPS: Show (Avg) if we have history
                 if data.dps and data.dps > 0 then
                    DPSLineText:SetText(string.format("DPS: %.1f (Avg)", data.dps))
                 else
                    DPSLineText:SetText(string.format("DPS: ~%.1f (Pred)", pDPS))
                 end
             else
                 TTK_P_M_Text:SetText(string.format("TTK (You->Mob): ~%s (Pred)", FormatTime(ttk_P_M)))
                 DPSLineText:SetText(string.format("DPS: ~%.1f (Pred)", pDPS))
             end
        else
             TTK_P_M_Text:SetText(string.format("TTK (You->Mob): ~%s (Pred)", FormatTime(ttk_P_M)))
             DPSLineText:SetText(string.format("DPS: ~%.1f (Pred)", pDPS))
        end
    end
end

-- --- Reset Button Script ---
DPSResetButton:SetScript("OnClick", function()
    if not UnitExists("target") then return end
    local name = UnitName("target")
    local level = UnitLevel("target")
    if name and level then
        local levelKey = (level > 0) and tostring(level) or "?"
        local key = name .. ":" .. levelKey
        if MobAnalyzerDB and MobAnalyzerDB.mobs and MobAnalyzerDB.mobs[key] then
            MobAnalyzerDB.mobs[key].dps = 0
            MobAnalyzerDB.mobs[key].dpsCount = 0
            print("MobAnalyzer: DPS statistics reset for " .. name)
            DPSLineText:SetText("DPS: N/A (Reset)")
        end
    end
end)

-- --- Event Handlers ---
local EventFrame = CreateFrame("Frame")
EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:RegisterEvent("PLAYER_LEVEL_UP")
EventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
EventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

EventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == "MobAnalyzer" then
            if not MobAnalyzerDB then MobAnalyzerDB = {} end
            
            -- DB Structure Migration
            if not MobAnalyzerDB.mobs then
                local newMobs = {}
                for k, v in pairs(MobAnalyzerDB) do
                    if k ~= "playerLevel" and type(v) == "number" then
                        newMobs[k] = { ttk = v, dps = 0, dpsCount = 0 }
                    end
                end
                MobAnalyzerDB = { mobs = newMobs, playerLevel = UnitLevel("player") }
                print("MobAnalyzer: Database version 2 initialized.")
            end
            if not MobAnalyzerDB.playerLevel then MobAnalyzerDB.playerLevel = UnitLevel("player") end
        end
    elseif event == "PLAYER_LEVEL_UP" then
        local newLevel = ...
        if MobAnalyzerDB then
            if MobAnalyzerDB.mobs then
                for k, v in pairs(MobAnalyzerDB.mobs) do
                    v.dps = 0
                    v.dpsCount = 0
                end
                print("MobAnalyzer: Level Up! Mob DPS stats reset.")
            end
            MobAnalyzerDB.playerLevel = newLevel
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        UpdateStaticData()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, arg12, arg13, arg14, arg15, arg16 = CombatLogGetCurrentEventInfo()
        
        -- Recording Death
        if subevent == "UNIT_DIED" then
            if currentTargetGUID and destGUID == currentTargetGUID and inCombatWithTarget then
                local duration = GetTime() - combatStartTime
                local name = destName or UnitName("target")
                local level = UnitLevel("target")
                
                if duration > 0 and name and level then
                    local fightDPS = (damageDoneToTarget > 0) and (damageDoneToTarget / duration) or 0
                    local levelKey = (level > 0) and tostring(level) or "?"
                    local key = name .. ":" .. levelKey
                    
                    if not MobAnalyzerDB then MobAnalyzerDB = { mobs = {} } end
                    if not MobAnalyzerDB.mobs then MobAnalyzerDB.mobs = {} end
                    
                    local data = MobAnalyzerDB.mobs[key] or { ttk = 0, dps = 0, dpsCount = 0 }
                    data.ttk = duration
                    
                    local oldAvg = data.dps or 0
                    local count = data.dpsCount or 0
                    data.dps = ((oldAvg * count) + fightDPS) / (count + 1)
                    data.dpsCount = count + 1
                    
                    MobAnalyzerDB.mobs[key] = data
                    print(string.format("MobAnalyzer: Recorded %s. TTK: %.1fs, DPS: %.1f", name, duration, fightDPS))
                end
                inCombatWithTarget = false
                combatStartTime = 0
                damageDoneToTarget = 0
                damageTakenFromMob = 0
            end
            return
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
            if isSrcPlayer and isDstTarget then
                if not inCombatWithTarget then
                    inCombatWithTarget = true
                    combatStartTime = GetTime()
                end
                damageDoneToTarget = damageDoneToTarget + amount
                lastHitDamage = amount
                LastHitText:SetText("Last Hit: " .. amount)
                local th = UnitHealth("target")
                HitsToDieText:SetText("Hits Left: " .. math.ceil(th / amount))
                UpdateLiveTTK()
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

local timer = 0
EventFrame:SetScript("OnUpdate", function(self, elapsed)
    timer = timer + elapsed
    if timer > 0.5 then
        UpdateLiveTTK()
        timer = 0
    end
end)

-- --- Scaling & Slash Commands ---
MainFrame:EnableMouseWheel(true)
MainFrame:SetScript("OnMouseWheel", function(self, delta)
    if IsControlKeyDown() then
        local s = self:GetScale() + (delta * 0.1)
        self:SetScale(math.max(0.5, math.min(3.0, s)))
    end
end)

SLASH_MOBANALYZER1 = "/ma"
SLASH_MOBANALYZER2 = "/mobanalyzer"
SlashCmdList["MOBANALYZER"] = function(msg)
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    if cmd == "scale" and tonumber(rest) then
        MainFrame:SetScale(math.max(0.5, math.min(3.0, tonumber(rest))))
    else
        print("MobAnalyzer: /ma scale <0.5-3.0>")
    end
end

UpdateStaticData()
