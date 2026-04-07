---
globs: "**/*"
regex: .*
description: "Applies to all tasks: constrain edits to VSCode workspace files
  and never edit Roblox Studio script instance code; allow only non-script
  instance/property edits and prefer Rojo-managed workspace changes."
alwaysApply: true
---

Only modify files within the VSCode workspace folder. Do not directly edit Roblox Studio script instance code (e.g., ServerScriptService/ReplicatedStorage scripts) using Roblox tools. You may modify Roblox Studio non-script instances/properties, but must ensure no script code is changed; if Rojo-managed, prefer implementing changes via workspace assets/configuration.