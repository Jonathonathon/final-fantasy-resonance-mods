# Final Fantasy Resonance — MogHub Mods

A collection of quality-of-life and gameplay plugins for **FINAL FANTASY RESONANCE** built for the **[MogHub](https://github.com/jesus-seijas-sp/ffr-moghub)** mod framework.

## Included Mods

| Mod | Folder | Summary |
| --- | --- | --- |
| **Skill Sorter** | `SkillSorter` | Manually reorder skills in the Pause Menu, auto-sort by type & power, and filter skills by category pages in combat. |
| **Item Sorter** | `ItemSorter` | Manually reorder items in the Pause Menu, auto-sort by Alphabetical / Type & Power / Quantity / Price (grouped by category), sort the Equipment picker, and optionally page Battle Items. |
| **Vision Spells & AP Expansion** | `VisionMasteryAP` | Unlock Vision Awakening spells via Synchro Mastery (`10 AP` or `Permanent` 0 AP) and make Awakening passive abilities individually equippable. |
| **Buff Cap Removal** | `BuffCapRemoval` | Raise the maximum stackable buff/effect turn duration cap in combat from `5` turns up to `99` turns. |

> [!TIP]
> **Mod Synergy:** All mods work independently, or together. When installed together, **Skill Sorter** automatically turns on **Paginated Abilities** by default if **Vision Spells** is set to **Permanent** (until you manually toggle it yourself).

---

## Requirements

Before installing any of these mods, you must have the following installed:

1. **FINAL FANTASY RESONANCE** (PC)
2. **[UE4SS (RE-UE4SS)](https://github.com/UE4SS-RE/RE-UE4SS/releases)** — Required script/mod loader for Unreal Engine 5.
3. **[MogHub](https://github.com/jesus-seijas-sp/ffr-moghub)** — **Required.** All mods in this repository are MogHub plugins and will not load without MogHub installed.

---

## Installation

### 1. Install UE4SS (Skip if already installed)

1. Download the latest release zip from the [RE-UE4SS Releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases).
2. Extract its contents into the game's `Win64` folder:
   ```text
   <Game Folder>\FFRS\Binaries\Win64\
   ```
   *(Default Steam path: `C:\Program Files (x86)\Steam\steamapps\common\FINAL FANTASY RESONANCE\FFRS\Binaries\Win64\`)*
3. Open `FFRS\Binaries\Win64\ue4ss\UE4SS-settings.ini` in a text editor and verify the engine version override under `[EngineVersionOverride]` matches the game's Unreal Engine version (check the MogHub page if a game update changed this):
   ```ini
   [EngineVersionOverride]
   MajorVersion = 5
   MinorVersion = 6
   ```

> [!NOTE]
> **Steam Deck / Linux (Proton) users:** In Steam, open **Properties → General → Launch Options** for *FINAL FANTASY RESONANCE* and add:
> ```text
> WINEDLLOVERRIDES="dwmapi=n,b" %command%
> ```

### 2. Install MogHub (Skip if already installed)

1. Download the latest `MogHub-x.x.x.zip` release from the [MogHub GitHub repository](https://github.com/jesus-seijas-sp/ffr-moghub) (or Nexus Mods).
2. Extract the zip directly into your **main game folder** (the folder that contains the `FFRS` directory):
   ```text
   C:\Program Files (x86)\Steam\steamapps\common\FINAL FANTASY RESONANCE\
   ```
3. Confirm that `FFRS\Binaries\Win64\ue4ss\Mods\MogHub\` exists.

### 3. Install These Mods

1. Download this repository by clicking the green **`<> Code`** button at the top of this page and selecting **Download ZIP** (then extract it).
2. Copy the `SkillSorter`, `ItemSorter`, `VisionMasteryAP`, and/or `BuffCapRemoval` folders into your UE4SS `Mods` folder:
   ```text
   <Game Folder>\FFRS\Binaries\Win64\ue4ss\Mods\
   ```
3. Your final folder layout should look like this:
   ```text
   FINAL FANTASY RESONANCE\
   └── FFRS\
       └── Binaries\
           └── Win64\
               └── ue4ss\
                   └── Mods\
                       ├── MogHub\
                       ├── SkillSorter\
                       │   ├── moghub.ini
                       │   ├── moghub.lua
                       │   └── config.ini
                       ├── ItemSorter\
                       │   ├── moghub.ini
                       │   ├── moghub.lua
                       │   └── config.ini
                       ├── VisionMasteryAP\
                       │   ├── moghub.ini
                       │   ├── moghub.lua
                       │   └── config.ini
                       └── BuffCapRemoval\
                           ├── moghub.ini
                           ├── moghub.lua
                           └── config.ini
   ```
4. Launch **FINAL FANTASY RESONANCE**, open **Main Menu → Mods**, and confirm the installed mods (**Skill Sorter**, **Item Sorter**, **Vision Spells & AP Expansion**, and/or **Buff Cap Removal**) appear in the list and are enabled.

---

## Mod Details & Usage

### Skill Sorter (`SkillSorter`)

Lets you organize each character's skill list and browse abilities faster in battle. Custom skill orders are saved automatically per save slot and applied in both the Pause Menu and combat.

#### Controls

| Action | Where | Keyboard | Controller |
| --- | --- | --- | --- |
| Pick up / Drop skill | Pause Menu → Skills | `R` | `X` (Xbox) / `Square` (PS) |
| Cancel pick-up | Pause Menu → Skills | `C` | `B` (Xbox) / `Circle` (PS) |
| Auto-sort by type & power *(press twice within 3s)* | Pause Menu → Skills | `G` | `Y` (Xbox) / `Triangle` (PS) |
| Previous / Next category page | Battle → Skills | `Q` / `E` | `LB` / `RB` (Xbox) / `L1` / `R1` (PS) |

#### Settings
* **In-game (`Main Menu → Mods → Skill Sorter`):**
  * **Paginated Abilities:** Toggles category paging in combat (`All`, `Physical`, `Heal`, `Magic`, `Buff / Debuff`, `Other`). Works with the game's *Remember Cursor Location* setting.
* **Custom Keyboard Keybinds (`SkillSorter/config.ini`):**
  For non-QWERTY layouts or personal preference, you can set `PickDropKey`, `CancelKey`, `AutoSortKey`, `PrevPageKey`, and `NextPageKey`.

---

### Item Sorter (`ItemSorter`)

Brings the same organization tools as **Skill Sorter** to your inventory, equipment picker, and battle item menus. Custom item orders are saved automatically per save slot and applied across Pause Menu → Items, Equipment & Abilities, and Battle → Item / Throw.

#### Controls

| Action | Where | Keyboard | Controller |
| --- | --- | --- | --- |
| Pick up / Drop item | Pause Menu → Items | `R` | `X` (Xbox) / `Square` (PS) |
| Cancel pick-up | Pause Menu → Items | `C` | `B` (Xbox) / `Circle` (PS) |
| Auto-sort using selected mode, or restore Vanilla if already sorted *(press twice within 3s)* | Pause Menu → Items | `G` | `Y` (Xbox) / `Triangle` (PS) |
| Previous / Next category page *(when enabled)* | Battle → Item / Throw | `Q` / `E` | `LB` / `RB` (Xbox) / `L1` / `R1` (PS) |

#### Settings
* **In-game (`Main Menu → Mods → Item Sorter`):**
  * **Auto-Sort Mode** (`AutoSortMode`): Choose what order double-tapping `G` / `Y` applies (all non-Vanilla modes stay **grouped by category**: Consumables → Weapons → Armor → Accessories → Visions → Valuables → Artifacts):
    * **Alphabetical (A–Z)** *(default)*: Case-insensitive alphabetical order within each category.
    * **Type & Power**: Smart sort — Consumables grouped by role (Revive → HP Heal → MP Heal/Elixir → Status Cure → Buff → Offensive/Throw) then potency; Weapons & Armor grouped by subtype (Greatsword, Katana, Rod, Heavy Armor, Robe, etc.) then primary stat; Accessories by stat total & passives.
    * **Quantity (High–Low)**: Most stocked items first, tie-broken alphabetically.
    * **Value / Price (High–Low)**: Highest value items first, tie-broken alphabetically.
    * **Vanilla**: Restores the game's default `SortId` order and clears saved custom order.
  * **Sort Equipment Picker** (`SortEquipPicker`, default `On`): Applies your saved order (or selected Auto-Sort Mode) inside the **Equipment & Abilities** weapon, armor, and accessory picker (always keeping any Unequip/Remove row pinned at the top).
  * **Paginated Battle Items** (`PaginatedBattleItems`, default `On`): Enables `Q` / `E` (or `LB` / `RB`) category paging inside **Battle → Item / Throw** (`All`, `Heal / Revive`, `Status Cure`, `Offensive / Throw`, `Other`), compatible with *Remember Cursor Location*.
* **Custom Keyboard Keybinds (`ItemSorter/config.ini`):**
  For non-QWERTY layouts or personal preference, you can set `PickDropKey`, `CancelKey`, `AutoSortKey`, `PrevPageKey`, and `NextPageKey`.

---

### Vision Spells & AP Expansion (`VisionMasteryAP`)

Expands Vision Mastery so unlocked Awakening spells and passives can be retained and mixed across builds. All options can be changed live in-game under **Main Menu → Mods → Vision Spells & AP Expansion** (or edited in `VisionMasteryAP/config.ini`).

#### Settings
* **Vision Spells** (`VisionSpellsMode`):
  * **Disabled (`disabled`):** Vanilla Vision behavior.
  * **10 AP (`ap10`):** Unlocked Vision Awakening spells unlock via Synchro Mastery for **10 AP** each and can be used by any character.
  * **Permanent (`permanent`):** Unlocked Vision spells are automatically learned permanently (**0 AP**, no ability slot used). Switching back to `10 AP` or `Disabled` cleanly reverts spells granted by Permanent mode.
* **Awakening Abilities** (`AwakeningAbilitiesMode`):
  * **Off (`off`):** Awakening Level passive abilities only apply while that Vision is equipped (vanilla).
  * **Equippable (`equippable`):** Unlocked Awakening Level passive abilities can be equipped individually in *Equipment & Abilities* at their inherited AP cost, and are also included when equipping a full Vision Master Skill (at unchanged AP cost).

---

### Buff Cap Removal (`BuffCapRemoval`)

Lets player buffs and formations stack duration additively up to **99 turns** when re-cast instead of merely refreshing, while keeping everything 100% DataTable-driven (zero raw memory hacks, zero performance impact, and no save-file edits).

#### How It Works
In *FINAL FANTASY RESONANCE*, re-casting a buff natively **refreshes** its remaining duration via `max(current, castDuration)` rather than adding turns (`4 + 5` stays `5`), and live buff objects (`CPP_ContEffect`) only expose read-only getters to UE4SS Lua. Rather than using fragile raw C++ memory patching that can break on game updates, **Buff Cap Removal** uses the game's own native `ExtendEffectTurnById` DataTable effect (`SKILL_EFFECT_DATA #19014`) combined with raising the global `SKILL_GENERAL_DATA.effectMaxLifeTime` cap (vanilla `10` → `99`). Whenever a player casts a configured buff skill, the mod dynamically scopes `#19014` on `CPP_BtlSkillBeginDelVal` exclusively to **that skill's own buff effect(s)** before applying it — so re-casting one formation or buff only extends that specific buff (never unrelated buffs, enemy skills, or *God of Water's Blessing*'s vanilla behavior), with **no cap on how many buffs can be enabled**.

#### Settings
* **In-game (`Main Menu → Mods → Buff Cap Removal`):**
  * **Max Buff Duration** (`MaxBuffDuration`):
    * **`5`** *(default)*: Vanilla behavior (restores all DataTables cleanly).
    * **`99`**: Raises the global duration cap to **99 turns** and enables additive turn stacking on all buffs listed in `ExtendedEffects`.
  * **Spell Duration on Cast** (`SpellDurationOnCast`):
    * **Standard (`standard`)** *(default)*: Buffs are cast with their normal base turn durations.
    * **Unlimited (`unlimited`)**: Every player buff and formation (excluding Defend) is cast directly with **99 turns** (also raises the global duration cap to 99 so casts aren't clamped). Debuffs, bad statuses, and enemy-only buffs are unaffected.
* **Customizing Affected Buffs (`BuffCapRemoval/config.ini`):**
  * **`ExtendedEffects`**: Comma-separated list of Effect IDs (or friendly alias names) to enable additive stacking for. **All 31 player buff & formation effects are enabled by default** — simply remove any IDs you prefer to keep vanilla. Changes are picked up automatically within 1 second even while the game is running.
  * **`TurnsAddedPerRecast`**: Number of turns added per re-cast (default `3`; set to `0` to automatically match each buff's own base duration).
  * A complete commented **Buff Effect ID Reference List** (covering Nichol's Formations & Tactics, Hastega/Haste, Protectga/Protect, Shellga/Shell, Manaward, Bravery, Faith, Regen/Healing Ruby, Reflect, and character stance buffs like *Hone Senses*, *Eminent Casting*, *Concentrate*, *Gut Rip*, *Placidity*, *Sage's Eye*, etc.) is included directly inside `BuffCapRemoval/config.ini` so you never have to hunt for IDs.

---

## Uninstalling

* **Skill Sorter:** Delete the `SkillSorter` folder from `FFRS\Binaries\Win64\ue4ss\Mods\`.
* **Item Sorter:** Delete the `ItemSorter` folder from `FFRS\Binaries\Win64\ue4ss\Mods\`.
* **Buff Cap Removal:** Delete the `BuffCapRemoval` folder from `FFRS\Binaries\Win64\ue4ss\Mods\` (no save data is modified).
* **Vision Spells & AP Expansion:**
  > [!IMPORTANT]
  > If you used **Permanent** mode and want to remove permanently granted Vision spells from your save first, load your save, open **Main Menu → Mods → Vision Spells & AP Expansion**, switch **Vision Spells** to **Disabled** (and **Awakening Abilities** to **Off**), save your game, and then close the game and delete the `VisionMasteryAP` folder.

---

## Troubleshooting

* **No "Mods" option on the Title Screen / Main Menu:** Make sure both **UE4SS** and **MogHub** are installed correctly (and that Steam Deck / Linux users set `WINEDLLOVERRIDES="dwmapi=n,b" %command%`).
* **A mod doesn't show up in MogHub:** Check that there isn't an extra nested folder (for example, `Mods\SkillSorter\SkillSorter\moghub.ini` will not load — `moghub.ini` must be directly inside `Mods\SkillSorter\`).
* **Settings aren't saving:** Make sure the game folder isn't set to read-only and that you don't have a conflicting copy of the mod elsewhere in `ue4ss\Mods\`.
