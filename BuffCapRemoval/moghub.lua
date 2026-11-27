local mod, kit = ...

local EXTENDER_EFFECT_ID = 19014 -- SKILL_EFFECT_DATA: ExtendEffectTurnById (ParamList[1]=turns, ParamList[2..15]=target effectIds)
local GOD_OF_WATER_SKILL = 405140 -- Vanilla skill that natively uses #19014 to extend all 5 Nichol Formations
local MAX_PARAM_SLOTS = 14

local DEFAULT_EXTENDED_EFFECTS = "16502, 15123, 12207, 16126, 12929, 54207, 54225, 54213, 16092, 1007, 19051, 1042, 19047, 1163, 19048, 16107, 19049, 16101, 19050, 16102, 1165, 21003, 1064, 12912, 12922, 16066, 13200, 19063, 15117, 1289, 1291"

-- Related effect IDs for the same logical buff (e.g., Fluid Warfare's active cast 54207 and battle-start passive 54225)
local PAIRED_EFFECTS = {
    [54207] = { 54207, 54225 },
    [54225] = { 54207, 54225 },
}

-- Friendly aliases so users can write either Effect IDs or buff names in config.ini
local EFFECT_ALIASES = {
    -- Nichol Formations & Tactics
    steeledadvance = 16502, formationsteeledadvance = 16502, valiantadvance = 16502,
    assail         = 15123, formationassail = 15123, offensiveformation = 15123,
    charge         = 12207, formationcharge = 12207, chargeformation = 12207,
    bulwark        = 16126, formationbulwark = 16126, ironwallformation = 16126,
    regroup        = 12929, formationregroup = 12929, breathrecoveryformation = 12929,
    fluidwarfare   = 54207, tacticfluidwarfare = 54207, fluidtactics = 54207,
    fluidwarfarestart = 54225, fluidwarfarepassive = 54225,
    mirroringprism = 54213, refractionarts = 54213,
    stratagem      = 16092, tacticalassault = 16092,

    -- Core Magic & Party Buffs
    hastega        = 1007,  cheerhaste = 1007,
    haste          = 19051,
    protectga      = 1042,  mightyguarddef = 1042, cheerdef = 1042, shiningrubydef = 1042,
    protect        = 19047,
    shellga        = 1163,  mightyguardmnd = 1163, cheermnd = 1163, shiningrubymnd = 1163,
    shell          = 19048,
    manaward       = 16107,
    bravery        = 19049,
    atkup3         = 16101, glitteringrubyatk = 16101, spiralcut = 16101,
    faith          = 19050,
    intup3         = 16102, glitteringrubyint = 16102,
    regen          = 1165,  hiregen = 1165, healingwind = 1165,
    healingruby    = 21003,
    reflect        = 1064,  rubylight = 1064,

    -- Character Self / Stance Buffs
    honesenses     = 12912, honingsense = 12912,
    eminentcasting = 12922, grandmagic = 12922,
    concentrate    = 16066, mindfocus = 16066,
    gutrip         = 13200, vitalpointatk = 13200,
    placidity      = 19063, swift = 19063,
    sageseye       = 15117, sageeye = 15117,
    crystalbraverdef = 1289,
    crystalbravermnd = 1291,
}

-- Mods menu settings (persisted in BuffCapRemoval/config.ini)
local cfg = mod:settings{
    {
        key = "MaxBuffDuration",
        label = "Max Buff Duration",
        type = "choice",
        default = 5,
        choices = {
            { 5,  "5" },
            { 99, "99" },
        },
        help = "5: Vanilla behavior. 99: Raises the global duration cap to 99 turns and makes re-casting configured buffs (editable in BuffCapRemoval/config.ini) add turns only to the buff being cast.",
    },
    {
        key = "SpellDurationOnCast",
        label = "Spell Duration on Cast",
        type = "choice",
        default = "standard",
        choices = {
            { "standard",  "Standard" },
            { "unlimited", "Unlimited" },
        },
        help = "Standard: Buffs are cast with their normal turn duration. Unlimited: Every player buff/formation is cast with 99 turns immediately (also raises the global duration cap to 99).",
    },
    {
        key = "TurnsAddedPerRecast",
        type = "value",
        default = 3,
    },
    {
        key = "ExtendedEffects",
        type = "value",
        default = DEFAULT_EXTENDED_EFFECTS,
    },
}

local genPatch = kit.tables.patcher()
local origExtenderParams = nil    -- { p[1], ..., p[15] }
local origSkillBundles = {}       -- skillId -> list of plain SKILL_EFFECT_BUNDLE tables
local origEffectEndTurn = {}      -- effectId -> original effectEndActionNum
local skillOwnEffects = {}        -- skillId -> { effectId1, ... } (only the buffs applied by THAT skill)
local effectBaseTurns = {}        -- effectId -> base effectEndActionNum
local extenderDT = nil            -- cached UDataTable* containing SKILL_EFFECT_DATA #19014
local extenderRowName = nil       -- cached row name for #19014
local lastAppliedState = nil

local function isActive()
    if not mod.enabled then return false end
    return (tonumber(cfg.MaxBuffDuration) or 5) > 5
end

local function isUnlimitedCast()
    if not mod.enabled then return false end
    return cfg.SpellDurationOnCast == "unlimited"
end

local function parseExtendedEffects(raw)
    local out = {}
    local seen = {}
    local str = tostring(raw or DEFAULT_EXTENDED_EFFECTS)
    for token in str:gmatch("[^,;]+") do
        local trimmed = token:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            local id = tonumber(trimmed)
            if not id then
                local norm = trimmed:lower():gsub("[%s%-%_:'’]+", "")
                id = EFFECT_ALIASES[norm]
            end
            if id and id > 0 and not seen[id] then
                seen[id] = true
                out[#out + 1] = id
            end
        end
    end
    return out, seen
end

local function copyBundle(b)
    local cond = b.conditionData
    return {
        effectId = b.effectId,
        TargetType = b.TargetType,
        targetRelation = b.targetRelation,
        activeSkillAddTiming = b.activeSkillAddTiming,
        passiveSkillAddTiming = b.passiveSkillAddTiming,
        conditionData = {
            Condition = cond and cond.Condition or 0,
            param1 = cond and cond.param1 or 0,
            param2 = cond and cond.param2 or 0,
            param3 = cond and cond.param3 or 0,
        },
    }
end

local function writeBundles(bl, list)
    if not bl then return false end
    local same = (#bl == #list)
    if same then
        for i = 1, #list do
            if bl[i].effectId ~= list[i].effectId then
                same = false
                break
            end
        end
    end
    if same then return false end
    bl:Empty()
    for i, item in ipairs(list) do
        bl[i] = item
    end
    return true
end

-- Write a specific turns count + target effect ID list into SKILL_EFFECT_DATA #19014's ParamList.
-- When targetIds is nil, restores #19014 to its original vanilla values.
local function setExtenderParams(turnsAdd, targetIds)
    local function applyToRow(row)
        local pl = row.ParamList
        if not pl or #pl < (MAX_PARAM_SLOTS + 1) then return false end
        if not origExtenderParams then
            origExtenderParams = {}
            for i = 1, #pl do origExtenderParams[i] = pl[i] end
        end
        if not targetIds then
            for i = 1, #origExtenderParams do
                pl[i] = origExtenderParams[i]
            end
        else
            pl[1] = turnsAdd
            for slot = 1, MAX_PARAM_SLOTS do
                pl[slot + 1] = targetIds[slot] or -1
            end
        end
        return true
    end

    if kit.valid(extenderDT) then
        local updated = false
        pcall(function()
            extenderDT:ForEachRow(function(_, r)
                if not updated and r.ID == EXTENDER_EFFECT_ID then
                    updated = applyToRow(r)
                end
            end)
        end)
        if updated then return true end
    end

    local updated = false
    pcall(function()
        kit.tables.rows("SKILL_EFFECT_DATA", function(row, rowName, tbl)
            if row.ID ~= EXTENDER_EFFECT_ID then return end
            extenderDT = tbl.dt
            extenderRowName = tostring(rowName)
            updated = applyToRow(row)
        end)
    end)
    return updated
end

-- Dynamically scope #19014 to ONLY the buff(s) belonging to the skill currently executing,
-- so casting one formation/buff never extends unrelated buffs on the same unit.
local function scopeExtenderForSkill(skillId)
    if not isActive() or not skillId or skillId <= 0 then return end

    -- Keep God of Water's Blessing (405140) 100% vanilla (extends all 5 Nichol Formations by +2)
    if skillId == GOD_OF_WATER_SKILL then
        setExtenderParams(nil, nil)
        return
    end

    local ownIds = skillOwnEffects[skillId]
    if not ownIds or #ownIds == 0 then return end

    local cfgTurns = tonumber(cfg.TurnsAddedPerRecast)
    local turnsAdd
    if cfgTurns and cfgTurns <= 0 then
        -- 0 = auto-match this buff's own base duration
        turnsAdd = effectBaseTurns[ownIds[1]] or 3
    else
        turnsAdd = math.max(1, math.min(99, math.floor(cfgTurns or 3)))
    end

    setExtenderParams(turnsAdd, ownIds)
end

local function applyPatch(force)
    local active = isActive()
    local unlimited = isUnlimitedCast()
    local cap = (active or unlimited) and 99 or nil
    local turnsAdd = tonumber(cfg.TurnsAddedPerRecast) or 3
    local extList, extSet = parseExtendedEffects(cfg.ExtendedEffects)

    local stateSig = string.format("%s|%s|%s|%s|%s",
        tostring(cap or "vanilla"),
        tostring(active),
        tostring(unlimited),
        tostring(turnsAdd),
        active and table.concat(extList, ",") or ""
    )

    if not force and lastAppliedState == stateSig then
        genPatch:apply("SKILL_GENERAL_DATA", stateSig, function(row, orig)
            local vanillaVal = orig("effectMaxLifeTime")
            kit.tables.set(row, "effectMaxLifeTime", cap or vanillaVal, vanillaVal)
        end)
        return
    end

    if force then genPatch:invalidate() end

    -- 1. Patch (or restore) SKILL_GENERAL_DATA.effectMaxLifeTime
    local foundGeneral = false
    genPatch:apply("SKILL_GENERAL_DATA", stateSig, function(row, orig)
        foundGeneral = true
        local vanillaVal = orig("effectMaxLifeTime")
        kit.tables.set(row, "effectMaxLifeTime", cap or vanillaVal, vanillaVal)
    end)
    if not foundGeneral and #kit.tables.find("SKILL_GENERAL_DATA") == 0 then
        return
    end

    -- Collect valid non-debuff buff status conditions (excluding Defend=36) and all effect IDs
    -- referenced by player skills (200000 <= ID < 500000) so Unlimited mode never extends enemy-only buffs.
    local validBuffStatus = {}
    local playerEffectIds = {}
    for eid in pairs(extSet) do playerEffectIds[eid] = true end
    if unlimited or next(origEffectEndTurn) then
        pcall(function()
            kit.tables.rows("UNIT_STATUSCONDITION_DETAIL_DATA", function(row)
                if not row.isBadStatus and not row.isDebuff then
                    local sc = tonumber(tostring(row.statusCondition)) or 0
                    if sc >= 24 and sc <= 86 and sc ~= 36 then
                        validBuffStatus[sc] = true
                    end
                end
            end)
            kit.tables.rows("SKILL_DATA", function(row)
                local sid = row.ID
                if not sid or sid < 200000 or sid >= 500000 then return end
                local bl = origSkillBundles[sid] or row.effectBundleList
                if not bl then return end
                for i = 1, #bl do
                    local eid = bl[i].effectId
                    if eid and eid > 0 and eid ~= EXTENDER_EFFECT_ID then
                        playerEffectIds[eid] = true
                    end
                end
            end)
        end)
    end

    -- 2. Cache #19014 location, snapshot vanilla params, record base turn durations,
    --    and apply (or restore) SpellDurationOnCast = Unlimited (99 turns on player buffs).
    local foundExtender = false
    local unlimitedEffectsPatched, unlimitedEffectsRestored = 0, 0
    pcall(function()
        kit.tables.rows("SKILL_EFFECT_DATA", function(row, rowName, tbl)
            local id = row.ID
            local sc = tonumber(tostring(row.statusCondition)) or 0
            local curEnd = row.effectEndActionNum

            if origEffectEndTurn[id] == nil and curEnd and curEnd > 0 then
                if extSet[id] or (unlimited and playerEffectIds[id] and validBuffStatus[sc]) then
                    origEffectEndTurn[id] = curEnd
                end
            end
            local baseEnd = origEffectEndTurn[id] or curEnd
            if extSet[id] and baseEnd and baseEnd > 0 then
                effectBaseTurns[id] = baseEnd
            end

            if unlimited and playerEffectIds[id] and validBuffStatus[sc] and origEffectEndTurn[id] and origEffectEndTurn[id] > 0 then
                if curEnd ~= 99 then
                    row.effectEndActionNum = 99
                    unlimitedEffectsPatched = unlimitedEffectsPatched + 1
                end
            elseif origEffectEndTurn[id] and curEnd ~= origEffectEndTurn[id] then
                row.effectEndActionNum = origEffectEndTurn[id]
                unlimitedEffectsRestored = unlimitedEffectsRestored + 1
            end

            if id == EXTENDER_EFFECT_ID then
                extenderDT = tbl.dt
                extenderRowName = tostring(rowName)
                local pl = row.ParamList
                if pl and #pl >= (MAX_PARAM_SLOTS + 1) then
                    if not origExtenderParams then
                        origExtenderParams = {}
                        for i = 1, #pl do origExtenderParams[i] = pl[i] end
                    end
                    foundExtender = true
                end
            end
        end)
    end)
    if foundExtender then
        setExtenderParams(nil, nil)
    end

    -- 3. Prepend #19014 to every player skill (200000 <= ID < 500000) that applies one or more
    --    configured buff Effect IDs, and record each skill's exact own Effect ID(s) so casting it
    --    only extends that specific buff (never unrelated formations/buffs).
    local newSkillOwnEffects = {}
    local patchedSkills, restoredSkills = 0, 0
    pcall(function()
        kit.tables.rows("SKILL_DATA", function(row)
            local sid = row.ID
            if not sid or sid < 200000 or sid >= 500000 then return end
            local bl = row.effectBundleList
            if not bl or #bl == 0 then return end

            local alreadyHasExtender = false
            local matchBundle = nil
            local ownList, ownSeen = {}, {}

            local function collectFrom(bundles, isPlain)
                for i = 1, #bundles do
                    local b = bundles[i]
                    local eid = b.effectId
                    if eid == EXTENDER_EFFECT_ID then
                        alreadyHasExtender = true
                    elseif extSet[eid] then
                        if not matchBundle then
                            matchBundle = isPlain and b or copyBundle(b)
                        end
                        local paired = PAIRED_EFFECTS[eid]
                        if paired then
                            for _, pid in ipairs(paired) do
                                if not ownSeen[pid] and #ownList < MAX_PARAM_SLOTS then
                                    ownSeen[pid] = true
                                    ownList[#ownList + 1] = pid
                                end
                            end
                        elseif not ownSeen[eid] and #ownList < MAX_PARAM_SLOTS then
                            ownSeen[eid] = true
                            ownList[#ownList + 1] = eid
                        end
                    end
                end
            end

            if origSkillBundles[sid] then
                collectFrom(origSkillBundles[sid], true)
            else
                collectFrom(bl, false)
            end

            if active and matchBundle and not alreadyHasExtender and #ownList > 0 then
                if not origSkillBundles[sid] then
                    local snap = {}
                    for i = 1, #bl do
                        snap[i] = copyBundle(bl[i])
                    end
                    origSkillBundles[sid] = snap
                end

                newSkillOwnEffects[sid] = ownList

                local extBundle = {
                    effectId = EXTENDER_EFFECT_ID,
                    TargetType = matchBundle.TargetType,
                    targetRelation = matchBundle.targetRelation,
                    activeSkillAddTiming = 1,
                    passiveSkillAddTiming = 0,
                    conditionData = {
                        Condition = matchBundle.conditionData.Condition,
                        param1 = matchBundle.conditionData.param1,
                        param2 = matchBundle.conditionData.param2,
                        param3 = matchBundle.conditionData.param3,
                    },
                }

                local rebuilt = { extBundle }
                for _, origB in ipairs(origSkillBundles[sid]) do
                    rebuilt[#rebuilt + 1] = origB
                end

                if writeBundles(bl, rebuilt) then
                    patchedSkills = patchedSkills + 1
                end
            elseif origSkillBundles[sid] then
                if writeBundles(bl, origSkillBundles[sid]) then
                    restoredSkills = restoredSkills + 1
                end
            end
        end)
    end)

    skillOwnEffects = newSkillOwnEffects
    lastAppliedState = stateSig
    if active or unlimited then
        mod:log(string.format(
            "Buff Cap Removal applied: cap=%s, recastStack=%s (+%s turns, %d skills), onCast=%s (%d effects -> 99t, %d restored).",
            tostring(cap or "vanilla"),
            tostring(active),
            turnsAdd <= 0 and "base" or tostring(turnsAdd),
            patchedSkills,
            unlimited and "Unlimited" or "Standard",
            unlimitedEffectsPatched,
            unlimitedEffectsRestored
        ))
    else
        mod:log(string.format(
            "Buff Cap Removal vanilla: cap restored, extender restored=%s, %d skills / %d effects restored.",
            tostring(foundExtender), restoredSkills, unlimitedEffectsRestored
        ))
    end
end

-- Hook battle skill begin / command decide via MogHub's native ExecuteEvent dispatcher
-- so #19014 is scoped exclusively to the exact skill currently executing.
mod:on("gameEvent", function(_, valParam)
    if not isActive() or not valParam then return end
    pcall(function()
        local val = valParam
        if type(val) == "userdata" and not val.IsValid then
            local okG, g = pcall(function() return val:get() end)
            if okG then val = g end
        end
        if not kit.valid(val) then return end

        -- 1. CPP_BtlSkillBeginDelVal: fires right as each skill begins executing (covers single, W-Action, Fluid Warfare, etc.)
        local okS, sid = pcall(function() return val.SkillId end)
        if okS and type(sid) == "number" and sid > 0 then
            scopeExtenderForSkill(sid)
            return
        end

        -- 2. CPP_BtlCmdDecideDelegateVal: early pre-scope when a command is confirmed
        local okD, list = pcall(function() return val.cmdDecideDataList end)
        if okD and list and #list > 0 then
            local first = list[1]
            if first and not first.isUseItem and type(first.actionId) == "number" and first.actionId > 0 then
                scopeExtenderForSkill(first.actionId)
            end
        end
    end)
end)

mod:every(1000, function() applyPatch(false) end, "applyBuffCap")
mod:on("loadingEnd", function() applyPatch(true) end)
mod:on("saveLoaded", function() applyPatch(true) end)
mod:onToggle(function() applyPatch(true) end)
cfg:onChange(function(key, value)
    if key == "MaxBuffDuration" then
        applyPatch(true)
        mod:notice("Max Buff Duration: " .. tostring(value) .. " turns", "on", 1800)
    elseif key == "SpellDurationOnCast" then
        applyPatch(true)
        mod:notice("Spell Duration on Cast: " .. (value == "unlimited" and "Unlimited (99 turns)" or "Standard"), "on", 1800)
    elseif key == "ExtendedEffects" or key == "TurnsAddedPerRecast" then
        applyPatch(true)
    end
end)

applyPatch(false)
