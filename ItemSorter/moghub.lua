local mod, kit = ...

-- Mods menu settings (expand "Item Sorter" with Confirm in Main Menu > Mods;
-- keyboard keybinds can also be customized in ItemSorter/config.ini)
local cfg = mod:settings{
    {
        key = "AutoSortMode",
        label = "Auto-Sort Mode",
        type = "choice",
        default = "alpha",
        choices = {
            { "alpha",    "Alphabetical (A-Z)" },
            { "type",     "Type & Power" },
            { "quantity", "Quantity (High-Low)" },
            { "price",    "Value / Price (High-Low)" },
            { "vanilla",  "Vanilla" },
        },
        help = "Sort order applied when double-tapping G / Y (Triangle) in Pause Menu > Items. All non-Vanilla modes stay grouped by category.",
    },
    {
        key = "SortEquipPicker",
        label = "Sort Equipment Picker",
        type = "toggle",
        default = true,
        help = "Apply your saved item order (or selected Auto-Sort Mode) inside the Equipment & Abilities weapon, armor, and accessory picker.",
    },
    {
        key = "PaginatedBattleItems",
        label = "Paginated Battle Items",
        type = "toggle",
        default = true,
        help = "In combat, press Q / E (or LB / RB on controller) inside the Item / Throw menu to page through All, Heal / Revive, Status Cure, Offensive / Throw, and Other.",
    },
    { key = "PickDropKey", type = "value", default = "R" },
    { key = "CancelKey",   type = "value", default = "C" },
    { key = "AutoSortKey", type = "value", default = "G" },
    { key = "PrevPageKey", type = "value", default = "Q" },
    { key = "NextPageKey", type = "value", default = "E" },
}

-- JSON file for persisting custom item order per save slot
local store = mod:store("ItemOrder")
local orderVersion = 0

cfg:onChange(function(key)
    if key == "AutoSortMode" or key == "SortEquipPicker" or key == "PaginatedBattleItems" then
        orderVersion = orderVersion + 1
    end
end)

local AUTO_SORT_CONFIRM_SEC = 3

local MODE_LABELS = {
    alpha    = "Alphabetical (A-Z)",
    type     = "Type & Power",
    quantity = "Quantity (High-Low)",
    price    = "Value / Price (High-Low)",
    vanilla  = "Vanilla",
}

local function modeLabel(m)
    return MODE_LABELS[m] or "Alphabetical (A-Z)"
end

-------------------------------------------------------------------------------
-- SHARED HELPERS
-------------------------------------------------------------------------------
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

local function sameIdList(a, b)
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function safeCall(obj, fn, ...)
    if not kit.valid(obj) then return false, nil end
    local args = { ... }
    return pcall(function() return obj[fn](obj, table.unpack(args)) end)
end

local function num(v)
    if type(v) == "number" then return v end
    if v == nil then return 0 end
    local ok, x = pcall(function() return v:get() end)
    if ok and type(x) == "number" then return x end
    return tonumber(tostring(v)) or 0
end

local function className(obj)
    if not kit.valid(obj) then return "" end
    local ok, s = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return (ok and type(s) == "string") and s or ""
end

local function textStr(v)
    if v == nil then return "" end
    if type(v) == "string" then return v end
    local ok, s = pcall(function()
        if type(v.ToString) == "function" then return v:ToString() end
        if type(v.get) == "function" then
            local inner = v:get()
            if type(inner) == "string" then return inner end
            if inner and type(inner.ToString) == "function" then return inner:ToString() end
            return tostring(inner)
        end
        return tostring(v)
    end)
    return (ok and type(s) == "string") and s or ""
end

local function saveStore()
    local slot = store.slot or (kit.events and kit.events.slot)
    if slot ~= nil then
        store:save(slot)
    end
end

local function getSavedOrder()
    if store.data and type(store.data.order) == "table" and #store.data.order > 0 then
        return store.data.order
    end
    return nil
end

-------------------------------------------------------------------------------
-- FOCUS & LISTVIEW UTILITIES
-------------------------------------------------------------------------------
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
    pcall(function()
        if not hit and kit.valid(w.WBP_PathButton) then
            hit = hit or w.WBP_PathButton:HasAnyUserFocus() or w.WBP_PathButton:HasFocusedDescendants()
        end
    end)
    return hit
end

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

local function getFocusedIndex(menu)
    ensureFocusHooks()
    if not kit.valid(menu) then return nil end

    for _, fn in ipairs({ "GetFocuedItemIndex", "GetFocusedItemIndex", "GetFocuedIndex", "GetFocusedIndex" }) do
        local ok, idx = safeCall(menu, fn, 0)
        if ok and type(idx) == "number" and idx >= 0 then return idx end
        local ok2, idx2 = safeCall(menu, fn)
        if ok2 and type(idx2) == "number" and idx2 >= 0 then return idx2 end
    end

    local entries = getMenuEntryWidgets(menu)
    if #entries > 0 then
        for i, w in ipairs(entries) do
            if isWidgetFocused(w) then return i - 1 end
        end

        for _, fn in ipairs({ "GetFocuedItemWidget", "GetFocusedItemWidget" }) do
            local okW, fw = safeCall(menu, fn, 0)
            if not (okW and kit.valid(fw)) then okW, fw = safeCall(menu, fn) end
            if okW and kit.valid(fw) then
                local fwAddr = nil
                pcall(function() fwAddr = fw:GetAddress() end)
                for i, w in ipairs(entries) do
                    local match = false
                    pcall(function()
                        match = (fwAddr and w:GetAddress() == fwAddr)
                            or (w:GetFName():ToString() == fw:GetFName():ToString())
                    end)
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

    local found = nil
    pcall(function()
        if menu.FocuedItemDataMap then
            menu.FocuedItemDataMap:ForEach(function(k, v)
                if num(k) == 0 then
                    local itemData = v:get()
                    found = itemData.Index
                end
            end)
        end
    end)
    return found
end

local function focusToIndex(menu, targetIdx)
    if not kit.valid(menu) then return end
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

local function isRealListViewClass(cn)
    if not cn or cn == "" then return false end
    local l = cn:lower()
    if l:find("menu", 1, true) then return false end
    return l == "listview" or l == "commonlistview" or l:find("listview", 1, true) ~= nil
end

local function findListView(widget)
    if not kit.valid(widget) then return nil end
    local found = nil
    pcall(function()
        if kit.valid(widget.CmnListView) then
            found = widget.CmnListView
        elseif kit.valid(widget.ListView) then
            found = widget.ListView
        elseif kit.valid(widget.CommonListView) then
            found = widget.CommonListView
        elseif isRealListViewClass(className(widget)) then
            found = widget
        elseif kit.ui and kit.ui.walk and widget.WidgetTree and kit.valid(widget.WidgetTree.RootWidget) then
            found = kit.ui.walk(widget.WidgetTree.RootWidget, function(w)
                return isRealListViewClass(className(w))
            end)
        end
    end)
    return found
end

local function findListViewMenu(widget)
    if not kit.valid(widget) then return nil end
    local found = nil
    pcall(function()
        if widget.ListItems ~= nil or kit.valid(widget.CmnListView) or kit.valid(widget.ListView) or kit.valid(widget.DirectionGridPanel) then
            found = widget
        elseif kit.valid(widget.WBP_ListViewBase) then
            found = widget.WBP_ListViewBase
        elseif kit.valid(widget.PathMenu) then
            found = widget.PathMenu
        elseif kit.ui and kit.ui.walk and widget.WidgetTree and kit.valid(widget.WidgetTree.RootWidget) then
            found = kit.ui.walk(widget.WidgetTree.RootWidget, function(w)
                local cn = className(w)
                return cn == "WBP_ListViewMenu_C"
                    or cn:find("ListViewMenu", 1, true) ~= nil
                    or cn:find("DirectionGridMenu", 1, true) ~= nil
                    or w.ListItems ~= nil
            end)
        end
    end)
    return found or widget
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

local function getDisplayedWidgets(lv)
    local list = {}
    if not kit.valid(lv) then return list end
    pcall(function()
        local displayed = lv:GetDisplayedEntryWidgets()
        if not displayed then return end
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
    end)
    return list
end

-- Extract { id, cat, num, isValid } from any UI list item UObject
local function extractItemInfo(obj)
    if not kit.valid(obj) then return nil end
    local id, cat, cnt, isVal = 0, 2, nil, nil
    pcall(function()
        if obj.ActionKey then
            id = num(obj.ActionKey.ID)
            cat = num(obj.ActionKey.Category)
        end
    end)
    if id <= 0 then
        pcall(function()
            if obj.InventoryActionData and obj.InventoryActionData.ActionKey then
                id = num(obj.InventoryActionData.ActionKey.ID)
                cat = num(obj.InventoryActionData.ActionKey.Category)
                cnt = num(obj.InventoryActionData.Num)
            end
        end)
    end
    if id <= 0 then
        pcall(function()
            if obj.ActionData and obj.ActionData.ActionKey then
                id = num(obj.ActionData.ActionKey.ID)
                cat = num(obj.ActionData.ActionKey.Category)
                cnt = num(obj.ActionData.TmpNum)
            end
        end)
    end
    if id <= 0 then
        pcall(function()
            if obj.SkillActionData and obj.SkillActionData.ActionKey then
                id = num(obj.SkillActionData.ActionKey.ID)
                cat = num(obj.SkillActionData.ActionKey.Category)
                cnt = num(obj.SkillActionData.TmpNum)
            end
        end)
    end
    if id <= 0 then
        pcall(function()
            if obj.WBP_ActionEntryBase and obj.WBP_ActionEntryBase.ActionKey then
                id = num(obj.WBP_ActionEntryBase.ActionKey.ID)
                cat = num(obj.WBP_ActionEntryBase.ActionKey.Category)
            end
        end)
    end
    if id <= 0 then
        pcall(function()
            if obj.ItemId ~= nil then id = num(obj.ItemId)
            elseif obj.ItemID ~= nil then id = num(obj.ItemID)
            elseif obj.ItemData and obj.ItemData.ID ~= nil then id = num(obj.ItemData.ID)
            elseif obj.ID ~= nil then id = num(obj.ID)
            end
        end)
    end
    pcall(function()
        if obj["In Is Valid"] ~= nil then isVal = obj["In Is Valid"] end
        if cnt == nil then
            if obj.Num ~= nil then cnt = num(obj.Num)
            elseif obj.TmpNum ~= nil then cnt = num(obj.TmpNum)
            elseif obj.ItemNum ~= nil then cnt = num(obj.ItemNum)
            end
        end
    end)
    return { id = id, cat = cat, num = cnt, isValid = isVal }
