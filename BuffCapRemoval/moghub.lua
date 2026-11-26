local mod, kit = ...

-- Mods menu settings (automatically persisted to BuffCapRemoval/config.ini)
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
        help = "Maximum number of turns continuous effects (buffs/formations) can stack to in combat. Default: 5 (vanilla). Note: SKILL_GENERAL_DATA.effectMaxLifeTime is a global cap shared by any extendable continuous effect.",
    },
}

local patch = kit.tables.patcher()
local loggedVanillaInfo = false

local function targetCap()
    if not mod.enabled then return nil end
    local v = tonumber(cfg.MaxBuffDuration) or 5
    if v <= 5 then return nil end
    return v
end

local function logStatusExtendBreakdown()
    if loggedVanillaInfo then return end
    local buffExt, debuffExt, badExt = 0, 0, 0
    local foundStatus = false
    pcall(function()
        kit.tables.rows("UNIT_STATUSCONDITION_DETAIL_DATA", function(row)
            foundStatus = true
            if row.isExtendLifeTurn then
                if row.isBadStatus then
                    badExt = badExt + 1
                elseif row.isDebuff then
                    debuffExt = debuffExt + 1
                else
                    buffExt = buffExt + 1
                end
            end
        end)
    end)
    if foundStatus then
        loggedVanillaInfo = true
        mod:log(string.format(
            "UNIT_STATUSCONDITION_DETAIL_DATA extendable effects: %d buffs, %d debuffs, %d bad statuses.",
            buffExt, debuffExt, badExt
        ))
    end
end

local function applyPatch(force)
    if force then patch:invalidate() end
    local cap = targetCap()
    local state = cap and tostring(cap) or "vanilla"
    local applied = patch:apply("SKILL_GENERAL_DATA", state, function(row, orig)
        local vanillaVal = orig("effectMaxLifeTime")
        local want = cap or vanillaVal
        kit.tables.set(row, "effectMaxLifeTime", want, vanillaVal)
        mod:log(string.format(
            "SKILL_GENERAL_DATA.effectMaxLifeTime: vanilla=%s -> active=%s",
            tostring(vanillaVal), tostring(want)
        ))
    end)
    if applied then
        logStatusExtendBreakdown()
    end
end

mod:every(1000, function() applyPatch(false) end, "applyBuffCap")
mod:on("loadingEnd", function() applyPatch(true) end)
mod:on("saveLoaded", function() applyPatch(true) end)
mod:onToggle(function() applyPatch(true) end)
cfg:onChange(function(key, value)
    if key == "MaxBuffDuration" then
        applyPatch(true)
        mod:notice("Max Buff Duration: " .. tostring(value) .. " turns", "on", 1800)
    end
end)

applyPatch(false)
