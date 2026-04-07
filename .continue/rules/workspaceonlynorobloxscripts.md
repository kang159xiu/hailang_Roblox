---
globs: "**/*"
regex: .*
description: Applies to all work; ensures edits stay within VSCode workspace and
  avoids modifying Roblox Studio script instances.
alwaysApply: true
---

Only modify files under the VSCode workspace folder. Do NOT modify Roblox Studio script instance code (e.g., ServerScriptService/ReplicatedStorage scripts) via roblox tools. Roblox Studio edits are allowed only for non-script instances/properties and must not change any script code; if Rojo-managed, prefer changes through workspace assets/config instead.