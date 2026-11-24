local mod, kit = ...

-- Check whether VisionMasteryAP currently has Vision Spells set to Permanent
local function isVisionPermanent()
    if kit.plugins then
        for _, p in ipairs(kit.plugins) do
            if p.id == "VisionMasteryAP" and p.enabled and p.config then
                return p.config.VisionSpellsMode == "permanent"
            end
        end
    end
    local ok, vals = pcall(function()
        return kit.config.read(mod.dir .. "/../VisionMasteryAP/config.ini")
    end)
    return ok and vals and vals.VisionSpellsMode == "permanent"
end

-- Mods menu settings (expand "Skill Sorter" with Confirm in the Mods screen;
-- keybinds can also be customized in SkillSorter/config.ini for non-QWERTY layouts)
local cfg = mod:settings{
    {
        key = "PaginatedAbilities",
        label = "Paginated Abilities",
        type = "toggle",
        default = isVisionPermanent(),
        help = "In combat, press Q / E (or LB / RB on controller) inside the Skills menu to page through All, Physical, Heal, Magic, Buff / Debuff, and Other. Defaults to On only when Vision Spells is set to Permanent.",
    },
    {
        key = "PaginatedAbilitiesCustomized",
        type = "value",
        default = false,
    },
    { key = "PickDropKey", type = "value", default = "R" },
    { key = "CancelKey",   type = "value", default = "C" },
    { key = "AutoSortKey", type = "value", default = "G" },
    { key = "PrevPageKey", type = "value", default = "Q" },
    { key = "NextPageKey", type = "value", default = "E" },
}

local syncingPaginationDefault = false
cfg:onChange(function(key)
    if key == "PaginatedAbilities" and not syncingPaginationDefault then
        cfg.PaginatedAbilitiesCustomized = true
    end
end)

-- If the user hasn't explicitly overridden Paginated Abilities yet, keep it synced to
-- whether Vision Spells is set to Permanent; once toggled by the user, preserve their choice.
local function syncPaginationDefault()
    if cfg.PaginatedAbilitiesCustomized then return end
    local want = isVisionPermanent()
    if cfg.PaginatedAbilities ~= want then
        syncingPaginationDefault = true
        cfg.PaginatedAbilities = want
        syncingPaginationDefault = false
    end
end
syncPaginationDefault()
mod:every(2000, syncPaginationDefault, "syncPaginationDefault")

-- JSON file for persisting skill order per save slot
local store = mod:store("SkillOrder")

local pickedSkillId = nil
local lastUnitKey = nil
local wasPickDown = false
local wasCancelDown = false
local wasAutoSortDown = false
local wasListOpen = false

-- Check if any key in a list (keyboard + gamepad equivalent) is currently held
local function anyKeyDown(keys)
    for _, k in ipairs(keys) do
        if k and k ~= "" and kit.game.keyDown(k) then
            return true
        end
    end
    return false
end

local function pickKeys()     return { cfg.PickDropKey or "R", "Gamepad_FaceButton_Left" } end
local function cancelKeys()   return { cfg.CancelKey or "C",   "Gamepad_FaceButton_Right" } end
local function autoSortKeys() return { cfg.AutoSortKey or "G", "Gamepad_FaceButton_Top" } end
local function prevPageKeys() return { cfg.PrevPageKey or "Q", "Gamepad_LeftShoulder" } end
local function nextPageKeys() return { cfg.NextPageKey or "E", "Gamepad_RightShoulder" } end

local function indexOf(t, v)
    for i, x in ipairs(t) do
        if x == v then return i end
    end
    return nil
end

-- Battle commands (Attack, Defend, Escape) should never be sorted or added to skill order
local function isCommand(id)
    if not id then return true end
    return id < 1000
        or id == 400010 or id == 400020 or id == 900000 -- Defend, Escape, Take a Break
        or (id >= 401010 and id <= 409010 and id % 1000 == 10) -- each character's Attack
end

-- Helper to safely call UObject methods
local function safeCall(obj, fn, ...)
    if not kit.valid(obj) then return false, nil end
    local args = { ... }
    return pcall(function() return obj[fn](obj, table.unpack(args)) end)
end

local function saveStore()
    local slot = store.slot or (kit.events and kit.events.slot)
    if slot ~= nil then
        store:save(slot)
    end
end

-- Ensures all skills have a stable rank and never get scrambled
local function getSortedIds(unitKey, currentIds, allowAdd)
    local master = store.data[unitKey]
    if not master or #master == 0 then
        return currentIds
    end

    local modified = false

    -- In pause menu: append any new skills seen for the first time in their natural game order
    if allowAdd then
        for _, id in ipairs(currentIds) do
            if not isCommand(id) and not indexOf(master, id) then
                table.insert(master, id)
                modified = true
            end
        end

        if modified then
            saveStore()
        end
    end

    local rank = {}
    for i, id in ipairs(master) do
        rank[id] = i
    end

    local decorated = {}
    for i, id in ipairs(currentIds) do
        local r = rank[id]
        if not r then
            -- Keep battle commands (Attack, Defend, etc.) at the top; unranked skills go to the bottom
            r = isCommand(id) and 0 or 99999
        end
        decorated[i] = { id = id, pos = i, rank = r }
    end

    table.sort(decorated, function(a, b)
        if a.rank ~= b.rank then
            return a.rank < b.rank
        end
        return a.pos < b.pos -- Stable tie-breaker preserving original order
    end)

    local sorted = {}
    for i, d in ipairs(decorated) do
        sorted[i] = d.id
    end
    return sorted
end

-- Moves `id` to `targetId`'s position (inserting above when moving up, below when moving down)
local function moveSkill(unitKey, id, targetId, moveDown, currentIds)
    if not store.data[unitKey] or #store.data[unitKey] == 0 then
        local init = {}
        for _, v in ipairs(currentIds) do
            if not isCommand(v) then table.insert(init, v) end
        end
        store.data[unitKey] = init
    end

    local master = store.data[unitKey]
    for i, v in ipairs(master) do
        if v == id then
            table.remove(master, i)
            break
        end
    end

    local insertAt = #master + 1
    for i, v in ipairs(master) do
        if v == targetId then
            insertAt = moveDown and (i + 1) or i
            break
        end
    end

    table.insert(master, insertAt, id)
    store.data[unitKey] = master
    saveStore()
end

-- The VM array and the widget both get the new order: the widget draws the rows, the VM answers
-- GetActionId(index) for the rest of the screen. The widget takes a plain Lua table (passing the VM's
-- TArray wrapper fails silently on this build), so the table goes first and the TArray is only a fallback.
-- Each attempt is checked by comparing the menu's item count with ours.
local warnedApply = false
local function applyOrderToUI(vm, listWidget, ids)
    local arr = vm.ActionIdList
    for i, id in ipairs(ids) do
        arr[i] = id
    end
    local menu = listWidget.PathMenu
    for _, a in ipairs({ ids, arr }) do
        local ok = safeCall(listWidget, "SetActionIdList", a)
        local okN, n = pcall(function() return menu.ListItems:GetArrayNum() end)
        if ok and okN and n == #ids then return true end
    end
    if not warnedApply then
        warnedApply = true
        mod:log("SetActionIdList did not take: the list on screen could not be redrawn")
    end
    return false
