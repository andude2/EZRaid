### EZRaid

Standalone raid formation tool written in Lua, with an easy to use ImGui interface.

<img width="1247" height="718" alt="ez raid start" src="https://github.com/user-attachments/assets/b0a503a5-c961-4cb2-8a7e-52e99a98ac4d" />

## Features
- Build 1–12 raid group layouts.
- Maintain a personal roster of PC names.
- Scan Connected PCs: discovers peers from MQ2Mono/E3, then DanNet, then EQBC and adds them to your roster.
- Save/load named layouts (JSON in `mq.configDir`).
- Form raid from layout: invites all listed PCs, auto-confirms any raid prompts, then arranges them into groups via the in-game Raid window.
- Apply layout: only moves players already listed in the "Not In Group" list.
- Scan current raid: reads live raid members and fills the current layout with their existing group assignments.

<img width="773" height="627" alt="ez raid multi group" src="https://github.com/user-attachments/assets/cc5b4533-7393-45e2-b009-fa92cc57f8a1" />

## Raid HUD
- Keep track of the basics of your raid.  Reads from TLO's, not from DanNet/Actors/E3/EQBC.
- Does not rely on a direct connection/peer connection.
- Multiple setups for the HUD - alphabetical, by group, by class, by name and class, multiple group windows to drag around...
  
<img width="305" height="534" alt="ez raid hud" src="https://github.com/user-attachments/assets/e83fe365-5321-4014-88cb-9bf44622124b" />

Usage
- Load: `/lua run EZRaid` (or add to your MQ startup scripts).
- Open UI: `/ezraid`
- Left pane: manage a roster of known player names (add/remove). These names are used when filling layout slots.
- Right pane: manage saved layouts, then build and apply a layout to the active raid.
- Use “Scan Current Raid” to prefill the first layout using the current raid’s group assignments.
 - Use “Scan Connected PCs” to populate your roster from currently connected peers (Mono → DanNet → EQBC).

Notes
- Invites use `/raidinvite <name>` and, if the confirmation dialog appears, automatically click `ConfirmationDialogBox -> CD_Yes_Button`.
- Movement of players to groups uses the in-game Raid window controls: selects the player in `RAID_NotInGroupPlayerList`, then clicks the corresponding `RAID_GroupNButton`.
