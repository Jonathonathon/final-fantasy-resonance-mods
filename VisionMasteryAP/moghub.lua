local mod, kit = ...

local MASTERY_STRUCT = "VISION_MASTERY_DATA"

-- Mods menu settings (automatically saved to config.ini)
local cfg = mod:settings{
    {
        key = "VisionSpellsMode",
        label = "Vision Spells",
        type = "choice",
        default = "ap10",
        choices = {
            { "disabled",  "Disabled" },
            { "ap10",      "10 AP" },
            { "permanent", "Permanent" },
        },
        help = "Disabled: vanilla Visions. 10 AP: Vision spells unlock via Synchro Mastery for 10 AP each. Permanent: Vision spells are auto-learned permanently once unlocked (0 AP, no slot used).",
    },
    {
        key = "AwakeningAbilitiesMode",
        label = "Awakening Abilities",
        type = "choice",
        default = "off",
        choices = {
            { "off",        "Off" },
            { "equippable", "Equippable" },
        },
        help = "Off: Awakening Level passive abilities only apply while that Vision is equipped (vanilla). Equippable: Unlocked Awakening Level abilities can be equipped individually in Equipment & Abilities at their inherited AP cost, and are also included when equipping a full Vision Master Skill (at unchanged AP cost).",
    },
}

-- Per-save-slot store tracking skills granted by Permanent mode so toggling to
-- 10 AP / Disabled can cleanly revert them even after a game restart.
local grantStore = mod:store("GrantedVisionSpells")

local TARGET_SLV = { [0] = 1, [1] = 3, [2] = 5, [3] = 7, [4] = 9, [5] = 10 }

local lastAppliedMode = nil
local lastAppliedAwkMode = nil
local lastAwakeningKey = nil
local needsPermSync = true
local origSynchro = {}              -- key -> { paramType, param1 }
local origSkill = {}                -- skillId -> { equipCost, isRemovable, hasUnit, cmds = {...} }
local origPassive = {}              -- passiveSkillId -> { equipCost, isRemovable }
local cachedVisionSpells = {}       -- vid -> { [awkLv] = { { paramType, skillId }, ... } }
local cachedAwakeningPassives = {}  -- vid -> { [awkLv] = { { paramType, skillId }, ... } }
local cachedSynchroSpells = {}      -- vid -> { [slv] = { { paramType, skillId }, ... } } (vanilla Synchro ActiveSkills)
local cachedAwakeningReq = {}       -- vid -> { [awkLv] = masteryPoint }
local cachedAllVisionSkills = {}    -- skillId -> paramType (spells only, never Awakening passives)
local cachedAllAwakeningPassives = {} -- passiveSkillId -> true
local injectedByVision = {}         -- vid -> { [skillId] = true }
local injectedAny = {}              -- all injected skillIds across all Visions
local injectedExclusive = {}        -- injected skillIds that NEVER appear in any vanilla Synchro table
local hiddenEntryWidgets = {}       -- widgetAddr -> true (for unhiding recycled widgets)
local cachedSynchroReq = {}         -- vid -> { [slv] = masteryPoint }
local cachedMaxSynchroLv = {}       -- vid -> highest slv in Synchro table (e.g. MR 9)

local function getActiveMode()
    if not mod.enabled then return "disabled" end
    return cfg.VisionSpellsMode or "ap10"
end

local function getActiveAwakeningMode()
    if not mod.enabled then return "off" end
    return cfg.AwakeningAbilitiesMode or "off"
end

local function ensureGrantTables()
    if type(grantStore.data) ~= "table" then grantStore.data = {} end
    if type(grantStore.data.active) ~= "table" then grantStore.data.active = {} end
    if type(grantStore.data.passive) ~= "table" then grantStore.data.passive = {} end
    return grantStore.data.active, grantStore.data.passive
end

local function saveGrantStore()
    local slot = grantStore.slot or (kit.events and kit.events.slot)
    if slot ~= nil then
        grantStore:save(slot)
    end
end

local function arrayContains(arr, targetId)
    if not arr then return false end
    for i = 1, #arr do
        if arr[i] == targetId then return true end
    end
    return false
end