end

local function setItemObjectIndex(obj, idx0)
    if not kit.valid(obj) then return end
    pcall(function()
        if obj.EntryIndex ~= nil then obj.EntryIndex = idx0 end
    end)
    pcall(function()
        if obj.ItemIndex ~= nil then obj.ItemIndex = idx0 end
    end)
end

local function findDisplayedEntryWidgetByItem(lv, idx0, targetItemId)
    if not kit.valid(lv) then return nil end
    local entryLib = StaticFindObject("/Script/UMG.Default__UserObjectListEntryLibrary")
    if not kit.valid(entryLib) then return nil end
    local fallback = nil
    for _, w in ipairs(getDisplayedWidgets(lv)) do
        local ok, item = pcall(function() return entryLib:GetListItemObject(w) end)
        if ok and kit.valid(item) then
            local info = extractItemInfo(item)
            if targetItemId and targetItemId > 0 and info and info.id == targetItemId then
                return w
            end
            local eIdx = nil
            pcall(function()
                if item.EntryIndex ~= nil then eIdx = num(item.EntryIndex)
                elseif item.ItemIndex ~= nil then eIdx = num(item.ItemIndex)
                end
            end)
            if eIdx ~= nil and eIdx == idx0 then
                fallback = w
            end
        end
    end
    return fallback
end

local function focusListWidgetIndex(container, pm, lv, idx0, targetItemId, vmBtl)
    idx0 = math.max(0, idx0 or 0)
    if kit.valid(vmBtl) then
        pcall(function()
            if vmBtl.CurrentFocusListIndex ~= nil then
                vmBtl.CurrentFocusListIndex = idx0
            end
        end)
    end
    if kit.valid(lv) then
        pcall(function() lv:ScrollIndexIntoView(idx0) end)
        pcall(function() lv:SetSelectedIndex(idx0) end)
        pcall(function() lv:NavigateToIndex(idx0) end)
    end
    if kit.valid(pm) then
        focusToIndex(pm, idx0)
    end

    local entryW = findDisplayedEntryWidgetByItem(lv, idx0, targetItemId)
    if kit.valid(entryW) then
        if kit.valid(pm) then
            if not safeCall(pm, "SetFocuedItemWidget", entryW, 0) then
                safeCall(pm, "SetFocuedItemWidget", entryW)
            end
        end
        local pc = kit.game and kit.game.playerController and kit.game.playerController()
        if kit.valid(pc) then
            pcall(function() entryW:SetUserFocus(pc) end)
        end
        pcall(function() entryW:SetKeyboardFocus() end)
        return isWidgetFocused(entryW)
    end
    return false
end

local function scheduleListFocus(container, pm, lv, cache, idx0, targetItemId, forceDelayed, vmBtl)
    cache.focusGen = (cache.focusGen or 0) + 1
    local gen = cache.focusGen
    local focusedNow = focusListWidgetIndex(container, pm, lv, idx0, targetItemId, vmBtl)
    if not kit.after then return end
    if not forceDelayed and focusedNow and idx0 == 0 then return end

    local function retry(remaining)
        if not kit.valid(container) or cache.focusGen ~= gen then return end
        local vis = false
        pcall(function() vis = container:IsVisible() end)
        if not vis then return end

        local ok = focusListWidgetIndex(container, pm, lv, idx0, targetItemId, vmBtl)
        if not ok and remaining > 0 then
            kit.after(60, function() retry(remaining - 1) end, "itemFocusRestore2")
        end
    end

    kit.after(50, function() retry(idx0 > 0 and 1 or 0) end, "itemFocusRestore")
end

-------------------------------------------------------------------------------
-- ITEM METADATA & CATEGORY-GROUPED COMPARATORS
-------------------------------------------------------------------------------
-- Category group order (keeps the "All" tab cleanly grouped by category)
local CAT_GROUP = {
    CONSUMABLE = 1,
    WEAPON     = 2,
    ARMOR      = 3,
    ACCESSORY  = 4,
    VISION     = 5,
    VALUABLE   = 6,
    ARTIFACT   = 7,
    OTHER      = 8,
}

