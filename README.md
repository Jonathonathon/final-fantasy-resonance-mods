# Final Fantasy Resonance — MogHub Mods

A collection of quality-of-life and gameplay plugins for **FINAL FANTASY RESONANCE** built for the **[MogHub](https://github.com/jesus-seijas-sp/ffr-moghub)** mod framework.

## Included Mods

| Mod | Folder | Summary |
| --- | --- | --- |
| **Skill Sorter** | `SkillSorter` | Manually reorder skills in the Pause Menu, auto-sort by type & power, and filter skills by category pages in combat. |
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
2. Copy the `SkillSorter`, `VisionMasteryAP`, and/or `BuffCapRemoval` folders into your UE4SS `Mods` folder:
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
                       ├── VisionMasteryAP\
                       │   ├── moghub.ini
                       │   ├── moghub.lua
                       │   └── config.ini
                       └── BuffCapRemoval\
                           ├── moghub.ini
                           ├── moghub.lua
                           └── config.ini
   ```
4. Launch **FINAL FANTASY RESONANCE**, open **Main Menu → Mods**, and confirm the installed mods (**Skill Sorter**, **Vision Spells & AP Expansion**, and/or **Buff Cap Removal**) appear in the list and are enabled.

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

Removes the vanilla 5-turn stacking cap on extendable continuous effects (such as buffs and formations like Nichol's) so additional duration isn't wasted when stacking turns. All changes are applied at runtime to the `SKILL_GENERAL_DATA` table and never modify your save file.

#### Settings
* **In-game (`Main Menu → Mods → Buff Cap Removal`, or `BuffCapRemoval/config.ini`):**
  * **Max Buff Duration** (`MaxBuffDuration`):
    * **`5`** *(default)*: Vanilla 5-turn maximum duration cap.
    * **`99`**: Allows extendable continuous effects to stack up to **99 turns**.

> [!NOTE]
> `SKILL_GENERAL_DATA.effectMaxLifeTime` is a global duration cap shared by any extendable continuous effect (`isExtendLifeTurn = true`). Setting it to `99` affects buffs/formations as well as any extendable debuffs or status effects that share that cap.

---

## Uninstalling

* **Skill Sorter:** Delete the `SkillSorter` folder from `FFRS\Binaries\Win64\ue4ss\Mods\`.
* **Buff Cap Removal:** Delete the `BuffCapRemoval` folder from `FFRS\Binaries\Win64\ue4ss\Mods\` (no save data is modified).
* **Vision Spells & AP Expansion:**
  > [!IMPORTANT]
  > If you used **Permanent** mode and want to remove permanently granted Vision spells from your save first, load your save, open **Main Menu → Mods → Vision Spells & AP Expansion**, switch **Vision Spells** to **Disabled** (and **Awakening Abilities** to **Off**), save your game, and then close the game and delete the `VisionMasteryAP` folder.

---

## Troubleshooting

* **No "Mods" option on the Title Screen / Main Menu:** Make sure both **UE4SS** and **MogHub** are installed correctly (and that Steam Deck / Linux users set `WINEDLLOVERRIDES="dwmapi=n,b" %command%`).
* **A mod doesn't show up in MogHub:** Check that there isn't an extra nested folder (for example, `Mods\SkillSorter\SkillSorter\moghub.ini` will not load — `moghub.ini` must be directly inside `Mods\SkillSorter\`).
* **Settings aren't saving:** Make sure the game folder isn't set to read-only and that you don't have a conflicting copy of the mod elsewhere in `ue4ss\Mods\`.
