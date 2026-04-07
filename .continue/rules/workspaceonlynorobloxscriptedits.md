---
globs: "**/*"
regex: .*
description: Applies to all tasks involving file edits or Roblox Studio changes.
alwaysApply: true
---

Only modify files within the VSCode workspace folder. Do not modify Roblox Studio script instance code (e.g., ServerScriptService/ReplicatedStorage) using Roblox tools. Roblox Studio changes are allowed only for non-script instances/properties and must not change any script code; if Rojo-managed, prefer implementing changes via workspace assets/configuration.