-- Consumable combat role sub-groups (used for Type & Power sort + Battle Item pagination)
local ROLE = {
    REVIVE    = 1,
    HP_HEAL   = 2,
    MP_HEAL   = 3,
    CURE      = 4,
    BUFF      = 5,
    OFFENSIVE = 6,
    OTHER     = 7,
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
local REL_FRIENDLIES, REL_ENEMIES = 1, 2

-- Read SKILL_DATA once so consumables can be classified accurately by linked skill
local skillRoleCache = nil
local function loadSkillRoles()
    if skillRoleCache and next(skillRoleCache) then return skillRoleCache end
    local info = {}
    pcall(function()
        kit.tables.rows("SKILL_DATA", function(row)
            local id = num(row.ID)
            if id <= 0 or info[id] then return end
            info[id] = {
                effect   = num(row.skillEffectType),
                relation = num(row.defaultTargetRelation),
                power    = num(row.magnification),
                hits     = num(row.hitCount),
                brk      = num(row.breakDamageValue),
                cost     = num(row.Cost),
                name     = textStr(row.Name):lower(),
                icon     = (function()
                    local s = ""
                    pcall(function()
                        if row.SkillIcon then
                            if row.SkillIcon.TagName and type(row.SkillIcon.TagName.ToString) == "function" then
                                s = row.SkillIcon.TagName:ToString():lower()
                            elseif type(row.SkillIcon.ToString) == "function" then
                                s = row.SkillIcon:ToString():lower()
                            end
                        end
                    end)
                    return s
                end)(),
            }
        end)
    end)
    if next(info) then skillRoleCache = info end
    return info
end

local function classifyConsumable(nameLower, descLower, skillId, isThrow, throwSkillId, skills)
    local sk = (skillId and skillId > 0 and skills[skillId])
        or (throwSkillId and throwSkillId > 0 and skills[throwSkillId])
        or nil
    local power = sk and (sk.power * math.max(1, sk.hits) + sk.brk) or 0

    -- Explicit name/skill cues for MP items (Ether / Elixir) and Revive (Phoenix Down)
    if sk then
        if sk.effect == EFFECT.Revival then
            return ROLE.REVIVE, power + 1000
        end
        if sk.effect == EFFECT.CureStatusCondition then
            return ROLE.CURE, power
        end
        if sk.effect == EFFECT.DamageAndRecovery and sk.relation == REL_FRIENDLIES then
            if nameLower:find("elixir", 1, true) or nameLower:find("ether", 1, true)
                or descLower:find(" mp", 1, true) or descLower:find("restore mp", 1, true)
                or descLower:find("recovers mp", 1, true) then
                return ROLE.MP_HEAL, power
            end
            return ROLE.HP_HEAL, power
        end
        if STATUS_EFFECTS[sk.effect] then
            if sk.relation == REL_ENEMIES then
                return ROLE.OFFENSIVE, power
            end
            return ROLE.BUFF, power
        end
        if sk.relation == REL_ENEMIES or isThrow then
            return ROLE.OFFENSIVE, power
        end
    end

    if isThrow then
        return ROLE.OFFENSIVE, power
    end
    if nameLower:find("phoenix", 1, true) or descLower:find("revive", 1, true) or descLower:find("ko", 1, true) then
        return ROLE.REVIVE, power
    end
    if nameLower:find("elixir", 1, true) or nameLower:find("ether", 1, true) then
        return ROLE.MP_HEAL, power
    end
    if nameLower:find("potion", 1, true) or nameLower:find("tent", 1, true) or nameLower:find("cottage", 1, true) then
        return ROLE.HP_HEAL, power
    end
    if nameLower:find("antidote", 1, true) or nameLower:find("remedy", 1, true) or nameLower:find("eye drops", 1, true)
        or nameLower:find("echo", 1, true) or nameLower:find("gold needle", 1, true) or nameLower:find("smelling", 1, true)
        or nameLower:find("vaccine", 1, true) or nameLower:find("maiden", 1, true) or nameLower:find("holy water", 1, true) then
        return ROLE.CURE, power
    end
    return ROLE.OTHER, power
end

local ITEM_TABLE_STRUCTS = {
    "CONSUMABLES_ITEM_DATA",
    "EQUIPMENT_ITEM_DATA",
    "VALUABLE_ITEM_DATA",
    "ARTIFACT_ITEM_DATA",
    "VISION_ITEM_DATA",
    "FEED_ITEM_DATA",
    "SEED_ITEM_DATA",
    "ITEM_DATA",
}

local itemInfoCache = nil
local function loadItemInfo()
    if itemInfoCache and next(itemInfoCache) then return itemInfoCache end
    local skills = loadSkillRoles()
    local info = {}

    for _, structName in ipairs(ITEM_TABLE_STRUCTS) do
        pcall(function()
            kit.tables.rows(structName, function(row)
                local id = num(row.ID)
                if id <= 0 or info[id] then return end

                local name = textStr(row.Name)
                local nameLower = name:lower()
                local descLower = textStr(row.Description):lower()
                local sortId = num(row.SortId)
                local itemType = num(row.ItemType)
                local buyPrice = num(row.buyingPrice)
                local sellPrice = num(row.sellingPrice)
                local price = math.max(buyPrice, sellPrice)

                local equipType = 0
                local equipDetail = 0
                local primaryStat = 0
                local totalStats = 0
                local passiveCount = 0
                local roleSub = ROLE.OTHER
                local power = 0
                local isThrow = false

                if structName == "EQUIPMENT_ITEM_DATA" or itemType == 3 then
                    equipType = num(row.EquipmentType)
                    equipDetail = num(row.equipmentDetailType)
                    pcall(function()
                        if row.params then
                            row.params:ForEach(function(k, v)
                                local pt = num(k)
                                local pv = num(v)
                                if pv ~= 0 then
                                    totalStats = totalStats + pv
                                    if equipType == 1 then
                                        -- Weapon primary: ATK(5), INT(7), MND(8), PhysAtk(12), MagAtk(14)
                                        if pt == 5 or pt == 7 or pt == 8 or pt == 12 or pt == 14 then
                                            if pv > primaryStat then primaryStat = pv end
                                        end
                                    elseif equipType == 2 then
                                        -- Armor primary: DEF(6), MND(8), PhysDef(13), MagDef(15)
                                        if pt == 6 or pt == 8 or pt == 13 or pt == 15 then
                                            primaryStat = primaryStat + pv
                                        end
                                    end
                                end
                            end)
                        end
                    end)
                    pcall(function()
                        if row.passiveList then passiveCount = #row.passiveList end
                    end)
                elseif structName == "CONSUMABLES_ITEM_DATA" or itemType == 1 then
                    local skillId = num(row.SkillId)
                    local throwSkillId = 0
                    pcall(function()
                        if row.throwSkillData then
                            isThrow = (row.throwSkillData.isThrow == true)
                            throwSkillId = num(row.throwSkillData.SkillId)
                        end
                    end)
                    roleSub, power = classifyConsumable(nameLower, descLower, skillId, isThrow, throwSkillId, skills)
                end

                local catGroup = CAT_GROUP.OTHER
                if itemType == 1 or structName == "CONSUMABLES_ITEM_DATA" then
                    catGroup = CAT_GROUP.CONSUMABLE
                elseif itemType == 3 or structName == "EQUIPMENT_ITEM_DATA" then
                    if equipType == 1 then catGroup = CAT_GROUP.WEAPON
                    elseif equipType == 2 then catGroup = CAT_GROUP.ARMOR
                    elseif equipType == 3 then catGroup = CAT_GROUP.ACCESSORY
                    elseif equipType == 4 then catGroup = CAT_GROUP.VISION
                    else catGroup = CAT_GROUP.ACCESSORY
                    end
                elseif structName == "VISION_ITEM_DATA" then
                    catGroup = CAT_GROUP.VISION
                elseif itemType == 2 or structName == "VALUABLE_ITEM_DATA" then
                    catGroup = CAT_GROUP.VALUABLE
                elseif itemType == 4 or structName == "ARTIFACT_ITEM_DATA" then
                    catGroup = CAT_GROUP.ARTIFACT
                end

                info[id] = {
                    id = id,
                    name = name,
                    nameLower = nameLower,
                    sortId = sortId,
                    itemType = itemType,
                    catGroup = catGroup,
                    equipType = equipType,
                    equipDetail = equipDetail,
                    primaryStat = primaryStat,
                    totalStats = totalStats,
                    passiveCount = passiveCount,
                    roleSub = roleSub,
                    power = power,
                    isThrow = isThrow,
                    price = price,
                }
            end)
        end)
    end

    if next(info) then
        itemInfoCache = info
    end
    return info
end

local function getItemDisplayName(id)
    local info = loadItemInfo()
    local it = info and info[id]
    if it and it.name and it.name ~= "" then return it.name end
    return "item"
end

-- Live inventory quantity lookup from SaveData.inventory
local function getInventoryQuantities()
    local qty = {}
    pcall(function()
        local sd = kit.game and kit.game.saveData and kit.game.saveData()
        if not kit.valid(sd) or not sd.inventory then return end
        for i = 1, #sd.inventory do
            local e = sd.inventory[i]
            local id = num(e.ItemId)
            local n = num(e.Num)
            if id > 0 then
                qty[id] = (qty[id] or 0) + n
            end
        end
    end)
    return qty
end

local function getAllOwnedItemIds(extraIds)
    local seen = {}
    local out = {}
    local function add(id)
        if id and id > 0 and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    pcall(function()
        local sd = kit.game and kit.game.saveData and kit.game.saveData()
        if kit.valid(sd) and sd.inventory then
            for i = 1, #sd.inventory do
                add(num(sd.inventory[i].ItemId))
            end
        end
    end)
    local saved = getSavedOrder()
    if saved then
        for _, id in ipairs(saved) do add(id) end
    end
    if extraIds then
        for _, id in ipairs(extraIds) do add(id) end
    end
    return out
end

-- Compare two items for a given Auto-Sort Mode (always grouped by category except Vanilla)
local function autoSortedOrder(ids, mode, qtyOverride)
    local info = loadItemInfo()
    local qtyMap = (mode == "quantity") and getInventoryQuantities() or nil
    local decorated = {}
    for i, id in ipairs(ids) do
        local q = 0
        if qtyMap then
            q = qtyMap[id] or (qtyOverride and qtyOverride[id]) or 0
        end
        decorated[i] = { id = id, pos = i, d = info[id], qty = q }
    end

    table.sort(decorated, function(a, b)
        -- Always keep placeholder / "Unequip" rows (id <= 0) pinned to the very top
        if (a.id <= 0) ~= (b.id <= 0) then return a.id <= 0 end
        if a.id <= 0 and b.id <= 0 then return a.pos < b.pos end

        local da, db = a.d, b.d
        if (da ~= nil) ~= (db ~= nil) then return da ~= nil end
        if not (da and db) then return a.pos < b.pos end

        if mode == "vanilla" then
            if da.sortId ~= db.sortId then return da.sortId < db.sortId end
            if da.id ~= db.id then return da.id < db.id end
            return a.pos < b.pos
        end

        -- Group by category first (Consumables -> Weapons -> Armor -> Accessories -> Visions -> Valuables -> Artifacts)
        if da.catGroup ~= db.catGroup then return da.catGroup < db.catGroup end

        if mode == "alpha" then
            if da.nameLower ~= db.nameLower then return da.nameLower < db.nameLower end
            if da.sortId ~= db.sortId then return da.sortId < db.sortId end
            return a.pos < b.pos
        elseif mode == "type" then
            if da.catGroup == CAT_GROUP.CONSUMABLE then
                if da.roleSub ~= db.roleSub then return da.roleSub < db.roleSub end
                if da.power ~= db.power then return da.power > db.power end
                if da.price ~= db.price then return da.price > db.price end
            elseif da.catGroup == CAT_GROUP.WEAPON or da.catGroup == CAT_GROUP.ARMOR then
                if da.equipDetail ~= db.equipDetail then return da.equipDetail < db.equipDetail end
                if da.primaryStat ~= db.primaryStat then return da.primaryStat > db.primaryStat end
                if da.totalStats ~= db.totalStats then return da.totalStats > db.totalStats end
                if da.price ~= db.price then return da.price > db.price end
            elseif da.catGroup == CAT_GROUP.ACCESSORY then
                if da.totalStats ~= db.totalStats then return da.totalStats > db.totalStats end
                if da.passiveCount ~= db.passiveCount then return da.passiveCount > db.passiveCount end
                if da.price ~= db.price then return da.price > db.price end
            else
                if da.price ~= db.price then return da.price > db.price end
            end
            if da.nameLower ~= db.nameLower then return da.nameLower < db.nameLower end
            if da.sortId ~= db.sortId then return da.sortId < db.sortId end
            return a.pos < b.pos
        elseif mode == "quantity" then
            if a.qty ~= b.qty then return a.qty > b.qty end
            if da.nameLower ~= db.nameLower then return da.nameLower < db.nameLower end
            if da.sortId ~= db.sortId then return da.sortId < db.sortId end
            return a.pos < b.pos
        elseif mode == "price" then
            if da.price ~= db.price then return da.price > db.price end
            if da.nameLower ~= db.nameLower then return da.nameLower < db.nameLower end
            if da.sortId ~= db.sortId then return da.sortId < db.sortId end
            return a.pos < b.pos
        end

        return a.pos < b.pos
    end)

    local out = {}
    for i, e in ipairs(decorated) do out[i] = e.id end
    return out
end

-- Apply saved custom order (or fallback AutoSortMode when fallbackToMode is true)
local function getSortedItemIds(currentIds, allowAdd, fallbackToMode, qtyOverride)
    local master = getSavedOrder()
    if not master then
        if fallbackToMode and cfg.AutoSortMode and cfg.AutoSortMode ~= "vanilla" then
            return autoSortedOrder(currentIds, cfg.AutoSortMode, qtyOverride)
        end
        return currentIds
    end

    if allowAdd then
        local modified = false
        local info = loadItemInfo()
        for _, id in ipairs(currentIds) do
            if id and id > 0 and not indexOf(master, id) then
                -- Insert unseen items at the end of their category group so categories stay clean
                local cg = info[id] and info[id].catGroup or CAT_GROUP.OTHER
                local insertAt = #master + 1
                for i = #master, 1, -1 do
                    local mcg = info[master[i]] and info[master[i]].catGroup or CAT_GROUP.OTHER
                    if mcg == cg then
                        insertAt = i + 1
                        break
                    end
                end
                table.insert(master, insertAt, id)
                modified = true
            end
        end
        if modified then
            store.data.order = master
            saveStore()
        end
    end

    local rank = {}
    for i, id in ipairs(master) do rank[id] = i end

    -- For any unranked items (when allowAdd is false), compute tie-break rank from AutoSortMode if set
    local fallbackRank = nil
    if fallbackToMode and cfg.AutoSortMode and cfg.AutoSortMode ~= "vanilla" then
        local unranked = {}
        for _, id in ipairs(currentIds) do
            if id > 0 and not rank[id] then unranked[#unranked + 1] = id end
        end
        if #unranked > 0 then
            fallbackRank = {}
            for i, id in ipairs(autoSortedOrder(unranked, cfg.AutoSortMode, qtyOverride)) do
                fallbackRank[id] = 100000 + i
            end
        end
    end

    local decorated = {}
    for i, id in ipairs(currentIds) do
        local r = (id <= 0) and -1 or (rank[id] or (fallbackRank and fallbackRank[id]) or 999999)
        decorated[i] = { id = id, pos = i, rank = r }
    end

    table.sort(decorated, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.pos < b.pos
    end)

    local sorted = {}
    for i, d in ipairs(decorated) do sorted[i] = d.id end
    return sorted
end

-- Moves `id` to `targetId`'s position inside saved order (inserting above when moving up, below when moving down)
local function moveItem(id, targetId, moveDown, currentIds)
    local master = getSavedOrder()
    if not master then
        master = getAllOwnedItemIds(currentIds)
        -- Preserve the current visible order for items currently shown on screen
        local visSet = {}
        for _, v in ipairs(currentIds) do if v > 0 then visSet[v] = true end end
        local ordered = {}
        for _, v in ipairs(currentIds) do if v > 0 then ordered[#ordered + 1] = v end end
        for _, v in ipairs(master) do if v > 0 and not visSet[v] then ordered[#ordered + 1] = v end end
        master = ordered
    end

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
    store.data.order = master
    store.data.appliedMode = "manual"
    orderVersion = orderVersion + 1
    saveStore()
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

-- Shared helper to push a reordered list of UObject items into PathMenu + ListView
local function applyObjectsToListView(pm, lv, reorderedEntries)
    local count = #reorderedEntries
    if count == 0 then return false end

    local objs = {}
    for i = 1, count do
        local obj = reorderedEntries[i].obj
        if kit.valid(obj) then
            setItemObjectIndex(obj, i - 1)
            objs[#objs + 1] = obj
        end
    end
    if #objs ~= count then return false end

    if kit.valid(pm) and pm ~= lv and pm.ListItems then
        pcall(function()
            pm.ListItems:Empty()
            for i, obj in ipairs(objs) do
                pm.ListItems[i] = obj
            end
        end)
    end

    if kit.valid(lv) then
        pcall(function() lv:ClearListItems() end)
        local okSet = pcall(function() lv:SetListItems(objs) end)
        if not okSet then
            pcall(function()
                for _, obj in ipairs(objs) do
                    lv:AddItem(obj)
                end
            end)
        end
        pcall(function() lv:RegenerateAllEntries() end)
        pcall(function() lv:RequestRefresh() end)
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- PAUSE MENU -> ITEMS (PICK/DROP, DOUBLE-TAP AUTO-SORT, AUTO-APPLY SAVED ORDER)
-------------------------------------------------------------------------------
local pickedItemId = nil
local autoSortArmedAt = nil
local wasPickDown = false
local wasCancelDown = false
local wasAutoSortDown = false
local wasPauseListOpen = false
local pauseFocusCache = {}
local lastPauseAppliedIds = nil
local lastPauseOrderVer = -1
local loggedInventoryLayout = false
local loggedNoInventoryOnce = false

local function isItemLayoutClassName(cn)
    if not cn or cn == "" then return false end
    local l = cn:lower()
    if l:find("shop", 1, true) or l:find("equip", 1, true) or l:find("result", 1, true)
        or l:find("dialog", 1, true) or l:find("btl", 1, true) or l:find("battle", 1, true)
        or l:find("mixture", 1, true) or l:find("craft", 1, true) then
        return false
    end
    return l:find("item", 1, true) ~= nil or l:find("inventory", 1, true) ~= nil
end

local function isLayoutActive(w)
    if not kit.valid(w) then return false, false, false end
    local vis, focused, act = false, false, false
    pcall(function()
        vis = w:IsVisible()
        if vis then
            focused = w:HasFocusedDescendants() or w:HasAnyUserFocus()
        end
    end)
    pcall(function() act = w:IsActivated() end)
    return vis, focused, act
end

local function getOpenInventoryScreen()
    -- 1. Check explicit known classes first
    for _, cls in ipairs({ "WBP_ItemLayout_C", "WBP_InventoryLayout_C", "CPP_WBP_InventoryLayoutBase" }) do
        for _, layout in ipairs(FindAllOf(cls) or {}) do
            if kit.valid(layout) and not layout:GetFName():ToString():find("Default__", 1, true) then
                local vis, focused = isLayoutActive(layout)
                if vis and focused then return layout end
            end
        end
    end

    -- 2. Generic search across active CPP_WBP_MuchaActivatable / CPP_EU_WBP_Activatable layouts
    for _, baseCls in ipairs({ "CPP_WBP_MuchaActivatable", "CPP_EU_WBP_Activatable" }) do
        for _, layout in ipairs(FindAllOf(baseCls) or {}) do
            if kit.valid(layout) and not layout:GetFName():ToString():find("Default__", 1, true) then
                local cn = className(layout)
                if isItemLayoutClassName(cn) then
                    local vis, focused = isLayoutActive(layout)
                    if vis and focused then return layout end
                end
            end
        end
    end

    return nil
end

local function getActiveItemLayoutVM(layout)
    local vm = nil
    if kit.valid(layout) then
        for _, prop in ipairs({ "VM_ItemLayout", "ItemLayoutVM", "CPP_VM_ItemLayout" }) do
            pcall(function()
                if not kit.valid(vm) and kit.valid(layout[prop]) then vm = layout[prop] end
            end)
        end
    end
    if kit.valid(vm) then return vm end
    local vms = FindAllOf("CPP_VM_ItemLayout") or {}
    for i = #vms, 1, -1 do
        local cand = vms[i]
        if kit.valid(cand) and not cand:GetFName():ToString():find("Default__", 1, true) then
            local ok, n = pcall(function() return cand.DisplayActionList and #cand.DisplayActionList or 0 end)
            if ok and n > 0 then return cand end
            vm = vm or cand
        end
    end
    return vm
end

-- Find the main item list widget (ListViewMenu / PathMenu) inside an Item layout,
-- skipping Tab, Category, Unit, and KeyGuide child menus.
local function findInventoryListWidget(layout)
    if not kit.valid(layout) then return nil, nil, nil end

    -- 1. Direct known property names
    for _, prop in ipairs({ "ListWidget", "WBP_ItemList", "WBP_InventoryList", "WBP_ActionList", "WBP_ListViewBase", "WBP_ListViewMenu" }) do
        local lw = nil
        pcall(function() lw = layout[prop] end)
        if kit.valid(lw) then
            local pm = findListViewMenu(lw)
            local lv = findListView(pm) or findListView(lw)
            return lw, pm, lv
        end
    end

    -- 2. Walk WidgetTree to locate the ListView / ListViewMenu / DirectionGridMenu holding items
    local bestPm, bestLv, bestScore = nil, nil, -1
    pcall(function()
        if not (kit.ui and kit.ui.walk and layout.WidgetTree and kit.valid(layout.WidgetTree.RootWidget)) then return end
        kit.ui.walk(layout.WidgetTree.RootWidget, function(w)
            local fn = ""
            pcall(function() fn = w:GetFName():ToString():lower() end)
            local cn = className(w)
            local cnl = cn:lower()
            if fn:find("tab", 1, true) or fn:find("unit", 1, true) or fn:find("party", 1, true)
                or fn:find("guide", 1, true) or fn:find("header", 1, true)
                or cnl:find("tab", 1, true) or cnl:find("unit", 1, true) then
                return false
            end

            local isLvMenu = (cn == "WBP_ListViewMenu_C" or cnl:find("listviewmenu", 1, true) ~= nil)
            local isLv = (not isLvMenu) and isRealListViewClass(cn)
            local isDirMenu = (cnl:find("directiongridmenu", 1, true) ~= nil or cnl:find("itemlist", 1, true) ~= nil)
            if isLvMenu or isLv or isDirMenu then
                local pm = isLv and nil or findListViewMenu(w)
                local lv = isLv and w or findListView(pm or w)
                local objs = readListViewItems(lv)
                if #objs == 0 and kit.valid(pm) then objs = readPathMenuItems(pm) end
                local itemHits = 0
                for _, o in ipairs(objs) do
                    local inf = extractItemInfo(o)
                    if inf and inf.id > 0 then itemHits = itemHits + 1 end
                end
                local score = itemHits * 100 + #objs + (isLvMenu and 5 or 0) + (kit.valid(lv) and 2 or 0)
                if score > bestScore then
                    bestScore = score
                    bestPm = pm or w
                    bestLv = lv
                end
            end
            return false
        end)
    end)

    if kit.valid(bestPm) or kit.valid(bestLv) then
        return bestPm or bestLv, bestPm or bestLv, bestLv
    end
    return nil, nil, nil
end

local function readActionArray(arr, objs)
    local entries, ids, qtyOverride = {}, {}, {}
    if not arr then return entries, ids, qtyOverride end
    local okN, n = pcall(function() return #arr end)
    if not okN or not n or n == 0 then return entries, ids, qtyOverride end
    local pairObjs = objs and (#objs == n)
    for i = 1, n do
        pcall(function()
            local d = arr[i]
            local id = d and d.ActionKey and num(d.ActionKey.ID) or 0
            if id > 0 then
                local cnt = 0
                if d.TmpNum ~= nil then cnt = num(d.TmpNum)
                elseif d.Num ~= nil then cnt = num(d.Num)
                end
                entries[#entries + 1] = {
                    id = id,
                    cat = num(d.ActionKey.Category),
                    num = cnt,
                    obj = pairObjs and objs[i] or nil,
                }
                ids[#ids + 1] = id
                if cnt > 0 then qtyOverride[id] = cnt end
            end
        end)
    end
    return entries, ids, qtyOverride
end

local function readInventoryEntries(layout, vm)
    local listWidget, pm, lv = findInventoryListWidget(layout)
    local selList = nil
    pcall(function() selList = layout.WBP_SelectItemList end)
    if kit.valid(selList) and kit.valid(selList.PathMenu) then
        pm = selList.PathMenu
        lv = findListView(pm) or lv
        listWidget = pm
    end
    local objs = readListViewItems(lv)
    if #objs == 0 and kit.valid(pm) then objs = readPathMenuItems(pm) end

    -- 1. Prefer WBP_SelectItemList.actionDataList (exact active tab data)
    if kit.valid(selList) then
        local okA, adl = pcall(function() return selList.actionDataList end)
        if okA and adl then
            local entries, ids, qtyOverride = readActionArray(adl, objs)
            if #ids > 0 then
                return listWidget, pm, lv, entries, ids, qtyOverride, selList
            end
        end
    end

    -- 2. Check ListView item objects directly if they carry item IDs
    local entries, ids, qtyOverride = {}, {}, {}
    if #objs > 0 then
        for _, obj in ipairs(objs) do
            local inf = extractItemInfo(obj)
            if inf and inf.id > 0 then
                entries[#entries + 1] = { id = inf.id, cat = inf.cat, num = inf.num, obj = obj }
                ids[#ids + 1] = inf.id
                if inf.num and inf.num > 0 then qtyOverride[inf.id] = inf.num end
            end
        end
    end

    -- 3. Fallback: VM_ItemLayout.DisplayActionList
    if #ids == 0 and kit.valid(vm) then
        local okD, dal = pcall(function() return vm.DisplayActionList end)
        if okD and dal then
            entries, ids, qtyOverride = readActionArray(dal, objs)
        end
    end
    return listWidget, pm, lv, entries, ids, qtyOverride, selList
end

local function getItemObjectIndex(obj)
    if not kit.valid(obj) then return nil end
    local idx = nil
    pcall(function()
        if obj.ItemIndex ~= nil then idx = num(obj.ItemIndex)
        elseif obj.EntryIndex ~= nil then idx = num(obj.EntryIndex)
        end
    end)
    return idx
end

local function itemIdFromEntryWidget(w, entryLib, currentIds)
    if not kit.valid(w) then return nil end
    -- 1. Widget's own live InventoryActionData / ActionKey (always accurate even on recycled ListView rows)
    local wInf = extractItemInfo(w)
    if wInf and wInf.id > 0 and indexOf(currentIds, wInf.id) then
        return wInf.id
    end
    -- 2. Backing ListItem object (BP_SelectItemEntry_C.ItemIndex)
    if kit.valid(entryLib) then
        local ok, item = pcall(function() return entryLib:GetListItemObject(w) end)
        if ok and kit.valid(item) then
            local inf = extractItemInfo(item)
            if inf and inf.id > 0 and indexOf(currentIds, inf.id) then
                return inf.id
            end
            local idx0 = getItemObjectIndex(item)
            if idx0 and currentIds[idx0 + 1] then
                return currentIds[idx0 + 1]
            end
        end
    end
    -- 3. Widget's EntryIndex fallback
    local wIdx = getItemObjectIndex(w)
    if wIdx and currentIds[wIdx + 1] then
        return currentIds[wIdx + 1]
    end
    return nil
end

local function getFocusedInventoryItemId(pm, lv, currentIds)
    local entryLib = StaticFindObject("/Script/UMG.Default__UserObjectListEntryLibrary")
    local displayed = kit.valid(lv) and getDisplayedWidgets(lv) or {}

    -- 1. Live Slate focus on realized ListView entry widgets
    for _, w in ipairs(displayed) do
        if isWidgetFocused(w) then
            local id = itemIdFromEntryWidget(w, entryLib, currentIds)
            if id then return id end
        end
    end

    -- 2. CPP_WBP_MenuBase.FocuedItemDataMap (Current=0, Last=2): check both Widget and Index
    if kit.valid(pm) then
        local mapWidget, mapIdx = nil, nil
        pcall(function()
            if pm.FocuedItemDataMap then
                pm.FocuedItemDataMap:ForEach(function(k, v)
                    local kv = num(k)
                    if kv == 0 or (kv == 2 and mapWidget == nil and mapIdx == nil) then
                        local fd = v:get()
                        if fd then
                            if kit.valid(fd.Widget) then mapWidget = fd.Widget end
                            if fd.Index ~= nil then mapIdx = num(fd.Index) end
                        end
                    end
                end)
            end
        end)
        if kit.valid(mapWidget) then
            local id = itemIdFromEntryWidget(mapWidget, entryLib, currentIds)
            if id then return id end
        end
        if mapIdx and mapIdx >= 0 and currentIds[mapIdx + 1] then
            return currentIds[mapIdx + 1]
        end
    end

    -- 3. Hook-captured last focused widget matched against displayed ListView entries
    if (lastFocusedWidgetAddr or lastFocusedWidgetName) and #displayed > 0 then
        for _, w in ipairs(displayed) do
            local match = false
            pcall(function()
                match = (lastFocusedWidgetAddr and w:GetAddress() == lastFocusedWidgetAddr)
                    or (lastFocusedWidgetName and w:GetFName():ToString() == lastFocusedWidgetName)
            end)
            if match then
                local id = itemIdFromEntryWidget(w, entryLib, currentIds)
                if id then return id end
            end
        end
    end

    -- 4. ListView SelectedItem fallback
    if kit.valid(lv) then
        local okSel, sel = pcall(function() return lv:GetSelectedItem() end)
        if okSel and kit.valid(sel) then
            local inf = extractItemInfo(sel)
            if inf and inf.id > 0 and indexOf(currentIds, inf.id) then
                return inf.id
            end
            local idx0 = getItemObjectIndex(sel)
            if idx0 and currentIds[idx0 + 1] then
                return currentIds[idx0 + 1]
            end
        end
    end

    -- 5. PathMenu focused index fallback
    local idx = getFocusedIndex(pm)
    if idx and currentIds[idx + 1] then
        return currentIds[idx + 1]
    end
    return nil
end

-- Reorder either TArray<UISkillActionData> or TArray<InventoryActionData> in-place and return a plain Lua table copy
local function syncActionArray(arr, orderedIds)
    if not arr then return false, nil end
    local ok = false
    local rebuiltPlain = nil
    pcall(function()
        if #arr ~= #orderedIds then return end
        local isSkillAction = (arr[1].UserUnitId ~= nil or arr[1].TmpNum ~= nil)
        local buckets = {}
        for i = 1, #arr do
            local d = arr[i]
            local id = num(d.ActionKey.ID)
            buckets[id] = buckets[id] or {}
            if isSkillAction then
                table.insert(buckets[id], {
                    UserUnitId = num(d.UserUnitId),
                    TmpNum = num(d.TmpNum),
                    ActionKey = { Category = num(d.ActionKey.Category), ID = id },
                })
            else
                table.insert(buckets[id], {
                    ActionKey = { Category = num(d.ActionKey.Category), ID = id },
                    Num = num(d.Num),
                    OwnerId = num(d.OwnerId),
                })
            end
        end
        local reordered = {}
        for i = 1, #orderedIds do
            local q = buckets[orderedIds[i]]
            if not q or #q == 0 then return end
            reordered[i] = table.remove(q, 1)
        end
        for i = 1, #reordered do
            local r = reordered[i]
            if isSkillAction then
                arr[i].UserUnitId = r.UserUnitId
                arr[i].TmpNum = r.TmpNum
            else
                arr[i].Num = r.Num
                arr[i].OwnerId = r.OwnerId
            end
            arr[i].ActionKey.Category = r.ActionKey.Category
            arr[i].ActionKey.ID = r.ActionKey.ID
        end
        rebuiltPlain = reordered
        ok = true
    end)
    return ok, rebuiltPlain
end

local function applyInventoryOrderToUI(layout, listWidget, vm, pm, lv, selList, rawEntries, orderedIds, focusIdx0, targetItemId)
    local syncedDal, plainDal = false, nil
    if kit.valid(vm) then
        local okD, dal = pcall(function() return vm.DisplayActionList end)
        if okD and dal then syncedDal, plainDal = syncActionArray(dal, orderedIds) end
    end
    local syncedSel, plainSel = false, nil
    if kit.valid(selList) then
        local okA, adl = pcall(function() return selList.actionDataList end)
        if okA and adl then syncedSel, plainSel = syncActionArray(adl, orderedIds) end
    end

    local applied = false

    -- 1. Preferred: WBP_ItemLayout_C:SetDisplayActionList (native MVVM setter) or WBP_SelectItemList_C:SetActionDataList
    if kit.valid(layout) and syncedDal and plainDal then
        if pcall(function() layout:SetDisplayActionList(plainDal) end) then
            applied = true
        elseif pcall(function() layout:SetDisplayActionList(vm.DisplayActionList) end) then
            applied = true
        end
    end
    if not applied and kit.valid(selList) and syncedSel and plainSel then
        if pcall(function() selList:SetActionDataList(plainSel) end) then
            applied = true
        elseif pcall(function() selList:SetActionDataList(selList.actionDataList) end) then
            applied = true
        end
    end

    -- 2. Fallback: direct ListView object reorder
    if not applied then
        local reordered = reorderEntriesByIds(rawEntries, orderedIds)
        if #reordered > 0 and kit.valid(reordered[1].obj) then
            applied = applyObjectsToListView(pm, lv, reordered)
        end
        if not applied and kit.valid(lv) then
            pcall(function() lv:RegenerateAllEntries() end)
            pcall(function() lv:RequestRefresh() end)
            applied = true
        end
        if not applied and kit.valid(listWidget) then
            for _, fn in ipairs({ "SetActionIdList", "SetItemIdList" }) do
                if safeCall(listWidget, fn, orderedIds) then
                    applied = true
                    break
                end
            end
        end
    end

    if applied and focusIdx0 ~= nil then
        scheduleListFocus(layout, pm, lv, pauseFocusCache, focusIdx0, targetItemId, true, nil)
    end
    return applied
end

local function logPauseItemsDiagIfNeeded(autoSortDown, pickDown)
    if loggedNoInventoryOnce or (not autoSortDown and not pickDown) then return end
    local vm = getActiveItemLayoutVM(nil)
    local dalCount = 0
    if kit.valid(vm) then
        pcall(function() dalCount = vm.DisplayActionList and #vm.DisplayActionList or 0 end)
    end
    if dalCount == 0 then return end
    loggedNoInventoryOnce = true
    local activeLayouts = {}
    for _, w in ipairs(FindAllOf("CPP_EU_WBP_Activatable") or {}) do
        if kit.valid(w) and not w:GetFName():ToString():find("Default__", 1, true) then
            local vis, foc = isLayoutActive(w)
            if vis then
                activeLayouts[#activeLayouts + 1] = string.format("%s(foc=%s)", className(w), tostring(foc))
            end
        end
    end
    mod:log(string.format("Pause Items diag (VM dal=%d): visibleLayouts=[%s]", dalCount, table.concat(activeLayouts, ", ")))
end

local function dumpClassReflection(tag, obj, maxDepth)
    if not kit.valid(obj) then return end
    local props, funcs = {}, {}
    local seenP, seenF = {}, {}
    pcall(function()
        local cls = obj:GetClass()
        local depth = 0
        while kit.valid(cls) and depth < (maxDepth or 3) do
            depth = depth + 1
            local cname = ""
            pcall(function() cname = cls:GetFName():ToString() end)
            if cname == "UserWidget" or cname == "Widget" or cname == "Visual" or cname == "Object" then break end
            pcall(function()
                cls:ForEachProperty(function(prop)
                    local pn = prop:GetFName():ToString()
                    if not seenP[pn] and pn ~= "UberGraphFrame" then
                        seenP[pn] = true
                        local valStr = ""
                        pcall(function()
                            local v = obj[pn]
                            if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
                                valStr = "=" .. tostring(v)
                            elseif kit.valid(v) then
                                valStr = "=<" .. className(v) .. ">"
                            elseif type(v) == "userdata" then
                                local okN, n = pcall(function() return #v end)
                                if okN and type(n) == "number" then valStr = "=[len=" .. tostring(n) .. "]" end
                            end
                        end)
                        props[#props + 1] = pn .. valStr
                    end
                end)
            end)
            pcall(function()
                cls:ForEachFunction(function(fn)
                    local fnName = fn:GetFName():ToString()
                    if not seenF[fnName] and not fnName:find("ExecuteUbergraph", 1, true) then
                        seenF[fnName] = true
                        funcs[#funcs + 1] = fnName
                    end
                end)
            end)
            local super = nil
            pcall(function() super = cls:GetSuperStruct() end)
            cls = super
        end
    end)
    mod:log(string.format("[DIAG %s (%s)] props={%s}", tag, className(obj), table.concat(props, ", ")))
    if #funcs > 0 then
        mod:log(string.format("[DIAG %s (%s)] funcs={%s}", tag, className(obj), table.concat(funcs, ", ")))
    end
end

local function getActiveCategoryTag(vm, selList)
    local tag = ""
    if kit.valid(selList) and selList.GetSelectCategory then
        pcall(function()
            local c = selList:GetSelectCategory()
            if c and c.TagName then tag = c.TagName:ToString() end
        end)
    end
    if (tag == "" or tag == "None") and kit.valid(vm) then
        pcall(function()
            if vm.FocusCategory and vm.FocusCategory.TagName then
                tag = vm.FocusCategory.TagName:ToString()
            end
        end)
    end
    return tag
end

-- True when the active tab is the game's chronological "Recently Acquired" tab
-- (backed by SaveData.inventoryProcedure.itemDatas)
local function isRecentlyAcquiredTab(catTag, currentIds)
    if catTag and catTag ~= "" and catTag ~= "None" then
        local l = catTag:lower()
        if l:find("recent", 1, true) or l:find("procedure", 1, true) or l:find("history", 1, true) or l:find("new", 1, true) then
            return true
        end
    end
    local matchesProc = false
    pcall(function()
        local sd = kit.game and kit.game.saveData and kit.game.saveData()
        local proc = kit.valid(sd) and sd.inventoryProcedure and sd.inventoryProcedure.itemDatas
        if not proc or #proc == 0 or #proc ~= #currentIds then return end
        local procSet = {}
        for i = 1, #proc do
            local id = num(proc[i].ItemId)
            if id > 0 then procSet[id] = true end
        end
        for _, id in ipairs(currentIds) do
            if not procSet[id] then return end
        end
        matchesProc = true
    end)
    return matchesProc
end

local function sameIdSet(a, b)
    if not a or not b or #a ~= #b then return false end
    local counts = {}
    for _, v in ipairs(a) do counts[v] = (counts[v] or 0) + 1 end
    for _, v in ipairs(b) do
        local c = counts[v]
        if not c or c <= 0 then return false end
        counts[v] = c - 1
    end
    return true
end

local vanillaTabOrder = {} -- signature -> original vanilla ordered IDs

local function tabSignature(ids)
    local copy = {}
    for i, id in ipairs(ids) do copy[i] = id end
    table.sort(copy)
    return table.concat(copy, ",")
end

local function restoreVanillaInventoryUI(layout, listWidget, vm, pm, lv, selList, rawEntries, currentIds, qtyOverride)
    -- 1. Try the game's own native VM_ItemLayout:BuildDrawItemList()
    if kit.valid(vm) and vm.BuildDrawItemList then
        local okBuild = pcall(function() vm:BuildDrawItemList() end)
        if okBuild then
            local okD, dal = pcall(function() return vm.DisplayActionList end)
            if okD and dal then
                local _, builtIds = readActionArray(dal, nil)
                if #builtIds > 0 and sameIdSet(builtIds, currentIds) then
                    if applyInventoryOrderToUI(layout, listWidget, vm, pm, lv, selList, rawEntries, builtIds, 0, builtIds[1]) then
                        return true
                    end
                end
            end
        end
    end

    -- 2. Otherwise restore captured original tab order, or SortId vanilla order
    local sig = tabSignature(currentIds)
    local vanillaIds = vanillaTabOrder[sig]
    if not (vanillaIds and sameIdSet(vanillaIds, currentIds)) then
        vanillaIds = autoSortedOrder(currentIds, "vanilla", qtyOverride)
    end
    return applyInventoryOrderToUI(layout, listWidget, vm, pm, lv, selList, rawEntries, vanillaIds, 0, vanillaIds[1])
end

local function handlePauseMenuItems()
    if not mod.enabled then return end
    if kit.events and kit.events.battle then
        pickedItemId = nil
        autoSortArmedAt = nil
        wasPauseListOpen = false
        return
    end

    ensureFocusHooks()

    local layout = getOpenInventoryScreen()
    if not kit.valid(layout) then
        local pk = anyKeyDown(pickKeys())
        local ak = anyKeyDown(autoSortKeys())
        logPauseItemsDiagIfNeeded(ak, pk)
        pickedItemId = nil
        autoSortArmedAt = nil
        wasPauseListOpen = false
        lastPauseAppliedIds = nil
        wasPickDown = pk
        wasCancelDown = anyKeyDown(cancelKeys())
        wasAutoSortDown = ak
        return
    end

    local vm = getActiveItemLayoutVM(layout)
    local listWidget, pm, lv, rawEntries, currentIds, qtyOverride, selList = readInventoryEntries(layout, vm)
    local catTag = getActiveCategoryTag(vm, selList)

    if not loggedInventoryLayout then
        loggedInventoryLayout = true
        local selLen, dalLen = 0, 0
        if kit.valid(selList) then pcall(function() selLen = selList.actionDataList and #selList.actionDataList or 0 end) end
        if kit.valid(vm) then pcall(function() dalLen = vm.DisplayActionList and #vm.DisplayActionList or 0 end) end
        mod:log(string.format("Pause Items detected: cat=%s selList=%d vmDal=%d ids=%d first=%s,%s,%s",
            catTag, selLen, dalLen, #currentIds, tostring(currentIds[1]), tostring(currentIds[2]), tostring(currentIds[3])))
    end

    if #currentIds == 0 then return end

    local onRecentTab = isRecentlyAcquiredTab(catTag, currentIds)

    -- Capture original vanilla order for each tab the first time we see it unsorted
    local sig = tabSignature(currentIds)
    if not onRecentTab and not getSavedOrder() and not vanillaTabOrder[sig] then
        local snap = {}
        for i, id in ipairs(currentIds) do snap[i] = id end
        vanillaTabOrder[sig] = snap
    end

    -- Auto-apply saved order whenever Pause Menu > Items is open (skip Recently Acquired tab)
    local saved = getSavedOrder()
    if saved and not onRecentTab then
        local sortedIds = getSortedItemIds(currentIds, true, false, qtyOverride)
        if not sameIdList(currentIds, sortedIds) then
            if applyInventoryOrderToUI(layout, listWidget, vm, pm, lv, selList, rawEntries, sortedIds, 0, sortedIds[1]) then
                listWidget, pm, lv, rawEntries, currentIds, qtyOverride, selList = readInventoryEntries(layout, vm)
            end
        end
    end
    lastPauseAppliedIds = currentIds
    lastPauseOrderVer = orderVersion

    -- Skip interactive sorting while picking a party member target on WBP_TargetUnitList / UnitWidget
    local unitFocused = false
    pcall(function()
        if layout.IsCurrentActionSelectState then
            if not layout:IsCurrentActionSelectState() then unitFocused = true end
        end
    end)
    if not unitFocused then
        pcall(function()
            local uw = layout.WBP_TargetUnitList or layout.UnitWidget
            if kit.valid(uw) and uw:IsVisible() then
                unitFocused = uw:HasFocusedDescendants() or uw:HasAnyUserFocus()
            end
        end)
    end

    if unitFocused then
        pickedItemId = nil
        autoSortArmedAt = nil
        wasPauseListOpen = false
        wasPickDown = anyKeyDown(pickKeys())
        wasCancelDown = anyKeyDown(cancelKeys())
        wasAutoSortDown = anyKeyDown(autoSortKeys())
        return
    end

    -- Check if focus is on the category tab strip (skip R pick/drop there, still allow G)
    local tabFocused = false
    if kit.valid(selList) then
        pcall(function()
            local tab = selList.WBP_InventoryCategoryTab
            if kit.valid(tab) and tab:IsVisible() then
                tabFocused = tab:HasFocusedDescendants() or tab:HasAnyUserFocus()
            end
        end)
    end

    -- If user switched tabs while holding a picked item that isn't on this tab, clear pick-up
    if pickedItemId and not indexOf(currentIds, pickedItemId) then
        pickedItemId = nil
    end

    local isPickDown = anyKeyDown(pickKeys())
    local isCancelDown = anyKeyDown(cancelKeys())
    local isAutoSortDown = anyKeyDown(autoSortKeys())

    if not wasPauseListOpen then
        wasPauseListOpen = true
        wasPickDown = isPickDown
        wasCancelDown = isCancelDown
        wasAutoSortDown = isAutoSortDown
        pickedItemId = nil
        return
    end

    local pickPressed = isPickDown and not wasPickDown
    local cancelPressed = isCancelDown and not wasCancelDown
    local autoSortPressed = isAutoSortDown and not wasAutoSortDown

    wasPickDown = isPickDown
    wasCancelDown = isCancelDown
    wasAutoSortDown = isAutoSortDown

    -- 0. Handle Auto-Sort / Un-Sort toggle (G / Y-Triangle, double-tap within 3s to confirm)
    if autoSortPressed then
        local now = os.clock()
        local mode = cfg.AutoSortMode or "alpha"
        local hasSaved = (getSavedOrder() ~= nil)
        local alreadyInMode = (mode ~= "vanilla") and hasSaved and (
            store.data.appliedMode == mode
            or (store.data.appliedMode == nil and sameIdList(currentIds, autoSortedOrder(currentIds, mode, qtyOverride)))
        )
        local wantVanilla = (mode == "vanilla") or alreadyInMode

        if autoSortArmedAt and now - autoSortArmedAt <= AUTO_SORT_CONFIRM_SEC then
            autoSortArmedAt = nil
            pickedItemId = nil
            if wantVanilla then
                store.data.order = nil
                store.data.appliedMode = nil
                orderVersion = orderVersion + 1
                saveStore()
                if not onRecentTab then
                    restoreVanillaInventoryUI(layout, listWidget, vm, pm, lv, selList, rawEntries, currentIds, qtyOverride)
                end
                mod:notice("Items restored to Vanilla order!", "on", 1500)
            else
                local allIds = getAllOwnedItemIds(currentIds)
                store.data.order = autoSortedOrder(allIds, mode, qtyOverride)
                store.data.appliedMode = mode
                orderVersion = orderVersion + 1
                saveStore()
                if not onRecentTab then
                    local updatedIds = getSortedItemIds(currentIds, false, false, qtyOverride)
                    applyInventoryOrderToUI(layout, listWidget, vm, pm, lv, selList, rawEntries, updatedIds, 0, updatedIds[1])
                end
                mod:notice("Items auto-sorted (" .. modeLabel(mode) .. ")!", "on", 1500)
            end
        else
            autoSortArmedAt = now
            if alreadyInMode then
                mod:notice("Already sorted (" .. modeLabel(mode) .. "). Press " .. (cfg.AutoSortKey or "G") .. " / Y again to restore Vanilla order.", "warn", 2500)
            elseif mode == "vanilla" then
                mod:notice("Press " .. (cfg.AutoSortKey or "G") .. " / Y again to restore Vanilla item order.", "warn", 2500)
            else
                mod:notice("Press " .. (cfg.AutoSortKey or "G") .. " / Y again to auto-sort (" .. modeLabel(mode) .. ").", "warn", 2500)
            end
        end
        return
    end
    if autoSortArmedAt and os.clock() - autoSortArmedAt > AUTO_SORT_CONFIRM_SEC then
        autoSortArmedAt = nil
    end

    -- 1. Handle Cancel (C / B-Circle)
    if cancelPressed and pickedItemId then
        pickedItemId = nil
        mod:notice("Sort cancelled.", "warn", 1000)
        return
    end

    -- 2. Handle Pick / Drop (R / X-Square)
    if pickPressed and not tabFocused and not onRecentTab then
        local targetId = getFocusedInventoryItemId(pm, lv, currentIds)
        if not targetId or targetId <= 0 then
            mod:log("Pick/Drop pressed but focused item could not be resolved (ids=" .. tostring(#currentIds) .. ")")
            return
        end

        if not pickedItemId then
            pickedItemId = targetId
            mod:notice("Picked up " .. getItemDisplayName(targetId) .. ". Highlight target & press " .. (cfg.PickDropKey or "R") .. " / X to place.", "on", 2000)
        else
            if pickedItemId == targetId then
                pickedItemId = nil
                mod:notice("Sort cancelled.", "warn", 1000)
                return
            end

            local fromIdx = indexOf(currentIds, pickedItemId)
            local toIdx = indexOf(currentIds, targetId)
            local pId = pickedItemId
            pickedItemId = nil

            if fromIdx and toIdx then
                moveItem(pId, targetId, fromIdx < toIdx, currentIds)
                local updatedIds = getSortedItemIds(currentIds, false, false, qtyOverride)
                local newIdx = indexOf(updatedIds, pId) or 1
                applyInventoryOrderToUI(layout, listWidget, vm, pm, lv, selList, rawEntries, updatedIds, newIdx - 1, pId)
                mod:notice("Item placed and saved!", "on", 1000)
            end
        end
    end
end

-------------------------------------------------------------------------------
-- EQUIPMENT & ABILITIES -> EQUIPPABLE ITEMS PICKER (WBP_EquippableItems_C)
-------------------------------------------------------------------------------
local equipPickerCache = {} -- addr -> { lastAppliedIds, lastOrderVer, focusGen }

local function handleEquipPickerSorting()
    if not mod.enabled or not cfg.SortEquipPicker then return end
    if kit.events and kit.events.battle then return end

    local pickers = FindAllOf("WBP_EquippableItems_C") or {}
    for _, pm in ipairs(pickers) do
        if kit.valid(pm) and not pm:GetFName():ToString():find("Default__", 1, true) then
            local vis = false
            pcall(function() vis = pm:IsVisible() end)
            if vis then
                local lv = findListView(pm)
                local objs = readListViewItems(lv)
                if #objs == 0 then objs = readPathMenuItems(pm) end
                if #objs > 1 then
                    local rawEntries = {}
                    local currentIds = {}
                    local qtyOverride = {}
                    for i, obj in ipairs(objs) do
                        local inf = extractItemInfo(obj)
                        local id = inf and inf.id or 0
                        rawEntries[i] = { id = id, obj = obj }
                        currentIds[i] = id
                        if inf and inf.num and inf.num > 0 then qtyOverride[id] = inf.num end
                    end

                    local addr = nil
                    pcall(function() addr = pm:GetAddress() end)
                    local ck = tostring(addr or pm:GetFullName())
                    local cache = equipPickerCache[ck]
                    if not cache then
                        cache = { lastAppliedIds = nil, lastOrderVer = -1, focusGen = 0 }
                        equipPickerCache[ck] = cache
                    end

                    local needsCheck = (cache.lastOrderVer ~= orderVersion)
                        or (not sameIdList(currentIds, cache.lastAppliedIds))
                    if needsCheck then
                        local sortedIds = getSortedItemIds(currentIds, false, true, qtyOverride)
                        if not sameIdList(currentIds, sortedIds) then
                            local keepId = getFocusedInventoryItemId(pm, lv, currentIds)
                            local reordered = reorderEntriesByIds(rawEntries, sortedIds)
                            if applyObjectsToListView(pm, lv, reordered) then
                                local keepIdx = (keepId and indexOf(sortedIds, keepId)) or 1
                                scheduleListFocus(pm, pm, lv, cache, keepIdx - 1, keepId or sortedIds[1], false, nil)
                                cache.lastAppliedIds = sortedIds
                                cache.lastOrderVer = orderVersion
                            end
                        else
                            cache.lastAppliedIds = currentIds
                            cache.lastOrderVer = orderVersion
                        end
                    end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- BATTLE -> ITEM & THROW MENUS (SAVED ORDER + OPTIONAL Q/E CATEGORY PAGES)
-------------------------------------------------------------------------------
local BATTLE_ITEM_PAGES = {
    { id = "ALL",       label = "All" },
    { id = "HEAL",      label = "Heal / Revive" },
    { id = "CURE",      label = "Status Cure" },
    { id = "OFFENSIVE", label = "Offensive / Throw" },
    { id = "OTHER",     label = "Other" },
}

local loggedBattleItemSort = {}
local battleItemCache = {}      -- listAddr -> { unitKey, customEntries, entryClass, entryOuter, pageIdx, lastAppliedIds, wasFocused, restoreLockUntil, focusGen }
local lastBattleItemCursor = {} -- unitKey -> { pageIdx, itemId }
local wasPrevDown = false
local wasNextDown = false
local cachedSoundFn = nil
local origSecTitles = {}

local function itemBattlePageId(itemId)
    local info = loadItemInfo()
    local it = info and info[itemId]
    if not it then return "OTHER" end
    if it.roleSub == ROLE.REVIVE or it.roleSub == ROLE.HP_HEAL or it.roleSub == ROLE.MP_HEAL then
        return "HEAL"
    elseif it.roleSub == ROLE.CURE then
        return "CURE"
    elseif it.roleSub == ROLE.OFFENSIVE or it.isThrow then
        return "OFFENSIVE"
    end
    return "OTHER"
end

local function isRememberCursorEnabled(actionList)
    local foundOpt, optVal = false, false
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

local function getSavedBattleItemId(unitId)
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
                    if cmd.isUseItem and cmd.actionId and cmd.actionId > 0 then
                        foundId = cmd.actionId
                    end
                end
                break
            end
        end
    end)
    return foundId
end

local function getFocusedBattleItemId(actionList, pm, lv, currentIds)
    local focused = getFocusedInventoryItemId(pm, lv, currentIds)
    if focused and focused > 0 then return focused end

    local iid = 0
    pcall(function()
        local vm = kit.valid(actionList) and actionList.VM_BtlCmd
        if kit.valid(vm) and vm.FocusCmdData and vm.FocusCmdData.Value and vm.FocusCmdData.Value.ActionKey then
            local cat = num(vm.FocusCmdData.Value.ActionKey.Category)
            local id = num(vm.FocusCmdData.Value.ActionKey.ID)
            if cat == 2 and id > 0 and indexOf(currentIds, id) then
                iid = id
            end
        end
    end)
    if iid > 0 then return iid end
    return nil
end

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

local function updateSecondaryHeaderTitle(actionList, pageLabel)
    pcall(function()
        local outer = actionList:GetOuter()
        local secList = nil
        local guard = 0
        while kit.valid(outer) and guard < 6 do
            guard = guard + 1
            local cn = className(outer)
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
            local cn = className(w)
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

local function getBattlePathMenu(actionList)
    if not kit.valid(actionList) then return nil end
    local pm = nil
    pcall(function()
        if kit.valid(actionList.WBP_ListViewBase) then pm = actionList.WBP_ListViewBase
        elseif kit.valid(actionList.PathMenu) then pm = actionList.PathMenu
        end
    end)
    return pm
end

local function getOrRebuildBattleEntryObj(cache, lv, e, idx0)
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

local function applyBattleItemEntries(actionList, pm, lv, cache, entries, targetFocusIdx0, forceDelayedFocus)
    local count = #entries
    if count == 0 then return false end
    local focusIdx = math.min(math.max(0, targetFocusIdx0 or 0), count - 1)
    local targetItemId = entries[focusIdx + 1] and entries[focusIdx + 1].id or nil

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

    -- 3. Sync PathMenu.ListItems + CmnListView via ClearListItems + SetListItems
    pcall(function()
        local reordered = {}
        for i = 1, count do
            local obj = getOrRebuildBattleEntryObj(cache, lv, entries[i], i - 1)
            if kit.valid(obj) then reordered[#reordered + 1] = obj end
        end

        if #reordered == count then
            if kit.valid(pm) and pm.ListItems then
                pcall(function()
                    pm.ListItems:Empty()
                    for i, obj in ipairs(reordered) do pm.ListItems[i] = obj end
                end)
            end

            if kit.valid(lv) then
                pcall(function() lv:ClearListItems() end)
                local okSet = pcall(function() lv:SetListItems(reordered) end)
                if not okSet then
                    pcall(function()
                        for _, obj in ipairs(reordered) do lv:AddItem(obj) end
                    end)
                end
                pcall(function() lv:RegenerateAllEntries() end)
                pcall(function() lv:RequestRefresh() end)
            end
        elseif kit.valid(lv) then
            pcall(function() lv:RegenerateAllEntries() end)
            pcall(function() lv:RequestRefresh() end)
        end

        scheduleListFocus(actionList, pm, lv, cache, focusIdx, targetItemId, forceDelayedFocus, actionList.VM_BtlCmd)
    end)

    return true
end

local function filterBattleItemEntries(fullEntries, pageId)
    if pageId == "ALL" then return fullEntries end
    local out = {}
    for _, e in ipairs(fullEntries) do
        if itemBattlePageId(e.id) == pageId then
            out[#out + 1] = e
        end
    end
    return out
end

local function processBattleItemList(actionList, unitId, unitKey, pageDelta)
    if not kit.valid(actionList) then return false end

    -- Only process Battle Item / Throw lists (ActionKey.Category == 2 or ListObject contains "Item")
    local isItemList = false
    pcall(function()
        local lo = actionList.ListObject
        if kit.valid(lo) and lo:GetFullName():find("Item", 1, true) then
            isItemList = true
        end
    end)

    local pm = getBattlePathMenu(actionList)
    local lv = findListView(actionList.WBP_ListViewBase)
    local lvItems = readListViewItems(lv)
    if #lvItems == 0 then lvItems = readPathMenuItems(pm) end

    local currentIds, currentCats, currentValids, currentObjs = {}, {}, {}, {}
    local hasItemEntry = false

    if #lvItems > 0 then
        for _, item in ipairs(lvItems) do
            local okAk, cat, id, isVal = pcall(function()
                return num(item.ActionKey.Category), num(item.ActionKey.ID), item["In Is Valid"]
            end)
            if okAk and id and id > 0 then
                currentIds[#currentIds + 1] = id
                currentCats[#currentCats + 1] = cat
                currentValids[#currentValids + 1] = isVal
                currentObjs[#currentObjs + 1] = item
                if cat == 2 then hasItemEntry = true end
            end
        end
    end

    if #currentIds == 0 then
        pcall(function()
            local akList = actionList.ActionKeyList
            if akList then
                for i = 1, #akList do
                    local cat = num(akList[i].Category)
                    local id = num(akList[i].ID)
                    if id > 0 then
                        currentIds[#currentIds + 1] = id
                        currentCats[#currentCats + 1] = cat
                        currentValids[#currentValids + 1] = true
                        currentObjs[#currentObjs + 1] = lvItems[i]
                        if cat == 2 then hasItemEntry = true end
                    end
                end
            end
        end)
    end

    if #currentIds == 0 or (not isItemList and not hasItemEntry) then return false end
    -- Guard: if any entry is a skill (cat == 1) and ListObject is not Item, bail so SkillSorter owns it
    if not isItemList then
        for _, c in ipairs(currentCats) do
            if c == 1 then return false end
        end
    end

    local listAddr = nil
    pcall(function() listAddr = actionList:GetAddress() end)
    local cacheKey = tostring(listAddr or actionList:GetFullName())
    local cache = battleItemCache[cacheKey]

    local needsSnapshot = (not cache)
        or (cache.unitKey ~= unitKey)
        or (cache.orderVer ~= orderVersion)
        or (not sameIdList(currentIds, cache.lastAppliedIds))

    local isFocused = false
    pcall(function() isFocused = actionList:HasFocusedDescendants() or actionList:HasAnyUserFocus() end)
    if not isFocused and kit.valid(pm) then
        pcall(function() isFocused = pm:HasFocusedDescendants() or pm:HasAnyUserFocus() end)
    end
    if not isFocused and kit.valid(lv) then
        pcall(function() isFocused = lv:HasFocusedDescendants() or lv:HasAnyUserFocus() end)
    end

    local rememberOn = isRememberCursorEnabled(actionList)
    local restoreItemId = nil
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

        -- Apply saved Pause Menu order (or keep natural game order if untouched)
        local sortedIds = getSortedItemIds(currentIds, false, false, nil)
        local customEntries = reorderEntriesByIds(rawEntries, sortedIds)

        local initialPageIdx = 1
        if rememberOn then
            local mem = lastBattleItemCursor[unitKey]
            if mem then
                if cfg.PaginatedBattleItems and mem.pageIdx and BATTLE_ITEM_PAGES[mem.pageIdx] then
                    initialPageIdx = mem.pageIdx
                end
                restoreItemId = mem.itemId
            else
                restoreItemId = getSavedBattleItemId(unitId)
            end
        end

        cache = {
            unitKey = unitKey,
            orderVer = orderVersion,
            customEntries = customEntries,
            entryClass = entryClass,
            entryOuter = entryOuter,
            pageIdx = initialPageIdx,
            lastAppliedIds = nil,
            wasFocused = false,
            restoreLockUntil = 0,
            focusGen = 0,
        }
        battleItemCache[cacheKey] = cache
    else
        justFocused = isFocused and not cache.wasFocused
        if justFocused and rememberOn and pageDelta == 0 then
            local mem = lastBattleItemCursor[unitKey]
            if mem then
                if cfg.PaginatedBattleItems and mem.pageIdx and BATTLE_ITEM_PAGES[mem.pageIdx] then
                    cache.pageIdx = mem.pageIdx
                end
                restoreItemId = mem.itemId
            end
        end
    end

    local canPage = pageDelta ~= 0 and cfg.PaginatedBattleItems and isFocused
    local switchedPage = false

    if not cfg.PaginatedBattleItems then
        cache.pageIdx = 1
    elseif canPage and #cache.customEntries > 0 then
        local n = #BATTLE_ITEM_PAGES
        local idx = cache.pageIdx
        for _ = 1, n do
            idx = ((idx - 1 + pageDelta) % n) + 1
            local page = BATTLE_ITEM_PAGES[idx]
            local subset = filterBattleItemEntries(cache.customEntries, page.id)
            if #subset > 0 then
                if idx ~= cache.pageIdx then
                    cache.pageIdx = idx
                    switchedPage = true
                    restoreItemId = nil
                end
                break
            end
        end
    end

    local page = BATTLE_ITEM_PAGES[cache.pageIdx] or BATTLE_ITEM_PAGES[1]
    local targetEntries = filterBattleItemEntries(cache.customEntries, page.id)
    if #targetEntries == 0 then
        cache.pageIdx = 1
        page = BATTLE_ITEM_PAGES[1]
        targetEntries = filterBattleItemEntries(cache.customEntries, page.id)
    end

    local targetIds = {}
    for i, e in ipairs(targetEntries) do targetIds[i] = e.id end

    local targetFocusIdx0 = 0
    local hasRestoredTarget = false
    if not switchedPage and restoreItemId then
        local pos = indexOf(targetIds, restoreItemId)
        if pos then
            targetFocusIdx0 = pos - 1
            hasRestoredTarget = true
        end
    end

    local needApply = switchedPage or needsSnapshot or not sameIdList(currentIds, targetIds)
    if needApply then
        local lockFocus = switchedPage or hasRestoredTarget
        applyBattleItemEntries(actionList, pm, lv, cache, targetEntries, targetFocusIdx0, lockFocus)
        cache.lastAppliedIds = targetIds
        if lockFocus then
            cache.restoreLockUntil = os.clock() + (targetFocusIdx0 > 0 and 0.18 or 0.09)
        end
        updateSecondaryHeaderTitle(actionList, page.label)

        if switchedPage then
            playMenuBeep(actionList)
            lastBattleItemCursor[unitKey] = { pageIdx = cache.pageIdx, itemId = targetIds[1] }
            mod:log(string.format("Battle item page -> %s (%d items) for unit %s.", page.label, #targetEntries, unitKey))
        else
            local logKey = unitKey .. "|" .. actionList:GetFullName()
            if not loggedBattleItemSort[logKey] then
                loggedBattleItemSort[logKey] = true
                mod:log(string.format("Applied item order in battle for unit %s (%d items).", unitKey, #targetEntries))
            end
        end
    elseif justFocused and hasRestoredTarget then
        scheduleListFocus(actionList, pm, lv, cache, targetFocusIdx0, restoreItemId, true, actionList.VM_BtlCmd)
        cache.restoreLockUntil = os.clock() + (targetFocusIdx0 > 0 and 0.18 or 0.09)
    else
        cache.lastAppliedIds = targetIds
        if isFocused and os.clock() >= (cache.restoreLockUntil or 0) then
            local focusedIid = getFocusedBattleItemId(actionList, pm, lv, currentIds)
            if focusedIid and focusedIid > 0 then
                lastBattleItemCursor[unitKey] = { pageIdx = cache.pageIdx, itemId = focusedIid }
            end
        end
    end

    cache.wasFocused = isFocused
    return switchedPage
end

local function handleBattleItemSorting()
    if not mod.enabled then return end
    if kit.events and not kit.events.battle then
        if next(loggedBattleItemSort) then loggedBattleItemSort = {} end
        if next(battleItemCache) then battleItemCache = {} end
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
    if cfg.PaginatedBattleItems then
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
                if processBattleItemList(actionList, unitId, unitKey, pageDelta) then
                    pageDelta = 0
                end
            else
                local listAddr = nil
                pcall(function() listAddr = actionList:GetAddress() end)
                local ck = tostring(listAddr or actionList:GetFullName())
                if battleItemCache[ck] then
                    battleItemCache[ck].wasFocused = false
                end
            end
        end
    end
end

mod:on("saveLoaded", function()
    orderVersion = orderVersion + 1
    lastBattleItemCursor = {}
    battleItemCache = {}
    equipPickerCache = {}
    lastPauseAppliedIds = nil
end)

mod:every(50, handlePauseMenuItems, "handlePauseMenuItems")
mod:every(100, handleEquipPickerSorting, "handleEquipPickerSorting")
mod:every(50, handleBattleItemSorting, "handleBattleItemSorting")
