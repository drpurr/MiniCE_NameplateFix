# MiniCE Nameplate Fix

WoW Forever addon that makes MinimalistCooldownEdge (MiniCE) style the aura timers on Blizzard nameplates.

- **Styling**: Blizzard sets a nameplate aura's cooldown before parenting the icon to the plate, so MiniCE marks it "not mine" and never styles it. This claims those cooldowns for MiniCE's Nameplate category after every aura refresh.
- **Threshold colors**: MiniCE never applies its "Color by Remaining Time" colors to nameplates. This colors nameplate timers with those thresholds whenever the game lets addons read aura durations. While auras are restricted, timers keep MiniCE's static nameplate color.

Requires MinimalistCooldownEdge.