local function arrayAddUnique(arr, targetId)
    if not arr or arrayContains(arr, targetId) then return false end
    arr[#arr + 1] = targetId
    return true
end

local function arrayRemoveSet(arr, removeSet)
    if not arr then return 0 end
    local kept = {}
    local removed = 0
    for i = 1, #arr do
        local v = arr[i]
        if removeSet[v] then
            removed = removed + 1
        else
            kept[#kept + 1] = v
        end
    end
    if removed == 0 then return 0 end
    arr:Empty()
    for i, v in ipairs(kept) do
        arr[i] = v
    end
    return removed
end

-- Clean Vision spells AND excess trailing -1 empty slots out of SaveData_UnitParameter.equipSkillList,
-- compacting it back to normal capacity (min 8 slots padded with -1).
local function cleanEquipSkillList(arr, removeSet)
    if not arr then return 0 end
    local kept = {}
    local removed = 0
    local origLen = #arr
    for i = 1, origLen do
        local v = arr[i]
        if v == -1 or v == 0 then
            -- drop empty placeholders; we will re-pad cleanly to min 8 slots below
        elseif removeSet[v] then
            removed = removed + 1
        else
            kept[#kept + 1] = v
        end
    end
    local targetLen = math.max(8, #kept)
    if removed == 0 and origLen == targetLen then return 0 end
    arr:Empty()
    for i = 1, targetLen do
        arr[i] = kept[i] or -1
    end
    return removed
end

-- Read a unit's synchro points for a SaveData_Vision entry (TMap<int32, int32>)
local function getUnitSynchroPoints(visionEntry, unitId)
    local pts = 0
    pcall(function()
        local spMap = visionEntry.synchroPoints
        if not spMap then return end
        local okF, found = pcall(function() return spMap:Find(unitId) end)
        if okF and found then
            local okG, val = pcall(function() return found:get() end)
            if okG and type(val) == "number" then pts = val; return end
            if type(found) == "number" then pts = found; return end
        end
        local okI, val = pcall(function() return spMap[unitId] end)
        if okI and type(val) == "number" then pts = val; return end
        pcall(function()
            spMap:ForEach(function(k, v)
                if k:get() == unitId then
                    pts = v:get()
                end
            end)
        end)
    end)
    return pts
end

-- Returns a map of vid -> awakeningPoint from current SaveData, plus a signature string
-- so we detect immediately when the player upgrades a Vision's Awakening with Mog.
local function getVisionAwakeningPoints()
    local map = {}
    local parts = {}
    local sd = kit.game and kit.game.saveData and kit.game.saveData()
    if kit.valid(sd) then
        pcall(function()
            local visions = sd.visionList
            if not visions then return end
            for i = 1, #visions do
                local v = visions[i]
                local vid = v.ID
                local ap = v.awakeningPoint or 0
                if vid and vid > 0 then
                    map[vid] = ap
                    parts[#parts + 1] = tostring(vid) .. "=" .. tostring(ap)
                end
            end
        end)
    end
    table.sort(parts)
    return map, table.concat(parts, ",")
end

local function isAwakeningUnlocked(awkPointsMap, reqMap, vid, awkLv)
    local ap = awkPointsMap[vid]
    if ap == nil then return false end
    local req = reqMap[vid] and reqMap[vid][awkLv]
    if req == nil then return false end
    return ap >= req
end

-- Push SaveData_UnitParameter skill/equip changes into live CPP_UnitParameter instances
-- and notify UI ViewModels (EquippedSkillsVM / Skills) immediately.
local function refreshLiveUnits(unitIds)
    pcall(function()
        local storage = FindFirstOf("CPP_MapUnitParameterStorage")
        if kit.valid(storage) and storage.m_UnitParameterList then
            for i = 1, #storage.m_UnitParameterList do
                local p = storage.m_UnitParameterList[i]
                if kit.valid(p) then
                    pcall(function() p:UpdateSkillList() end)
                end
            end
        end
    end)
    pcall(function()
        local bfl = kit.game and kit.game.lib and kit.game.lib("CPP_BFL_Unit")
        if kit.valid(bfl) and unitIds then
            for _, uid in ipairs(unitIds) do
                pcall(function()
                    local p = bfl:GetPlayableUnitParameterObj(uid)
                    if kit.valid(p) then p:UpdateSkillList() end
                end)
                pcall(function() bfl:ExecuteUnitActionUpdate(uid) end)
            end
        end
    end)
end

-- In Permanent mode: grant unlocked Vision spells directly into each unit's innate
-- activeSkillIdList / passiveSkillIdList (0 AP, never shown on Equipment & Abilities),
-- clean Vision spells + excess -1 slots out of SaveData.equipSkillList, and sync live
-- CPP_UnitParameter objects immediately via UpdateSkillList + ExecuteUnitActionUpdate.
local function syncPermanentVisionSkills()
    local sd = kit.game and kit.game.saveData and kit.game.saveData()
    if not kit.valid(sd) then return end

    local mode = getActiveMode()
    local awkMode = getActiveAwakeningMode()
    local gActive, gPassive = ensureGrantTables()

    if mode ~= "permanent" then
        local reverted = 0
        local strippedAwk = 0
        local touchedUnits = {}
        local needAwkStrip = (awkMode == "off" and next(cachedAllAwakeningPassives) ~= nil)
        if next(gActive) or next(gPassive) or needAwkStrip then
            pcall(function()
                local units = sd.unitParameterList
                for i = 1, #units do
                    local u = units[i]
                    local uid = u.UnitId
                    local uKey = tostring(uid)
                    local changed = false
                    if gActive[uKey] then
                        local rem = {}
                        for sidStr in pairs(gActive[uKey]) do
                            local sid = tonumber(sidStr)
                            if sid then rem[sid] = true end
                        end
                        local n = arrayRemoveSet(u.activeSkillIdList, rem)
                        if n > 0 then reverted = reverted + n; changed = true end
                        gActive[uKey] = nil
                    end
                    if gPassive[uKey] then
                        local rem = {}
                        for sidStr in pairs(gPassive[uKey]) do
                            local sid = tonumber(sidStr)
                            if sid then rem[sid] = true end
                        end
                        local n = arrayRemoveSet(u.passiveSkillIdList, rem)
                        if n > 0 then reverted = reverted + n; changed = true end
                        gPassive[uKey] = nil
                    end
                    if needAwkStrip then
                        local n = cleanEquipSkillList(u.equipSkillList, cachedAllAwakeningPassives)
                        if n > 0 then strippedAwk = strippedAwk + n; changed = true end
                    end
                    if changed and uid and uid > 0 then
                        touchedUnits[#touchedUnits + 1] = uid
                    end
                end
            end)
            if next(gActive) or next(gPassive) or reverted > 0 then
                grantStore.data.active = {}
                grantStore.data.passive = {}
                saveGrantStore()
            end
            if reverted > 0 or strippedAwk > 0 then
                refreshLiveUnits(touchedUnits)
                mod:log(string.format("Reverted %d permanent Vision spells, cleaned %d Awakening passives (mode='%s', awk='%s').", reverted, strippedAwk, mode, awkMode))
            end
        end
        needsPermSync = false
        return
    end

    if not next(cachedVisionSpells) then return end

    local awkPointsMap = getVisionAwakeningPoints()
    local addedCount, strippedEquipCount, revokedCount = 0, 0, 0
    local allUnitIds = {}
    local storeDirty = false

    pcall(function()
        local units = sd.unitParameterList
        local visions = sd.visionList
        if not units or not visions then return end

        for ui = 1, #units do
            local u = units[ui]
            local uid = u.UnitId
            if uid and uid > 0 then
                allUnitIds[#allUnitIds + 1] = uid
                local uKey = tostring(uid)
                gActive[uKey] = gActive[uKey] or {}
                gPassive[uKey] = gPassive[uKey] or {}

                local unlocked = {}

                for vi = 1, #visions do
                    local v = visions[vi]
                    local vid = v.ID
                    if cachedSynchroReq[vid] then
                        local pts = getUnitSynchroPoints(v, uid)
                        if pts and pts > 0 then
                            if cachedVisionSpells[vid] then
                                local maxSlv = cachedMaxSynchroLv[vid] or 9
                                for awkLv, spells in pairs(cachedVisionSpells[vid]) do
                                    local slv = math.min(TARGET_SLV[awkLv] or maxSlv, maxSlv)
                                    local req = cachedSynchroReq[vid][slv] or cachedSynchroReq[vid][maxSlv]
                                    if req and pts >= req
                                        and isAwakeningUnlocked(awkPointsMap, cachedAwakeningReq, vid, awkLv) then
                                        for _, sp in ipairs(spells) do
                                            unlocked[sp.skillId] = sp.paramType
                                        end
                                    end
                                end
                            end

                            if cachedSynchroSpells[vid] then
                                for slv, spells in pairs(cachedSynchroSpells[vid]) do
                                    local req = cachedSynchroReq[vid][slv]
                                    if req and pts >= req then
                                        for _, sp in ipairs(spells) do
                                            unlocked[sp.skillId] = sp.paramType
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                local remA, remP = {}, {}
                for sidStr in pairs(gActive[uKey]) do
                    local sid = tonumber(sidStr)
                    if sid and not unlocked[sid] then
                        remA[sid] = true
                        gActive[uKey][sidStr] = nil
                        storeDirty = true
                    end
                end
                for sidStr in pairs(gPassive[uKey]) do
                    local sid = tonumber(sidStr)
                    if sid and not unlocked[sid] then
                        remP[sid] = true
                        gPassive[uKey][sidStr] = nil
                        storeDirty = true
                    end
                end
                if next(remA) then revokedCount = revokedCount + arrayRemoveSet(u.activeSkillIdList, remA) end
                if next(remP) then revokedCount = revokedCount + arrayRemoveSet(u.passiveSkillIdList, remP) end

                for sid, ptype in pairs(unlocked) do
                    local sidStr = tostring(sid)
                    if ptype == 2 then
                        if arrayAddUnique(u.passiveSkillIdList, sid) then
                            gPassive[uKey][sidStr] = true
                            addedCount = addedCount + 1
                            storeDirty = true
                        end
                    else
                        if arrayAddUnique(u.activeSkillIdList, sid) then
                            gActive[uKey][sidStr] = true
                            addedCount = addedCount + 1
                            storeDirty = true
                        end
                    end
                end

                strippedEquipCount = strippedEquipCount + cleanEquipSkillList(u.equipSkillList, cachedAllVisionSkills)
                if awkMode == "off" and next(cachedAllAwakeningPassives) then
                    strippedEquipCount = strippedEquipCount + cleanEquipSkillList(u.equipSkillList, cachedAllAwakeningPassives)
                end
            end
        end
    end)

    needsPermSync = false
    if storeDirty then
        saveGrantStore()
    end
    if #allUnitIds > 0 then
        refreshLiveUnits(allUnitIds)
    end
    if addedCount > 0 or strippedEquipCount > 0 or revokedCount > 0 then
        mod:log(string.format(
            "Permanent Vision Spells synced: %d innate added, %d cleaned from equipSkillList, %d locked revoked (live units refreshed).",
            addedCount, strippedEquipCount, revokedCount
        ))
    end
end

local function applyPatches(force)
    local mode = getActiveMode()
    local awkMode = getActiveAwakeningMode()
    local awkPointsMap, awkKey = getVisionAwakeningPoints()
    if not force and lastAppliedMode == mode and lastAppliedAwkMode == awkMode and lastAwakeningKey == awkKey then
        if needsPermSync then
            syncPermanentVisionSkills()
        end
        return
    end

    local visionSpells = {}
    local awakeningPassives = {}
    local synchroSpells = {}
    local awakeningReq = {}
    local allVisionSkillIds = {}
    local allAwakeningPassiveIds = {}
    local synchroReq = {}
    local maxSynchroLv = {}
    local foundAwakening = false

    -- Step 1: Gather Awakening spells (ActiveSkills) and Awakening passive abilities (PassiveSkills)
    -- along with masteryPoint thresholds from Awakening tables.
    kit.tables.rows(MASTERY_STRUCT, function(row, rowName, tbl)
        if not tbl.path:find("Awakening") then return end
        foundAwakening = true
        local vid = row.ID
        local awkLv = row.Level
        visionSpells[vid] = visionSpells[vid] or {}
        visionSpells[vid][awkLv] = visionSpells[vid][awkLv] or {}
        awakeningPassives[vid] = awakeningPassives[vid] or {}
        awakeningPassives[vid][awkLv] = awakeningPassives[vid][awkLv] or {}
        awakeningReq[vid] = awakeningReq[vid] or {}
        awakeningReq[vid][awkLv] = row.masteryPoint or 0

        local details = row.detailData
        for i = 1, #details do
            local d = details[i]
            local sid = d.params[1]
            local ptype = d.parameterType
            if sid and sid > 0 then
                if ptype == 2 then
                    -- Awakening Level passive ability (e.g. Spellblade Mastery, Spellblade Wielder)
                    table.insert(awakeningPassives[vid][awkLv], { paramType = ptype, skillId = sid })
                    allAwakeningPassiveIds[sid] = true
                elseif sid >= 200000 then
                    -- Awakening Level spell / active skill
                    table.insert(visionSpells[vid][awkLv], { paramType = ptype, skillId = sid })
                    allVisionSkillIds[sid] = ptype
                end
            end
        end
    end)

    if not foundAwakening then return end

    -- Step 2: Restore Synchro Mastery tables to vanilla and collect thresholds / vanilla ActiveSkills.
    -- - When VisionSpellsMode == 'ap10': inject unlocked Awakening spells into Synchro rows.
    -- - When AwakeningAbilitiesMode == 'equippable': inject unlocked Awakening passive abilities
    --   into Synchro rows so they become individually equippable in Equipment & Abilities (at their
    --   inherited AP cost) AND automatically included when equipping a full Vision Master Skill
    --   (at unchanged AP cost).
    local newInjectedByVision = {}
    local newInjectedAny = {}
    local vanillaSynchroAny = {}
    local existingSynchroSkills = {} -- vid -> { [skillId] = true }
    kit.tables.rows(MASTERY_STRUCT, function(row, rowName, tbl)
        if not tbl.path:find("Synchro") then return end
        local vid = row.ID
        local slv = row.Level
        synchroReq[vid] = synchroReq[vid] or {}
        synchroReq[vid][slv] = row.masteryPoint
        if not maxSynchroLv[vid] or slv > maxSynchroLv[vid] then
            maxSynchroLv[vid] = slv
        end
        existingSynchroSkills[vid] = existingSynchroSkills[vid] or {}

        local details = row.detailData

        -- Snapshot original slot values once and restore them before applying the new mode
        for i = 1, #details do
            local key = tbl.path .. "|" .. tostring(rowName) .. "|" .. tostring(i)
            if not origSynchro[key] then
                origSynchro[key] = { paramType = details[i].parameterType, param1 = details[i].params[1] }
            else
                details[i].parameterType = origSynchro[key].paramType
                details[i].params[1] = origSynchro[key].param1
            end

            local op = origSynchro[key]
            if op.param1 and op.param1 > 0 then
                existingSynchroSkills[vid][op.param1] = true
                vanillaSynchroAny[op.param1] = true
            end
            -- Record vanilla Synchro ActiveSkills (parameterType == 1, e.g. Deathblow)
            if op.paramType == 1 and op.param1 and op.param1 >= 200000 then
                synchroSpells[vid] = synchroSpells[vid] or {}
                synchroSpells[vid][slv] = synchroSpells[vid][slv] or {}
                table.insert(synchroSpells[vid][slv], { paramType = op.paramType, skillId = op.param1 })
                allVisionSkillIds[op.param1] = op.paramType
            end
        end
    end)

    -- Build per-Vision/level injection queues and inject into available -1 Synchro slots
    local injectQueues = {} -- vid -> { [targetSlv] = { { paramType, skillId }, ... } }
    local injectSpill = {}  -- vid -> { { paramType, skillId }, ... }
    local injectedPassivesCount = 0

    local function queueItem(vid, targetSlv, item)
        if existingSynchroSkills[vid] and existingSynchroSkills[vid][item.skillId] then return end
        existingSynchroSkills[vid] = existingSynchroSkills[vid] or {}
        existingSynchroSkills[vid][item.skillId] = true
        injectQueues[vid] = injectQueues[vid] or {}
        injectQueues[vid][targetSlv] = injectQueues[vid][targetSlv] or {}
        table.insert(injectQueues[vid][targetSlv], item)
    end

    if mode == "ap10" then
        for vid, byLv in pairs(visionSpells) do
            local maxSlv = maxSynchroLv[vid] or 9
            for awkLv, spells in pairs(byLv) do
                if isAwakeningUnlocked(awkPointsMap, awakeningReq, vid, awkLv) then
                    local target = math.min(TARGET_SLV[awkLv] or maxSlv, maxSlv)
                    for _, sp in ipairs(spells) do
                        queueItem(vid, target, sp)
                    end
                end
            end
        end
    end

    if awkMode == "equippable" then
        for vid, byLv in pairs(awakeningPassives) do
            local maxSlv = maxSynchroLv[vid] or 9
            for awkLv, passives in pairs(byLv) do
                if isAwakeningUnlocked(awkPointsMap, awakeningReq, vid, awkLv) then
                    local target = math.min(TARGET_SLV[awkLv] or maxSlv, maxSlv)
                    for _, pa in ipairs(passives) do
                        queueItem(vid, target, pa)
                    end
                end
            end
        end
    end

    if next(injectQueues) then
        -- Pass 1: place each item into its target Synchro level row
        kit.tables.rows(MASTERY_STRUCT, function(row, rowName, tbl)
            if not tbl.path:find("Synchro") then return end
            local vid = row.ID
            local slv = row.Level
            local q = injectQueues[vid] and injectQueues[vid][slv]
            if not q or #q == 0 then return end
            local details = row.detailData
            local idx = 1
            for i = 1, #details do
                if idx <= #q and details[i].params[1] == -1 then
                    local item = q[idx]
                    details[i].parameterType = item.paramType
                    details[i].params[1] = item.skillId
                    newInjectedByVision[vid] = newInjectedByVision[vid] or {}
                    newInjectedByVision[vid][item.skillId] = true
                    newInjectedAny[item.skillId] = true
                    if item.paramType == 2 then injectedPassivesCount = injectedPassivesCount + 1 end
                    idx = idx + 1
                end
            end
            if idx <= #q then
                injectSpill[vid] = injectSpill[vid] or {}
                for k = idx, #q do
                    table.insert(injectSpill[vid], q[k])
                end
            end
        end)

        -- Pass 2: if a target row had no free -1 slots left, spill into any open -1 slot on that Vision
        if next(injectSpill) then
            kit.tables.rows(MASTERY_STRUCT, function(row, rowName, tbl)
                if not tbl.path:find("Synchro") then return end
                local vid = row.ID
                local spill = injectSpill[vid]
                if not spill or #spill == 0 then return end
                local details = row.detailData
                for i = 1, #details do
                    if #spill == 0 then break end
                    if details[i].params[1] == -1 then
                        local item = table.remove(spill, 1)
                        details[i].parameterType = item.paramType
                        details[i].params[1] = item.skillId
                        newInjectedByVision[vid] = newInjectedByVision[vid] or {}
                        newInjectedByVision[vid][item.skillId] = true
                        newInjectedAny[item.skillId] = true
                        if item.paramType == 2 then injectedPassivesCount = injectedPassivesCount + 1 end
                    end
                end
            end)
        end
    end

    local newInjectedExclusive = {}
    for sid in pairs(newInjectedAny) do
        if not vanillaSynchroAny[sid] then
            newInjectedExclusive[sid] = true
        end
    end

    cachedVisionSpells = visionSpells
    cachedAwakeningPassives = awakeningPassives
    cachedSynchroSpells = synchroSpells
    cachedAwakeningReq = awakeningReq
    cachedAllVisionSkills = allVisionSkillIds
    cachedAllAwakeningPassives = allAwakeningPassiveIds
    injectedByVision = newInjectedByVision
    injectedAny = newInjectedAny
    injectedExclusive = newInjectedExclusive
    cachedSynchroReq = synchroReq
    cachedMaxSynchroLv = maxSynchroLv

    -- Step 3: Find the standard command list ID from a universal spell (Meteor 210190 / Fire 210010)
    -- so Vision-exclusive active skills (like Sacred Wave) also appear in every character's Skills list
    local stdCmdId = nil
    pcall(function()
        kit.tables.rows("SKILL_DATA", function(row)
            if stdCmdId then return end
            local id = row.ID
            if id == 210190 or id == 210010 then
                local cmds = row.belongCommandList
                if cmds and #cmds > 0 then
                    stdCmdId = cmds[1]
                end
            end
        end)
    end)

    -- Step 4: Patch (or restore) SKILL_DATA equipCost, isRemovable, hasUnit, and belongCommandList
    local patchedSkills = 0
    pcall(function()
        kit.tables.rows("SKILL_DATA", function(row)
            local id = row.ID
            if not allVisionSkillIds[id] then return end

            if not origSkill[id] then
                local origCmds = {}
                pcall(function()
                    if row.belongCommandList then
                        for i = 1, #row.belongCommandList do
                            origCmds[i] = row.belongCommandList[i]
                        end
                    end
                end)
                origSkill[id] = {
                    equipCost = row.equipCost,
                    isRemovable = row.isRemovable,
                    hasUnit = row.hasUnit,
                    cmds = origCmds,
                }
            end

            if mode == "disabled" then
                pcall(function() row.equipCost = origSkill[id].equipCost end)
                pcall(function() row.isRemovable = origSkill[id].isRemovable end)
                pcall(function() row.hasUnit = origSkill[id].hasUnit end)
                pcall(function()
                    local cmds = row.belongCommandList
                    if cmds and origSkill[id].cmds then
                        cmds:Empty()
                        for i, c in ipairs(origSkill[id].cmds) do
                            cmds[i] = c
                        end
                    end
                end)
            else
                if mode == "ap10" then
                    pcall(function() row.equipCost = 10 end)
                else
                    pcall(function() row.equipCost = origSkill[id].equipCost end)
                end
                pcall(function() row.isRemovable = true end)
                -- Ensure any character can use the Vision spell once unlocked via Synchro Mastery
                pcall(function()
                    if row.hasUnit ~= 10 then
                        row.hasUnit = 10 -- ePlayableUnit::All
                    end
                end)
                -- Ensure the spell is included in the standard Skills command list
                -- (replace -1 placeholder slots such as Sacred Wave's cmds=[-1])
                if stdCmdId then
                    pcall(function()
                        local cmds = row.belongCommandList
                        if cmds then
                            local hasStd = false
                            local emptySlot = nil
                            for i = 1, #cmds do
                                if cmds[i] == stdCmdId then
                                    hasStd = true
                                    break
                                elseif not emptySlot and cmds[i] == -1 then
                                    emptySlot = i
                                end
                            end
                            if not hasStd then
                                if emptySlot then
                                    cmds[emptySlot] = stdCmdId
                                else
                                    cmds[#cmds + 1] = stdCmdId
                                end
                            end
                        end
                    end)
                end
                patchedSkills = patchedSkills + 1
            end
        end)
    end)

    -- Step 4b: For Awakening passive abilities, preserve inherited equipCost and ensure
    -- isRemovable = true when Equippable mode is enabled (restore vanilla when Off).
    local patchedPassives = 0
    local samplePassiveCosts = {}
    pcall(function()
        kit.tables.rows("PASSIVE_SKILL_DATA", function(row)
            local id = row.ID
            if not allAwakeningPassiveIds[id] then return end

            if not origPassive[id] then
                origPassive[id] = {
                    equipCost = row.equipCost,
                    isRemovable = row.isRemovable,
                }
            end

            if awkMode == "equippable" then
                pcall(function() row.equipCost = origPassive[id].equipCost end)
                pcall(function() row.isRemovable = true end)
                patchedPassives = patchedPassives + 1
                if #samplePassiveCosts < 6 then
                    samplePassiveCosts[#samplePassiveCosts + 1] = tostring(id) .. "=" .. tostring(origPassive[id].equipCost) .. "AP"
                end
            else
                pcall(function() row.equipCost = origPassive[id].equipCost end)
                pcall(function() row.isRemovable = origPassive[id].isRemovable end)
            end
        end)
    end)

    lastAppliedMode = mode
    lastAppliedAwkMode = awkMode
    lastAwakeningKey = awkKey
    needsPermSync = true
    syncPermanentVisionSkills()
    -- If Awakening Abilities mode changed while a save is loaded (including in 10 AP / Disabled
    -- Vision Spells modes), refresh live CPP_UnitParameter instances so full Vision Master Skills
    -- and Equipment & Abilities pick up the updated Synchro Mastery table immediately.
    pcall(function()
        local sd = kit.game and kit.game.saveData and kit.game.saveData()
        if kit.valid(sd) and sd.unitParameterList then
            local uids = {}
            for i = 1, #sd.unitParameterList do
                local uid = sd.unitParameterList[i].UnitId
                if uid and uid > 0 then uids[#uids + 1] = uid end
            end
            if #uids > 0 then refreshLiveUnits(uids) end
        end
    end)

    local sampleStr = #samplePassiveCosts > 0 and (" [" .. table.concat(samplePassiveCosts, ", ") .. "]") or ""
    mod:log(string.format(
        "Vision Spells='%s' (%d skills, stdCmd=%s) | Awakening Abilities='%s' (%d passives injected, %d passive rows%s).",
        mode, patchedSkills, tostring(stdCmdId), awkMode, injectedPassivesCount, patchedPassives, sampleStr
    ))
end

mod:every(1000, function() applyPatches(false) end, "applyPatches")
mod:on("loadingEnd", function()
    lastAppliedMode = nil
    lastAppliedAwkMode = nil
    lastAwakeningKey = nil
    needsPermSync = true
    applyPatches(true)
end)
mod:on("saveLoaded", function()
    lastAppliedMode = nil
    lastAppliedAwkMode = nil
    lastAwakeningKey = nil
    needsPermSync = true
    applyPatches(true)
end)
mod:on("battleEnd", function()
    needsPermSync = true
    syncPermanentVisionSkills()
end)
mod:onToggle(function()
    lastAppliedMode = nil
    lastAppliedAwkMode = nil
    lastAwakeningKey = nil
    needsPermSync = true
    applyPatches(true)
end)
cfg:onChange(function(key, value)
    if key == "VisionSpellsMode" then
        lastAppliedMode = nil
        lastAwakeningKey = nil
        needsPermSync = true
        applyPatches(true)
        local labels = { disabled = "Disabled", ap10 = "10 AP", permanent = "Permanent (Auto-Learned)" }
        mod:notice("Vision Spells: " .. (labels[value] or tostring(value)), "on", 1800)
    elseif key == "AwakeningAbilitiesMode" then
        lastAppliedAwkMode = nil
        lastAwakeningKey = nil
        needsPermSync = true
        applyPatches(true)
        local labels = { off = "Off (Vanilla)", equippable = "Equippable (Individual & Full Vision)" }
        mod:notice("Awakening Abilities: " .. (labels[value] or tostring(value)), "on", 1800)
    end
end)

-- =========================================================================
-- Hide Injected Spell Entries in Synchro Mastery UI (Pause Menu & Level Up)
-- =========================================================================
-- Strips injected Awakening spell entries (and their spacers) out of each
-- WBP_VisionSynchroMasteryList_C's DirectionGridPanel, scoped per VisionId so
-- vanilla Synchro Mastery skills on other Visions are never hidden.

local function readSkillIdFromWidget(w)
    if not kit.valid(w) then return 0 end
    local sid = 0
    pcall(function()
        if type(w.m_SkillId) == "number" and w.m_SkillId > 0 then
            sid = w.m_SkillId
            return
        end
        for _, vmField in ipairs({ "CPP_VM_VisionMasteryData", "CPP_VM_MasteryData" }) do
            local vm = w[vmField]
            if kit.valid(vm) and kit.valid(vm.SkillDataVM) then
                local id = vm.SkillDataVM.SkillId
                if type(id) == "number" and id > 0 then
                    sid = id
                    return
                end
            end
        end
    end)
    return sid
end

local function getEntrySkillId(entry)
    local sid = readSkillIdFromWidget(entry)
    if sid > 0 then return sid end

    pcall(function()
        if kit.ui and kit.ui.walk and entry.WidgetTree and kit.valid(entry.WidgetTree.RootWidget) then
            kit.ui.walk(entry.WidgetTree.RootWidget, function(w)
                local id = readSkillIdFromWidget(w)
                if id > 0 then
                    sid = id
                    return true
                end
                return false
            end)
        end
    end)
    return sid
end

local function getListVisionId(listW)
    local vid = 0
    pcall(function()
        if type(listW.VisionId) == "number" and listW.VisionId > 0 then
            vid = listW.VisionId
            return
        end
        for _, field in ipairs({ "CPP_VM_VisionSynchroMasteryList", "VM_VisionSynchroMasteryList", "CPP_VM_VisionMasteryList" }) do
            local vm = listW[field]
            if kit.valid(vm) and type(vm.VisionId) == "number" and vm.VisionId > 0 then
                vid = vm.VisionId
                return
            end
        end
    end)
    return vid
end

local function getEntryVisionId(entry)
    local vid = getListVisionId(entry)
    if vid > 0 then return vid end
    pcall(function()
        local cur = entry:GetOuter()
        local guard = 0
        while kit.valid(cur) and guard < 6 do
            guard = guard + 1
            local id = getListVisionId(cur)
            if id > 0 then
                vid = id
                return
            end
            cur = cur:GetOuter()
        end
    end)
    return vid
end

local function hideEntryWidget(w)
    if not kit.valid(w) then return end
    pcall(function() hiddenEntryWidgets[w:GetAddress()] = true end)
    pcall(function()
        if w:GetVisibility() ~= 1 then
            w:SetVisibility(1) -- ESlateVisibility::Collapsed
        end
    end)
    pcall(function() w:SetIsEnabled(false) end)
    pcall(function() w.IsEnabled = false end)
    pcall(function()
        if kit.valid(w.PathButton) then
            w.PathButton:SetIsEnabled(false)
            w.PathButton:SetVisibility(1)
        end
    end)
end

local function unhideEntryWidget(w)
    if not kit.valid(w) then return end
    local addr = nil
    pcall(function() addr = w:GetAddress() end)
    if not addr or not hiddenEntryWidgets[addr] then return end
    hiddenEntryWidgets[addr] = nil
    pcall(function()
        if w:GetVisibility() == 1 then
            w:SetVisibility(0) -- ESlateVisibility::Visible
        end
    end)
    pcall(function() w:SetIsEnabled(true) end)
    pcall(function() w.IsEnabled = true end)
    pcall(function()
        if kit.valid(w.PathButton) then
            w.PathButton:SetIsEnabled(true)
            w.PathButton:SetVisibility(0)
        end
    end)
end

local function hideInjectedMasteryEntries()
    if not mod.enabled then return end
    if not next(injectedAny) then return end

    local lists = FindAllOf("WBP_VisionSynchroMasteryList_C") or {}
    for _, listW in ipairs(lists) do
        if kit.valid(listW) and not listW:GetFullName():find("Default__", 1, true) then
            pcall(function()
                local dgp = listW.DirectionGridPanel
                if not kit.valid(dgp) and kit.valid(listW.PathMenu) then
                    dgp = listW.PathMenu.DirectionGridPanel
                end
                if not kit.valid(dgp) then return end

                local eCount = dgp.EntryList and #dgp.EntryList or 0
                local wCount = dgp.EntryWidgetList and #dgp.EntryWidgetList or 0
                if eCount == 0 and wCount == 0 then return end

                local vid = getListVisionId(listW)
                local hideSet = nil
                if vid > 0 then
                    hideSet = injectedByVision[vid]
                    if not hideSet then return end
                else
                    -- Never fall back to global injectedAny, which can match vanilla Synchro
                    -- Mastery skills on other Visions (e.g. Cecil's MR 5); only hide skills
                    -- that never appear in any vanilla Synchro Mastery table.
                    hideSet = injectedExclusive
                end
                if not next(hideSet) then return end

                local hiddenAddrs = {}
                local keptEntries = {}
                local removedAny = false

                if dgp.EntryList and eCount > 0 then
                    for i = 1, eCount do
                        local item = dgp.EntryList[i]
                        local w = kit.valid(item) and item.Widget
                        local sid = kit.valid(w) and getEntrySkillId(w) or 0
                        if sid > 0 and hideSet[sid] then
                            removedAny = true
                            pcall(function() hiddenAddrs[w:GetAddress()] = true end)
                            hideEntryWidget(w)
                            pcall(function() w:RemoveFromParent() end)
                            pcall(function()
                                if kit.valid(item.Spacer) then
                                    item.Spacer:SetVisibility(1)
                                    item.Spacer:RemoveFromParent()
                                end
                            end)
                        else
                            if kit.valid(w) then unhideEntryWidget(w) end
                            keptEntries[#keptEntries + 1] = item
                        end
                    end

                    if removedAny then
                        dgp.EntryList:Empty()
                        for i, item in ipairs(keptEntries) do
                            dgp.EntryList[i] = item
                        end
                    end
                end

                if dgp.EntryWidgetList and wCount > 0 then
                    local keptWidgets = {}
                    local removedW = false
                    for i = 1, wCount do
                        local w = dgp.EntryWidgetList[i]
                        local hide = false
                        if kit.valid(w) then
                            pcall(function()
                                if hiddenAddrs[w:GetAddress()] then hide = true end
                            end)
                            if not hide then
                                local sid = getEntrySkillId(w)
                                if sid > 0 and hideSet[sid] then
                                    hide = true
                                end
                            end
                        end
                        if hide then
                            removedW = true
                            hideEntryWidget(w)
                            pcall(function() w:RemoveFromParent() end)
                        else
                            if kit.valid(w) then unhideEntryWidget(w) end
                            keptWidgets[#keptWidgets + 1] = w
                        end
                    end

                    if removedW then
                        dgp.EntryWidgetList:Empty()
                        for i, w in ipairs(keptWidgets) do
                            dgp.EntryWidgetList[i] = w
                        end
                    end
                end
            end)
        end
    end

    -- Fallback sweep on standalone WBP_VisionSynchroMasteryEntry_C widgets (e.g. Level Up / detail panels).
    -- Scoped by VisionId when available; otherwise restricted to injectedExclusive so vanilla
    -- Synchro Mastery bonuses on any Vision (like Cecil's MR 5) are never collapsed.
    local entries = FindAllOf("WBP_VisionSynchroMasteryEntry_C") or {}
    for _, entry in ipairs(entries) do
        if kit.valid(entry) and not entry:GetFullName():find("Default__", 1, true) then
            local sid = getEntrySkillId(entry)
            if sid > 0 then
                local vid = getEntryVisionId(entry)
                local shouldHide = false
                if vid > 0 then
                    shouldHide = (injectedByVision[vid] and injectedByVision[vid][sid]) == true
                else
                    shouldHide = (injectedExclusive[sid] == true)
                end
                if shouldHide then
                    hideEntryWidget(entry)
                else
                    unhideEntryWidget(entry)
                end
            end
        end
    end
end

mod:every(50, hideInjectedMasteryEntries, "hideInjectedMasteryEntries")