end

-- Track the last focused item widget reported by CPP_WBP_MenuBase hooks
local lastFocusedWidgetAddr = nil
local lastFocusedWidgetName = nil
local focusHooked = false

local function ensureFocusHooks()
    if focusHooked then return end
    focusHooked = true
    for _, fn in ipairs({ "SetFocuedItemWidget", "BP_OnItemFocused" }) do
        pcall(function()
            RegisterHook("/Script/EnhancedUI.CPP_WBP_MenuBase:" .. fn, function(_, itemWidgetParam)
                pcall(function()
                    local w = itemWidgetParam:get()
                    if kit.valid(w) then
                        lastFocusedWidgetAddr = w:GetAddress()
                        lastFocusedWidgetName = w:GetFName():ToString()
                    end
                end)
            end)
        end)
    end
end

-- Collects the entry widgets currently inside a PathMenu's DirectionGridPanel
local function getMenuEntryWidgets(menu)
    local out = {}
    if not kit.valid(menu) then return out end
    pcall(function()
        local dgp = menu.DirectionGridPanel
        if kit.valid(dgp) and dgp.EntryWidgetList then
            dgp.EntryWidgetList:ForEach(function(_, e)
                local w = e:get()
                if kit.valid(w) then out[#out + 1] = w end
            end)
        end
    end)
    if #out == 0 then
        pcall(function()
            local dgp = menu.DirectionGridPanel
            local root = kit.valid(dgp) and dgp.WidgetTree and dgp.WidgetTree.RootWidget
            if kit.valid(root) then
                local n = root:GetChildrenCount() or 0
                for i = 0, n - 1 do
                    local w = root:GetChildAt(i)
                    if kit.valid(w) then out[#out + 1] = w end
                end
            end
        end)
    end
    return out
end

local function isWidgetFocused(w)
    if not kit.valid(w) then return false end
    local hit = false
    pcall(function() hit = hit or w:HasAnyUserFocus() end)
    pcall(function() hit = hit or w:HasFocusedDescendants() end)
    pcall(function()
        if not hit and kit.valid(w.PathButton) then
            hit = hit or w.PathButton:HasAnyUserFocus() or w.PathButton:HasFocusedDescendants()
        end
    end)
    return hit
end

local function getFocusedIndex(menu)
    ensureFocusHooks()

    -- 1. Try direct index getters (note: CPP_WBP_MenuBase spells Focused as "Focued" in C++)
    for _, fn in ipairs({ "GetFocuedItemIndex", "GetFocusedItemIndex", "GetFocuedIndex", "GetFocusedIndex" }) do
        local ok, idx = safeCall(menu, fn, 0)
        if ok and type(idx) == "number" and idx >= 0 then return idx end
        local ok2, idx2 = safeCall(menu, fn)
        if ok2 and type(idx2) == "number" and idx2 >= 0 then return idx2 end
    end

    -- 2. Inspect entry widgets in DirectionGridPanel for active focus or hook-recorded focus
    local entries = getMenuEntryWidgets(menu)
    if #entries > 0 then
        for i, w in ipairs(entries) do
            if isWidgetFocused(w) then
                return i - 1
            end
        end

        for _, fn in ipairs({ "GetFocuedItemWidget", "GetFocusedItemWidget" }) do
            local okW, fw = safeCall(menu, fn, 0)
            if not (okW and kit.valid(fw)) then
                okW, fw = safeCall(menu, fn)
            end
            if okW and kit.valid(fw) then
                local fwAddr = nil
                pcall(function() fwAddr = fw:GetAddress() end)
                for i, w in ipairs(entries) do
                    local match = false
                    pcall(function() match = (fwAddr and w:GetAddress() == fwAddr) or (w:GetFName():ToString() == fw:GetFName():ToString()) end)
                    if match then return i - 1 end
                end
            end
        end

        if lastFocusedWidgetAddr or lastFocusedWidgetName then
            for i, w in ipairs(entries) do
                local match = false
                pcall(function()
                    match = (lastFocusedWidgetAddr and w:GetAddress() == lastFocusedWidgetAddr)
                        or (lastFocusedWidgetName and w:GetFName():ToString() == lastFocusedWidgetName)
                end)
                if match then return i - 1 end
            end
        end
    end

    -- 3. Fallback: try FocuedItemDataMap if accessible
    local found = nil
    pcall(function()
        if menu.FocuedItemDataMap then
            menu.FocuedItemDataMap:ForEach(function(k, v)
                if k:get() == 0 then
                    local itemData = v:get()
                    found = itemData.Index
                end
            end)
        end
    end)
    return found
end

local function focusToIndex(menu, targetIdx)
    for _, fn in ipairs({ "SetFocuedItemByIndex", "SetFocuedIndex", "NavigateToIndex", "SetFocusedItemByIndex", "SetFocusedIndex" }) do
        if safeCall(menu, fn, targetIdx, 0) then return end
        if safeCall(menu, fn, targetIdx) then return end
    end
    local entries = getMenuEntryWidgets(menu)
    local targetWidget = entries[targetIdx + 1]
    if kit.valid(targetWidget) then
        if safeCall(menu, "SetFocuedItemWidget", targetWidget, 0) then return end
        if safeCall(menu, "SetFocuedItemWidget", targetWidget) then return end
    end
end

-------------------------------------------------------------------------------
-- AUTO SORT (group by type, then most to least powerful)
-------------------------------------------------------------------------------
local AUTO_SORT_CONFIRM_SEC = 3

local GROUP = {
    PHYSICAL = 1,
    HEAL     = 2,
    MAGIC    = 3,
    BUFF     = 4,
    DEBUFF   = 5,
    OTHER    = 6,
}

local ELEMENT_SUB = {
    Fire = 1,
    Ice = 2,
    Thunder = 3,
    Water = 4,
    Wind = 5,
    Earth = 6,
    Light = 7,
    Dark = 8,
    Magic = 9,
}

local EFFECT = {
    DamageAndRecovery = 1, ParameterVariation = 2, ParameterContinuousVariation = 3,
    IncreaseParameterVariation = 4, CureStatusCondition = 19, Revival = 20,
    AddEffect = 57, AddRandEffect = 58,
}
local STATUS_EFFECTS = {
    [EFFECT.ParameterVariation] = true, [EFFECT.ParameterContinuousVariation] = true,
    [EFFECT.IncreaseParameterVariation] = true, [EFFECT.AddEffect] = true, [EFFECT.AddRandEffect] = true,
}
local REL_FRIENDLIES, REL_ENEMIES = 1, 2   -- eRelation
local DMG_PHYSIC, DMG_MAGIC = 1, 2         -- eSkillDamageType

-- a game value as a plain Lua number (enum and int fields can come back wrapped)
local function num(v)
    if type(v) == "number" then return v end
    if v == nil then return 0 end
    local ok, x = pcall(function() return v:get() end)
    if ok and type(x) == "number" then return x end
    return tonumber(tostring(v)) or 0
end

-- skill id -> { group, sub, power, hits, brk, cost, sortId }, read once from the SKILL_DATA tables
local skillInfo = nil
local function loadSkillInfo()
    if skillInfo and next(skillInfo) then return skillInfo end
    local info = {}
    pcall(function()
        kit.tables.rows("SKILL_DATA", function(row)
            local id = num(row.ID)
            if id <= 0 or info[id] then return end

            local effect = num(row.skillEffectType)
            local relation = num(row.defaultTargetRelation)
            local damageType = num(row.DamageType)
            local element = num(row.element)
            local power = num(row.magnification)
            local hits = num(row.hitCount)
            local brk = num(row.breakDamageValue)
            local cost = num(row.Cost)
            local sortId = num(row.SortId)

            local rawIcon = nil
            pcall(function()
                if row.SkillIcon then
                    local v = row.SkillIcon
                    if type(v) == "number" then
                        rawIcon = v
                    elseif type(v.TagName) == "userdata" and type(v.TagName.ToString) == "function" then
                        rawIcon = v.TagName:ToString()
                    elseif type(v.ToString) == "function" then
                        rawIcon = v:ToString()
                    elseif type(v.get) == "function" then
                        rawIcon = v:get()
                    end
                end
            end)

            local iconName = nil
            if type(rawIcon) == "string" then
                local s = rawIcon:lower()
                if s:find("fire") then iconName = "Fire"
                elseif s:find("ice") or s:find("blizzard") then iconName = "Ice"
                elseif s:find("thunder") or s:find("lightning") then iconName = "Thunder"
                elseif s:find("water") then iconName = "Water"
                elseif s:find("wind") or s:find("aero") then iconName = "Wind"
                elseif s:find("earth") or s:find("stone") or s:find("quake") then iconName = "Earth"
                elseif s:find("light") or s:find("holy") then iconName = "Light"
                elseif s:find("dark") then iconName = "Dark"
                elseif s:find("heal") or s:find("recovery") then iconName = "Heal"
                elseif s:find("aid") or s:find("buff") then iconName = "Aid"
                elseif s:find("badstatus") or s:find("debuff") then iconName = "BadStatus"
                elseif s:find("magic") then iconName = "Magic"
                elseif s:find("attack") then iconName = "Attack"
                end
            elseif type(rawIcon) == "number" then
                local map = {
                    [0] = "Attack", [1] = "Aid", [2] = "Heal", [3] = "BadStatus",
                    [4] = "Fire", [5] = "Ice", [6] = "Wind", [7] = "Earth",
                    [8] = "Thunder", [9] = "Water", [10] = "Light", [11] = "Dark"
                }
                iconName = map[rawIcon]
            end

            if not iconName then
                if effect == EFFECT.Revival or effect == EFFECT.CureStatusCondition
                    or (effect == EFFECT.DamageAndRecovery and relation == REL_FRIENDLIES) then
                    iconName = "Heal"
                elseif STATUS_EFFECTS[effect] then
                    iconName = (relation == REL_ENEMIES) and "BadStatus" or "Aid"
                elseif damageType == DMG_PHYSIC and (relation == REL_ENEMIES or power > 0 or hits > 0 or brk > 0) then
                    iconName = "Attack"
                elseif element == 1 then iconName = "Fire"
                elseif element == 2 then iconName = "Ice"
                elseif element == 3 then iconName = "Wind"
                elseif element == 4 then iconName = "Earth"
                elseif element == 5 then iconName = "Thunder"
                elseif element == 6 then iconName = "Water"
                elseif element == 7 then iconName = "Light"
                elseif element == 8 then iconName = "Dark"
                elseif (relation == REL_ENEMIES or power > 0 or hits > 0 or brk > 0) then
                    iconName = (damageType == DMG_MAGIC) and "Magic" or "Attack"
                else
                    iconName = "Other"
                end
            end

            local group = GROUP.OTHER
            local sub = 0

            if iconName == "Attack" then
                group = GROUP.PHYSICAL
            elseif iconName == "Heal" then
                group = GROUP.HEAL
            elseif ELEMENT_SUB[iconName] then
                group = GROUP.MAGIC
                sub = ELEMENT_SUB[iconName]
            elseif iconName == "Aid" then
                group = GROUP.BUFF
            elseif iconName == "BadStatus" then
                group = GROUP.DEBUFF
            end

            info[id] = {
                group = group,
                sub = sub,
                power = power,
                hits = hits,
                brk = brk,
                cost = cost,
                sortId = sortId,
            }
        end)
    end)
    if next(info) then
        skillInfo = info
    else
        mod:log("auto sort: SKILL_DATA table not found (not loaded yet?)")
    end
    return info
end

local function autoSortedOrder(ids)
    local info = loadSkillInfo()
    local decorated = {}
    for i, id in ipairs(ids) do decorated[i] = { id = id, pos = i, s = info[id] } end
    table.sort(decorated, function(a, b)
        local sa, sb = a.s, b.s
        if (sa ~= nil) ~= (sb ~= nil) then return sa ~= nil end
        if sa and sb then
            if sa.group ~= sb.group then return sa.group < sb.group end
            if sa.sub ~= sb.sub then return sa.sub < sb.sub end
            if sa.power ~= sb.power then return sa.power > sb.power end
            if sa.hits ~= sb.hits then return sa.hits > sb.hits end
            if sa.brk ~= sb.brk then return sa.brk > sb.brk end
            if sa.cost ~= sb.cost then return sa.cost > sb.cost end
            if sa.sortId ~= sb.sortId then return sa.sortId < sb.sortId end
        end
        return a.pos < b.pos
    end)
    local out = {}
    for i, d in ipairs(decorated) do out[i] = d.id end
    return out
end

local autoSortArmedAt = nil

-------------------------------------------------------------------------------
-- PAUSE MENU (SORTING & SAVING)
-------------------------------------------------------------------------------
local function getOpenSkillScreen()
    for _, layout in ipairs(FindAllOf("WBP_UnitSkillLayout_C") or {}) do
        if kit.valid(layout) and not layout:GetFName():ToString():find("Default__") then
            local vis, focused = false, false
            pcall(function()
                vis = layout:IsVisible()
                if vis then
                    focused = layout:HasFocusedDescendants() or layout:HasAnyUserFocus()
                end
            end)
            if vis and focused then return layout end
        end
    end
    return nil
end

local function handlePauseMenuSorting()
    if not mod.enabled then return end
    -- Skip Pause Menu scans during combat
    if kit.events and kit.events.battle then
        pickedSkillId = nil
        autoSortArmedAt = nil
        lastUnitKey = nil
        wasListOpen = false
        return
    end

    ensureFocusHooks()

    local layout = getOpenSkillScreen()
    local vm = layout and layout.VM_UnitSkillPanel
    local listWidget = layout and layout.WBP_UnitSkillPanel_ActionList

    local isScreenOpen = kit.valid(layout)
        and kit.valid(vm)
        and kit.valid(listWidget)

    if not isScreenOpen then
        pickedSkillId = nil
        autoSortArmedAt = nil
        lastUnitKey = nil
        wasListOpen = false
        wasPickDown = anyKeyDown(pickKeys())
        wasCancelDown = anyKeyDown(cancelKeys())
        wasAutoSortDown = anyKeyDown(autoSortKeys())
        return
    end

    local rawId = vm.UnitId
    local unitId = tonumber(tostring(rawId))
    if not unitId or unitId <= 0 then return end
    local unitKey = tostring(unitId)
    if lastUnitKey and lastUnitKey ~= unitKey then
        pickedSkillId = nil
        autoSortArmedAt = nil
    end
    lastUnitKey = unitKey
    local menu = listWidget.PathMenu

    local currentActionIds = {}
    for i = 1, vm.ActionIdList:GetArrayNum() do
        currentActionIds[i] = vm.ActionIdList[i]
    end
    if #currentActionIds == 0 then return end

    -- Auto-apply stored order whenever the Skill screen is open
    if store.data[unitKey] and #store.data[unitKey] > 0 then
        local sortedIds = getSortedIds(unitKey, currentActionIds, true)
        local needsSort = false
        for i = 1, #currentActionIds do
            if currentActionIds[i] ~= sortedIds[i] then
                needsSort = true
                break
            end
        end

        if needsSort then
            applyOrderToUI(vm, listWidget, sortedIds)
            currentActionIds = sortedIds
        end
    end

    -- Interactive sorting only runs while focus is inside the skill list (Visibility == 4)
    local isListOpen = listWidget:GetVisibility() == 4
    if not isListOpen then
        pickedSkillId = nil
        autoSortArmedAt = nil
        wasListOpen = false
        wasPickDown = anyKeyDown(pickKeys())
        wasCancelDown = anyKeyDown(cancelKeys())
        wasAutoSortDown = anyKeyDown(autoSortKeys())
        return
    end

    local isPickDown = anyKeyDown(pickKeys())
    local isCancelDown = anyKeyDown(cancelKeys())
    local isAutoSortDown = anyKeyDown(autoSortKeys())

    if not wasListOpen then
        wasListOpen = true
        wasPickDown = isPickDown
        wasCancelDown = isCancelDown
        wasAutoSortDown = isAutoSortDown
        pickedSkillId = nil
        return
    end

    local pickPressed = isPickDown and not wasPickDown
    local cancelPressed = isCancelDown and not wasCancelDown
    local autoSortPressed = isAutoSortDown and not wasAutoSortDown

    wasPickDown = isPickDown
    wasCancelDown = isCancelDown
    wasAutoSortDown = isAutoSortDown

    -- 0. Handle Auto Sort (G / Y-Triangle, pressed twice to confirm)
    if autoSortPressed then
        local now = os.clock()
        if autoSortArmedAt and now - autoSortArmedAt <= AUTO_SORT_CONFIRM_SEC then
            autoSortArmedAt = nil
            pickedSkillId = nil
            local baseIds = store.data[unitKey]
            if not baseIds or #baseIds == 0 then
                baseIds = {}
                for _, id in ipairs(currentActionIds) do
                    if not isCommand(id) then table.insert(baseIds, id) end
                end
            end
            store.data[unitKey] = autoSortedOrder(baseIds)
            saveStore()
            local updatedIds = getSortedIds(unitKey, currentActionIds, false)
            applyOrderToUI(vm, listWidget, updatedIds)
            focusToIndex(menu, 0)
            mod:notice("Skills auto-sorted by type and power!", "on", 1500)
        else
            autoSortArmedAt = now
            mod:notice("Press " .. (cfg.AutoSortKey or "G") .. " / Y again to auto-sort (replaces this character's order).", "warn", 2500)
        end
        return
    end
    if autoSortArmedAt and os.clock() - autoSortArmedAt > AUTO_SORT_CONFIRM_SEC then
        autoSortArmedAt = nil
    end

    -- 1. Handle Cancel (C / B-Circle)
    if cancelPressed and pickedSkillId then
        pickedSkillId = nil
        mod:notice("Sort cancelled.", "warn", 1000)
        return
    end

    -- 2. Handle Pick/Drop (R / X-Square — avoids conflicting with F casting field skills like Cure)
    if pickPressed then
        local focusedIdx = getFocusedIndex(menu)
        if not focusedIdx then return end

        local targetId = currentActionIds[focusedIdx + 1]
        if not targetId then return end

        if not pickedSkillId then
            pickedSkillId = targetId
            mod:notice("Picked up skill. Highlight target & press " .. (cfg.PickDropKey or "R") .. " / X to place.", "on", 2000)
        else
            if pickedSkillId == targetId then
                pickedSkillId = nil
                mod:notice("Sort cancelled.", "warn", 1000)
                return
            end

            local fromIdx = indexOf(currentActionIds, pickedSkillId)
            local toIdx = focusedIdx + 1
            local pId = pickedSkillId
            pickedSkillId = nil

            if fromIdx then
                moveSkill(unitKey, pId, targetId, fromIdx < toIdx, currentActionIds)
                local updatedIds = getSortedIds(unitKey, currentActionIds, false)
                applyOrderToUI(vm, listWidget, updatedIds)

                local newIdx = indexOf(updatedIds, pId)
                if newIdx then
                    focusToIndex(menu, newIdx - 1)
                end
                mod:notice("Skill placed and saved!", "on", 1000)
            end
        end
    end
end

-------------------------------------------------------------------------------
-- BATTLE MENU (AUTO-APPLY SAVED ORDER + LIVE CATEGORY FILTER PAGES [Q / E or LB / RB])
-------------------------------------------------------------------------------
local BATTLE_PAGES = {
    { id = "ALL",      label = "All" },
    { id = "PHYSICAL", label = "Physical" },
    { id = "HEAL",     label = "Heal" },
    { id = "MAGIC",    label = "Magic" },
    { id = "SUPPORT",  label = "Buff / Debuff" },
    { id = "OTHER",    label = "Other" },
}

local loggedBattleSort = {}
local battleListCache = {}  -- listAddr -> { unitKey, customEntries, entryClass, entryOuter, pageIdx, lastAppliedIds, wasFocused, restoreLockUntil }
local lastBattleCursor = {} -- unitKey -> { pageIdx, skillId } (persists across turns/battles when Remember Cursor is ON)
local wasPrevDown = false
local wasNextDown = false
local cachedSoundFn = nil   -- { obj, fn, usePc }

-- Check whether the game's "Remember Cursor Location" setting is enabled
local function isRememberCursorEnabled(actionList)
    local foundOpt, optVal = false, false

    -- 1. Check CPP_MuchaOptionSaveData.m_EntrySaveDataList for any Cursor / Command Memory option
    pcall(function()
        local mgr = FindFirstOf("CPP_MuchaSaveDataManager")
        local opt = kit.valid(mgr) and mgr.m_pOptionSaveData
        if kit.valid(opt) and opt.m_EntrySaveDataList then
            opt.m_EntrySaveDataList:ForEach(function(k, v)
                local okT, tag = pcall(function() return k:get().TagName:ToString():lower() end)
                if okT and tag and (tag:find("cursor", 1, true) or (tag:find("command", 1, true) and (tag:find("memory", 1, true) or tag:find("remember", 1, true) or tag:find("save", 1, true)))) then
                    local okV, val = pcall(function() return v:get().Value end)
                    if okV and type(val) == "number" then
                        foundOpt = true
                        optVal = (val ~= 0)
                    end
                end
            end)
        end
    end)
    if foundOpt then return optVal end

    -- 2. Fallback: check BtlCmdDA.bIsEnableSaveListIndex on the active battle VM
    local enabled = true
    pcall(function()
        local vm = kit.valid(actionList) and actionList.VM_BtlCmd
        local da = kit.valid(vm) and vm.BtlCmdDA
        if kit.valid(da) and da.bIsEnableSaveListIndex ~= nil then
            enabled = (da.bIsEnableSaveListIndex == true)
        end
    end)
    return enabled
end

-- Read the skill ID currently highlighted in the battle skill list
local function getFocusedBattleSkillId(actionList, pm, lv, currentIds)
    local sid = 0

    -- 1. Live Slate focus on displayed ListView entry widgets (ground truth of highlighted row)
    if kit.valid(lv) then
        pcall(function()
            local displayed = lv:GetDisplayedEntryWidgets()
            if displayed then
                local list = {}
                if type(displayed) == "table" then
                    for _, v in ipairs(displayed) do
                        local okU, o = pcall(function() return v:get() end)
                        o = okU and o or v
                        if kit.valid(o) then list[#list + 1] = o end
                    end
                else
                    displayed:ForEach(function(_, v)
                        local o = v:get()
                        if kit.valid(o) then list[#list + 1] = o end
                    end)
                end
                local entryLib = StaticFindObject("/Script/UMG.Default__UserObjectListEntryLibrary")
                for _, w in ipairs(list) do
                    if isWidgetFocused(w) and kit.valid(entryLib) then
                        local item = entryLib:GetListItemObject(w)
                        if kit.valid(item) then
                            local id = num(item.ActionKey.ID)
                            if id > 0 and indexOf(currentIds, id) then
                                sid = id
                                return
                            end
                        end
                    end
                end
            end
        end)
    end
    if sid > 0 then return sid end

    -- 2. Live FocusCmdData on VM_BtlCmd
    pcall(function()
        local vm = kit.valid(actionList) and actionList.VM_BtlCmd
        if kit.valid(vm) and vm.FocusCmdData and vm.FocusCmdData.Value and vm.FocusCmdData.Value.ActionKey then
            local cat = num(vm.FocusCmdData.Value.ActionKey.Category)
            local id = num(vm.FocusCmdData.Value.ActionKey.ID)
            if cat == 1 and id > 0 and indexOf(currentIds, id) then
                sid = id
            end
        end
    end)
    if sid > 0 then return sid end

    -- 3. Fallback: focused index on PathMenu
    local idx = getFocusedIndex(pm)
    if idx and currentIds[idx + 1] then
        return currentIds[idx + 1]
    end
    return nil
end

-- Read the game's saved last battle actionId for a unit (used if Remember Cursor is ON
-- before we have seen the unit pick a skill in the current session)
local function getSavedBattleActionId(unitId)
    local foundId = nil
    pcall(function()
        local sd = kit.game and kit.game.saveData and kit.game.saveData()
        if not kit.valid(sd) or not sd.unitParameterList then return end
        for i = 1, #sd.unitParameterList do
            local u = sd.unitParameterList[i]
            if u.UnitId == unitId then
                local bundle = u.btlCmdData
                if bundle and bundle.cmdDataList and #bundle.cmdDataList > 0 then
                    local cmd = bundle.cmdDataList[1]
                    if not cmd.isUseItem and cmd.actionId and cmd.actionId > 0 then
                        foundId = cmd.actionId
                    end
                end
                break
            end
        end
    end)
    return foundId
end

local function focusBattleIndex(actionList, pm, lv, idx0)
    idx0 = math.max(0, idx0 or 0)
    pcall(function()
        local vm = kit.valid(actionList) and actionList.VM_BtlCmd
        if kit.valid(vm) and vm.CurrentFocusListIndex ~= nil then
            vm.CurrentFocusListIndex = idx0
        end
    end)
    if kit.valid(lv) then
        pcall(function() lv:ScrollIndexIntoView(idx0) end)
        pcall(function() lv:SetSelectedIndex(idx0) end)
        pcall(function() lv:NavigateToIndex(idx0) end)
    end
    if kit.valid(pm) then
        focusToIndex(pm, idx0)
    end
end

-- Play the native combat menu selection "beep" using SelectSoundTag from Battle Command DA
local function playMenuBeep(actionList)
    local tag = nil
    pcall(function()
        local vm = kit.valid(actionList) and actionList.VM_BtlCmd
        local usvm = kit.valid(vm) and vm.UnitSelectVM
        local usda = kit.valid(usvm) and usvm.UnitSelectDA
        if kit.valid(usda) and usda.SelectSoundTag then
            tag = usda.SelectSoundTag
        end
    end)
    if not tag then
        tag = { TagName = FName("Sound.UI.Common.Select") }
    end

    local pc = kit.game and kit.game.playerController and kit.game.playerController()

    if cachedSoundFn and kit.valid(cachedSoundFn.obj) then
        local ok = pcall(function()
            if cachedSoundFn.usePc and pc then
                cachedSoundFn.obj[cachedSoundFn.fn](cachedSoundFn.obj, pc, tag)
            else
                cachedSoundFn.obj[cachedSoundFn.fn](cachedSoundFn.obj, tag)
            end
        end)
        if ok then return true end
        cachedSoundFn = nil
    end

    local bfl = kit.game and kit.game.lib and kit.game.lib("CPP_BFL_Sound")
    local sub = FindFirstOf("CPP_SoundSubsystem")

    for _, obj in ipairs({ bfl, sub }) do
        if kit.valid(obj) then
            for _, fn in ipairs({ "PlaySoundByTag", "PlaySEByTag", "PlaySound", "PlaySE", "PlayUISound" }) do
                if obj[fn] then
                    if pc and pcall(function() obj[fn](obj, pc, tag) end) then
                        cachedSoundFn = { obj = obj, fn = fn, usePc = true }
                        return true
                    end
                    if pcall(function() obj[fn](obj, tag) end) then
                        cachedSoundFn = { obj = obj, fn = fn, usePc = false }
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function skillPageId(skillId)
    local info = loadSkillInfo()
    local s = info and info[skillId]
    if not s then return "OTHER" end
    if s.group == GROUP.PHYSICAL then return "PHYSICAL" end
    if s.group == GROUP.HEAL then return "HEAL" end
    if s.group == GROUP.MAGIC then return "MAGIC" end
    if s.group == GROUP.BUFF or s.group == GROUP.DEBUFF then return "SUPPORT" end
    return "OTHER"
end

local function sameIdList(a, b)
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function readListViewItems(lv)
    local items = {}
    if not kit.valid(lv) then return items end
    local okG, rawItems = pcall(function() return lv:GetListItems() end)
    if okG and rawItems then
        if type(rawItems) == "table" then
            for _, v in ipairs(rawItems) do
                local okU, o = pcall(function() return v:get() end)
                o = okU and o or v
                if kit.valid(o) then items[#items + 1] = o end
            end
        else
            pcall(function()
                rawItems:ForEach(function(_, v)
                    local o = v:get()
                    if kit.valid(o) then items[#items + 1] = o end
                end)
            end)
        end
    end
    return items
end

local function getActiveBattleUnitId()
    local headers = FindAllOf("WBP_BtlCmd_ListHeader_C") or {}
    for i = #headers, 1, -1 do
        local h = headers[i]
        if kit.valid(h) and not h:GetFullName():find("Default__", 1, true) then
            local ok, uid = pcall(function()
                if not h:IsVisible() then return nil end
                local bup = h.CPP_VM_BtlUnitParam
                if kit.valid(bup) then
                    local id = num(bup.UnitId)
                    if id and id > 0 then return id end
                end
            end)
            if ok and uid and uid > 0 then return uid end
        end
    end

    local primaries = FindAllOf("WBP_BtlCmd_PrimaryList_C") or {}
    for i = #primaries, 1, -1 do
        local p = primaries[i]
        if kit.valid(p) and not p:GetFullName():find("Default__", 1, true) then
            local ok, uid = pcall(function()
                if not p:IsVisible() then return nil end
                local h = p.WBP_BtlCmd_ListHeader
                local bup = kit.valid(h) and h.CPP_VM_BtlUnitParam
                if kit.valid(bup) then
                    local id = num(bup.UnitId)
                    if id and id > 0 then return id end
                end
            end)
            if ok and uid and uid > 0 then return uid end
        end
    end

    return nil
end

local function findListView(widget)
    if not kit.valid(widget) then return nil end
    local found = nil
    pcall(function()
        if kit.valid(widget.CmnListView) then
            found = widget.CmnListView
        elseif kit.valid(widget.ListView) then
            found = widget.ListView
        elseif widget.GetListItems or widget.RequestRefresh then
            found = widget
        elseif kit.ui and kit.ui.walk and widget.WidgetTree and kit.valid(widget.WidgetTree.RootWidget) then
            found = kit.ui.walk(widget.WidgetTree.RootWidget, function(w)
                local cn = w:GetClass():GetName()
                return cn == "ListView" or cn == "CommonListView" or cn:find("ListView", 1, true) ~= nil
            end)
        end
    end)
    return found
end

local function readPathMenuItems(pm)
    local items = {}
    if not kit.valid(pm) then return items end
    pcall(function()
        local arr = pm.ListItems
        if not arr then return end
        for i = 1, #arr do
            local it = arr[i]
            if type(it) == "userdata" and not it.IsValid then
                local okG, g = pcall(function() return it:get() end)
                if okG then it = g end
            end
            if kit.valid(it) then items[#items + 1] = it end
        end
    end)
    return items
end

local function filterEntriesForPage(fullEntries, pageId)
    if pageId == "ALL" then return fullEntries end
    local out = {}
    for _, e in ipairs(fullEntries) do
        if isCommand(e.id) or skillPageId(e.id) == pageId then
            out[#out + 1] = e
        end
    end
    return out
end

local function getBattlePathMenu(actionList)
    if not kit.valid(actionList) then return nil end
    local pm = nil
    pcall(function()
        if kit.valid(actionList.WBP_ListViewBase) then
            pm = actionList.WBP_ListViewBase
        elseif kit.valid(actionList.PathMenu) then
            pm = actionList.PathMenu
        end
    end)
    return pm
end

-- Update native subhead/title text on WBP_BtlCmd_SecondaryList_C if one exists (no floating banner)
local origSecTitles = {}
local function updateSecondaryHeaderTitle(actionList, pageLabel)
    pcall(function()
        local outer = actionList:GetOuter()
        local secList = nil
        local guard = 0
        while kit.valid(outer) and guard < 6 do
            guard = guard + 1
            local cn = ""
            pcall(function() cn = outer:GetClass():GetName() end)
            if cn == "WBP_BtlCmd_SecondaryList_C" then
                secList = outer
                break
            end
            outer = outer:GetOuter()
        end
        if not kit.valid(secList) or not (kit.ui and kit.ui.walk) then return end
        if not (secList.WidgetTree and kit.valid(secList.WidgetTree.RootWidget)) then return end

        local listAddr = actionList:GetAddress()
        local titleWidget = nil
        kit.ui.walk(secList.WidgetTree.RootWidget, function(w)
            if w:GetAddress() == listAddr then return false end
            local cn = ""
            pcall(function() cn = w:GetClass():GetName() end)
            if (cn == "CommonTextBlock" or cn == "TextBlock") then
                local fn = ""
                pcall(function() fn = w:GetFName():ToString():lower() end)
                if fn:find("title", 1, true) or fn:find("subhead", 1, true) or fn:find("header", 1, true) then
                    titleWidget = w
                    return true
                end
            end
            return false
        end)

        if kit.valid(titleWidget) then
            local tAddr = titleWidget:GetAddress()
            if not origSecTitles[tAddr] then
                local okT, txt = pcall(function() return titleWidget:GetText():ToString() end)
                if okT and txt and txt ~= "" then
                    origSecTitles[tAddr] = txt
                end
            end
            local base = origSecTitles[tAddr]
            if base then
                local label = (pageLabel == "All") and base or (base .. " - " .. pageLabel)
                titleWidget:SetText(FText(label))
            end
        end
    end)
end

-- GC-safe item resolver: reuses the cached BP_BtlCmdListEntry_C if still valid,
-- or constructs a fresh instance if Unreal's GC collected a filtered-out entry mid-battle.
local function getOrRebuildEntryObj(cache, lv, e, idx0)
    if kit.valid(e.obj) then
        pcall(function()
            e.obj.EntryIndex = idx0
            e.obj.ActionKey.Category = e.cat
            e.obj.ActionKey.ID = e.id
            if e.isValid ~= nil then e.obj["In Is Valid"] = e.isValid end
        end)
        return e.obj
    end

    local created = nil
    pcall(function()
        local cls = cache.entryClass
        if not kit.valid(cls) then
            cls = StaticFindObject("/Game/UI/Battle/Command/BP_BtlCmdListEntry.BP_BtlCmdListEntry_C")
        end
        local outer = kit.valid(cache.entryOuter) and cache.entryOuter or lv
        if kit.valid(cls) and kit.valid(outer) then
            created = StaticConstructObject(cls, outer)
            if kit.valid(created) then
                created.EntryIndex = idx0
                created.ActionKey.Category = e.cat
                created.ActionKey.ID = e.id
                if e.isValid ~= nil then created["In Is Valid"] = e.isValid end
            end
        end
    end)
    if kit.valid(created) then
        e.obj = created
        return created
    end
    return nil
end

local function applyBattleEntries(actionList, pm, lv, cache, entries, targetFocusIdx0, forceDelayedFocus)
    local count = #entries
    if count == 0 then return false end
    local focusIdx = math.min(math.max(0, targetFocusIdx0 or 0), count - 1)

    -- 1. Update ActionKeyList on WBP_BtlCmd_ActionList_C
    pcall(function()
        local akList = actionList.ActionKeyList
        if not akList then return end
        if #akList ~= count then
            akList:Empty()
            for i = 1, count do
                akList[i] = { Category = entries[i].cat, ID = entries[i].id }
            end
        else
            for i = 1, count do
                akList[i].Category = entries[i].cat
                akList[i].ID = entries[i].id
            end
        end
    end)

    -- 2. Update ListObject.ActionKeyList if present
    pcall(function()
        local lo = actionList.ListObject
        if kit.valid(lo) and lo.ActionKeyList then
            local lak = lo.ActionKeyList
            if #lak ~= count then
                lak:Empty()
                for i = 1, count do
                    lak[i] = { Category = entries[i].cat, ID = entries[i].id }
                end
            else
                for i = 1, count do
                    lak[i].Category = entries[i].cat
                    lak[i].ID = entries[i].id
                end
            end
        end
    end)

    -- 3. Build the GC-safe list of BP_BtlCmdListEntry_C objects for this page,
    --    sync both PathMenu.ListItems and CmnListView via ClearListItems + SetListItems.
    pcall(function()
        local reordered = {}
        for i = 1, count do
            local obj = getOrRebuildEntryObj(cache, lv, entries[i], i - 1)
            if kit.valid(obj) then
                reordered[#reordered + 1] = obj
            end
        end

        if #reordered == count then
            if kit.valid(pm) and pm.ListItems then
                pcall(function()
                    pm.ListItems:Empty()
                    for i, obj in ipairs(reordered) do
                        pm.ListItems[i] = obj
                    end
                end)
            end

            if kit.valid(lv) then
                pcall(function() lv:ClearListItems() end)
                local okSet = pcall(function() lv:SetListItems(reordered) end)
                if not okSet then
                    pcall(function()
                        for _, obj in ipairs(reordered) do
                            lv:AddItem(obj)
                        end
                    end)
                end
                pcall(function() lv:RegenerateAllEntries() end)
                pcall(function() lv:RequestRefresh() end)
            end
        elseif kit.valid(lv) then
            pcall(function() lv:RegenerateAllEntries() end)
            pcall(function() lv:RequestRefresh() end)
        end

        focusBattleIndex(actionList, pm, lv, focusIdx)
        -- Re-apply focus after one Slate layout tick in case RegenerateAllEntries or
        -- the game's native cursor memory moves the highlight on the next frame
        if (forceDelayedFocus or focusIdx > 0) and kit.after then
            local savedAl, savedPm, savedLv, savedIdx = actionList, pm, lv, focusIdx
            kit.after(50, function()
                focusBattleIndex(savedAl, savedPm, savedLv, savedIdx)
            end, "battleFocusRestore")
        end
    end)

    return true
end

local function reorderEntriesByIds(rawEntries, orderedIds)
    local buckets = {}
    for _, e in ipairs(rawEntries) do
        buckets[e.id] = buckets[e.id] or {}
        table.insert(buckets[e.id], e)
    end
    local out = {}
    for i = 1, #orderedIds do
        local q = buckets[orderedIds[i]]
        if q and #q > 0 then
            out[#out + 1] = table.remove(q, 1)
        end
    end
    return out
end

-- Returns the entry list for a given page, preserving each character's Pause Menu order
-- (manual custom order, Auto-Sort order if used, or default game order if untouched).
local function entriesForBattlePage(cache, pageId)
    return filterEntriesForPage(cache.customEntries, pageId)
end

local function processBattleActionList(actionList, unitId, unitKey, pageDelta)
    if not kit.valid(actionList) then return false end

    -- Skip Item lists
    local isItemList = false
    pcall(function()
        local lo = actionList.ListObject
        if kit.valid(lo) and lo:GetFullName():find("Item", 1, true) then
            isItemList = true
        end
    end)
    if isItemList then return false end

    local pm = getBattlePathMenu(actionList)
    local lv = findListView(actionList.WBP_ListViewBase)

    local currentIds = {}
    local currentCats = {}
    local currentValids = {}
    local currentObjs = {}
    local hasSortableSkill = false

    local lvItems = readListViewItems(lv)
    if #lvItems == 0 then
        lvItems = readPathMenuItems(pm)
    end

    if #lvItems > 0 then
        for i, item in ipairs(lvItems) do
            local okAk, cat, id, isVal = pcall(function()
                return num(item.ActionKey.Category), num(item.ActionKey.ID), item["In Is Valid"]
            end)
            if okAk and id and id > 0 then
                currentIds[#currentIds + 1] = id
                currentCats[#currentCats + 1] = cat
                currentValids[#currentValids + 1] = isVal
                currentObjs[#currentObjs + 1] = item
                if cat == 1 and not isCommand(id) then
                    hasSortableSkill = true
                end
            end
        end
    end

    if not hasSortableSkill then
        currentIds, currentCats, currentValids, currentObjs = {}, {}, {}, {}
        pcall(function()
            local akList = actionList.ActionKeyList
            if akList then
                for i = 1, #akList do
                    local cat = num(akList[i].Category)
                    local id = num(akList[i].ID)
                    currentIds[i] = id
                    currentCats[i] = cat
                    currentValids[i] = true
                    currentObjs[i] = lvItems[i]
                    if cat == 1 and not isCommand(id) then
                        hasSortableSkill = true
                    end
                end
            end
        end)
    end

    if #currentIds == 0 or not hasSortableSkill then return false end

    local listAddr = nil
    pcall(function() listAddr = actionList:GetAddress() end)
    local cacheKey = tostring(listAddr or actionList:GetFullName())
    local cache = battleListCache[cacheKey]

    local needsSnapshot = (not cache)
        or (cache.unitKey ~= unitKey)
        or (not sameIdList(currentIds, cache.lastAppliedIds))

    -- Check whether this skill list currently has Slate focus
    local isFocused = false
    pcall(function()
        isFocused = actionList:HasFocusedDescendants() or actionList:HasAnyUserFocus()
    end)
    if not isFocused and kit.valid(pm) then
        pcall(function() isFocused = pm:HasFocusedDescendants() or pm:HasAnyUserFocus() end)
    end
    if not isFocused and kit.valid(lv) then
        pcall(function() isFocused = lv:HasFocusedDescendants() or lv:HasAnyUserFocus() end)
    end

    local rememberOn = isRememberCursorEnabled(actionList)
    local restoreSkillId = nil
    local justFocused = false

    if needsSnapshot then
        local rawEntries = {}
        local entryClass, entryOuter = nil, nil
        for i = 1, #currentIds do
            local obj = currentObjs[i]
            if not entryClass and kit.valid(obj) then
                pcall(function()
                    entryClass = obj:GetClass()
                    entryOuter = obj:GetOuter()
                end)
            end
            rawEntries[i] = {
                id = currentIds[i],
                cat = currentCats[i],
                isValid = currentValids[i],
                obj = obj,
            }
        end

        -- Build the character's Pause Menu order (custom order if saved, else natural game order)
        local customEntries = rawEntries
        if store.data[unitKey] and #store.data[unitKey] > 0 then
            local sortedIds = getSortedIds(unitKey, currentIds, false)
            customEntries = reorderEntriesByIds(rawEntries, sortedIds)
        end

        -- Restore last page & skill when the game's "Remember Cursor Location" setting is ON
        local initialPageIdx = 1
        if rememberOn then
            local mem = lastBattleCursor[unitKey]
            if mem then
                if cfg.PaginatedAbilities and mem.pageIdx and BATTLE_PAGES[mem.pageIdx] then
                    initialPageIdx = mem.pageIdx
                end
                restoreSkillId = mem.skillId
            else
                -- First turn of the session: check the game's saved last actionId for this unit
                restoreSkillId = getSavedBattleActionId(unitId)
            end
        end

        cache = {
            unitKey = unitKey,
            customEntries = customEntries,
            entryClass = entryClass,
            entryOuter = entryOuter,
            pageIdx = initialPageIdx,
            lastAppliedIds = nil,
            wasFocused = false,
            restoreLockUntil = 0,
        }
        battleListCache[cacheKey] = cache
    else
        justFocused = isFocused and not cache.wasFocused
        -- If the list just received focus again (e.g., list was pre-populated before focus,
        -- same unit acted again without list rebuild, or returned from target selection),
        -- re-sync the remembered page & skill when Remember Cursor is ON.
        if justFocused and rememberOn and pageDelta == 0 then
            local mem = lastBattleCursor[unitKey]
            if mem then
                if cfg.PaginatedAbilities and mem.pageIdx and BATTLE_PAGES[mem.pageIdx] then
                    cache.pageIdx = mem.pageIdx
                end
                restoreSkillId = mem.skillId
            end
        end
    end

    local canPage = pageDelta ~= 0 and cfg.PaginatedAbilities and isFocused

    local switchedPage = false
    if not cfg.PaginatedAbilities then
        cache.pageIdx = 1
    elseif canPage and #cache.customEntries > 0 then
        local n = #BATTLE_PAGES
        local idx = cache.pageIdx
        for _ = 1, n do
            idx = ((idx - 1 + pageDelta) % n) + 1
            local page = BATTLE_PAGES[idx]
            local subset = entriesForBattlePage(cache, page.id)
            if #subset > 0 then
                if idx ~= cache.pageIdx then
                    cache.pageIdx = idx
                    switchedPage = true
                    restoreSkillId = nil
                end
                break
            end
        end
    end

    local page = BATTLE_PAGES[cache.pageIdx] or BATTLE_PAGES[1]
    local targetEntries = entriesForBattlePage(cache, page.id)
    if #targetEntries == 0 then
        cache.pageIdx = 1
        page = BATTLE_PAGES[1]
        targetEntries = entriesForBattlePage(cache, page.id)
    end

    local targetIds = {}
    for i, e in ipairs(targetEntries) do targetIds[i] = e.id end

    -- Compute desired cursor index (restored skill when reopening with Remember Cursor ON, else 0)
    local targetFocusIdx0 = 0
    local hasRestoredTarget = false
    if not switchedPage and restoreSkillId then
        local pos = indexOf(targetIds, restoreSkillId)
        if pos then
            targetFocusIdx0 = pos - 1
            hasRestoredTarget = true
        end
    end

    local needApply = switchedPage or needsSnapshot or not sameIdList(currentIds, targetIds)
    if needApply then
        local lockFocus = switchedPage or hasRestoredTarget
        applyBattleEntries(actionList, pm, lv, cache, targetEntries, targetFocusIdx0, lockFocus)
        cache.lastAppliedIds = targetIds
        if lockFocus then
            cache.restoreLockUntil = os.clock() + 0.09
        end
        updateSecondaryHeaderTitle(actionList, page.label)

        if switchedPage then
            playMenuBeep(actionList)
            lastBattleCursor[unitKey] = { pageIdx = cache.pageIdx, skillId = targetIds[1] }
            mod:log(string.format("Battle page -> %s (%d skills) for unit %s.", page.label, #targetEntries, unitKey))
        else
            local logKey = unitKey .. "|" .. actionList:GetFullName()
            if not loggedBattleSort[logKey] then
                loggedBattleSort[logKey] = true
                mod:log(string.format("Applied saved skill order in battle for unit %s (%d skills).", unitKey, #targetEntries))
            end
        end
    elseif justFocused and hasRestoredTarget then
        focusBattleIndex(actionList, pm, lv, targetFocusIdx0)
        if kit.after then
            local savedAl, savedPm, savedLv, savedIdx = actionList, pm, lv, targetFocusIdx0
            kit.after(50, function()
                focusBattleIndex(savedAl, savedPm, savedLv, savedIdx)
            end, "battleFocusRestore")
        end
        cache.restoreLockUntil = os.clock() + 0.09
    else
        cache.lastAppliedIds = targetIds
        -- Continuously remember the currently highlighted skill & page while this list has focus
        if isFocused and os.clock() >= (cache.restoreLockUntil or 0) then
            local focusedSid = getFocusedBattleSkillId(actionList, pm, lv, currentIds)
            if focusedSid and focusedSid > 0 then
                lastBattleCursor[unitKey] = { pageIdx = cache.pageIdx, skillId = focusedSid }
            end
        end
    end

    cache.wasFocused = isFocused
    return switchedPage
end

local function handleBattleSorting()
    if not mod.enabled then return end
    if kit.events and not kit.events.battle then
        if next(loggedBattleSort) then loggedBattleSort = {} end
        if next(battleListCache) then battleListCache = {} end
        if next(origSecTitles) then origSecTitles = {} end
        wasPrevDown = anyKeyDown(prevPageKeys())
        wasNextDown = anyKeyDown(nextPageKeys())
        return
    end

    local unitId = getActiveBattleUnitId()
    if not unitId or unitId <= 0 then
        wasPrevDown = anyKeyDown(prevPageKeys())
        wasNextDown = anyKeyDown(nextPageKeys())
        return
    end
    local unitKey = tostring(unitId)

    local isPrevDown = anyKeyDown(prevPageKeys())
    local isNextDown = anyKeyDown(nextPageKeys())
    local prevPressed = isPrevDown and not wasPrevDown
    local nextPressed = isNextDown and not wasNextDown
    wasPrevDown = isPrevDown
    wasNextDown = isNextDown

    local pageDelta = 0
    if cfg.PaginatedAbilities then
        if prevPressed then pageDelta = -1
        elseif nextPressed then pageDelta = 1 end
    end

    local lists = FindAllOf("WBP_BtlCmd_ActionList_C") or {}
    for i = #lists, 1, -1 do
        local actionList = lists[i]
        if kit.valid(actionList) and not actionList:GetFullName():find("Default__", 1, true) then
            local vis = false
            pcall(function() vis = actionList:IsVisible() end)
            if vis then
                if processBattleActionList(actionList, unitId, unitKey, pageDelta) then
                    pageDelta = 0 -- consume Q/E or LB/RB on the focused skill list
                end
            else
                local listAddr = nil
                pcall(function() listAddr = actionList:GetAddress() end)
                local ck = tostring(listAddr or actionList:GetFullName())
                if battleListCache[ck] then
                    battleListCache[ck].wasFocused = false
                end
            end
        end
    end
end

mod:on("saveLoaded", function()
    lastBattleCursor = {}
    battleListCache = {}
end)

mod:every(50, handlePauseMenuSorting, "handlePauseMenuSorting")
mod:every(50, handleBattleSorting, "handleBattleSorting")
