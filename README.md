EZRaid
=====

Standalone raid helper for live PCs using MacroQuest Lua + ImGui.

Features
- Build 1–12 raid group layouts (6 slots each).
- Maintain a personal roster of PC names.
- Scan Connected PCs: discovers peers from MQ2Mono/E3, then DanNet, then EQBC and adds them to your roster.
- Save/load named layouts (JSON in `mq.configDir`).
- Form raid from layout: invites all listed PCs, auto-confirms any raid prompts, then arranges them into groups via the in-game Raid window.
- Apply layout: only moves players already listed in the "Not In Group" list.
- Scan current raid: reads live raid members and fills the current layout with their existing group assignments.

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
- This tool never spawns bots; it is intended for live PCs only.
