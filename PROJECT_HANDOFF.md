# 项目交接文档

## 1. 当前进度

当前项目已完成本轮围绕 **`PlacementService.luau`** 与 **`HomeService.luau`** 的一组关键修复，代码状态为：**本地逻辑已更新完成，待 Roblox Studio 实机回归验证**。

本轮最新开发进度如下：

- 已完成家园升级交互从 `ClickDetector` 向 `ProximityPrompt` 切换。
- 已完成房屋按等级的真实隐藏/恢复，改为通过 `Parent = nil` 与缓存恢复控制。
- 已完成 `collectSlots()` 补扫隐藏房屋缓存，避免 2/3 级房屋隐藏后丢失 `11~30` 槽位。
- 已完成放置区与收币区触碰逻辑拆分，避免 `Platform` 与 `Collector` 判定混用。
- 已完成解锁提示站位判定重构，改为基于世界坐标的绝对距离判断，解决二三层旋转地块导致的“解锁提示不出现”问题。
- 已完成收益 UI 机制重构，改为直接克隆 `BillboardGui` 并挂到 `Collector`，去除旧的整块 Part 克隆与反复重建逻辑。
- 已完成收益显示模板查找逻辑放宽，改为全局遍历 `Workspace` 查找名为 `收益显示` 的对象，并提取其内部 `BillboardGui`。

**当前结论：**

- 本地脚本修复已落地；
- 尚未完成 Roblox Studio Play 模式的完整回归；
- 当前应视为：**代码已修复，下一步应先做 Studio 验证，而不是继续大改逻辑。**

---

## 2. 已执行操作

### 2.1 已修改的本地 Lua 脚本

本轮已修改以下本地脚本：

1. `src/server/ServerScriptService/Modules/PlacementService.luau`
2. `src/server/ServerScriptService/Modules/HomeService.luau`

### 2.2 `PlacementService.luau` 已执行修改

#### （1）解锁提示站位判定重写

- 已重写 `isPlayerStandingOnSlot(player, slotPart)`。
- 已彻底抛弃原 `PointToObjectSpace()` 本地坐标判定。
- 当前改为：
  - 直接比较 `HumanoidRootPart.Position.Y` 与 `slotPart.Position.Y` 的高度差；
  - 要求 `Y` 差值在 `0 ~ 8`；
  - 在 `XZ` 平面用 `Vector2(...).Magnitude` 计算水平距离；
  - 以 `math.max(slotPart.Size.X, slotPart.Size.Z)` 作为判定半径。
- 该修改用于解决：**二三层 Platform 被旋转后，本地坐标轴失真导致解锁 Prompt 不出现的问题。**

#### （2）收益 UI 机制重构为 BillboardGui 直挂载

- 旧方案：克隆整个收益显示 Part，再额外处理位置同步、显隐与内部文本校验。
- 新方案：
  - 直接获取模板中的 `BillboardGui`；
  - 克隆后直接 `Parent` 到槽位 `Collector`（若无 Collector 则回退到 `slotPart`）；
  - 不再依赖独立 Part 作为 UI 载体；
  - 不再每秒反复 Destroy / Clone。
- 目标是彻底解决：**收益 UI 闪烁、结构脆弱、数值更新链路被旧校验拦截**的问题。

#### （3）收益模板获取逻辑放宽

- 已重写 `getIncomeDisplayTemplate()`。
- 不再强依赖固定路径 `Workspace.区域.收益显示`。
- 当前实现为：
  - 遍历 `Workspace:GetDescendants()`；
  - 查找名字为 `收益显示` 的 `BasePart / Model / Folder`；
  - 在其内部递归寻找第一个 `BillboardGui`。
- 若仍找不到模板，会输出明确的调试警告，提示：
  - `Workspace` 下是否存在名为 `收益显示` 的对象；
  - 该对象内部是否包含 `BillboardGui`。

#### （4）收益显示刷新逻辑精简

- `setIncomeDisplayText()` 现在仅负责：
  - 在 `BillboardGui` 后代中找第一个 `TextLabel`；
  - 直接写入四行文本：
    - 怪物等级
    - 每秒收益
    - 未领取收益
    - 价值
- `refreshIncomeDisplayForSlot()` 现在只做：
  - 确保当前槽位存在一个稳定的 `BillboardGui`；
  - 判断槽位是否仍在 `Workspace` 内；
  - 根据是否已放置怪，更新“未放置”文案或实际收益数值。

#### （5）收益可见性判定修正

- 已重写 `isSlotCurrentlyVisible(slotPart)`。
- 不再通过 `Transparency < 1` 判断槽位是否可见。
- 当前只判断：

```lua
slotPart:IsDescendantOf(workspace)
```

- 原因：现在未解锁/未显示楼层的房屋会被 `Parent = nil` 移出场景树，而 `Platform` 本身又可能是透明逻辑块，因此透明度不能再作为 UI 更新开关。

#### （6）放置与收币触碰逻辑拆分

- `slot.Part.Touched` 现在只负责：
  - `tryPlaceFromEquippedTool(player, slot.Part)`
- `slot.Collector.Touched` 现在只负责：
  - `payoutIfAny(player, slot.Part)`
- 两条链路均保留：
  - `__DataLoaded` 判定；
  - 玩家角色命中判定；
  - 独立 debounce 防抖。

### 2.3 `HomeService.luau` 已执行修改

#### （1）新增隐藏房屋缓存

- 已新增：

```lua
local hiddenHousesCache: {[Instance]: {[number]: Instance}} = {}
```

- 用于缓存被 `Parent = nil` 隐藏的 2/3 级房屋模型。

#### （2）房屋显示逻辑改为 Parent 控制

- 已重写 `applyHomeLevelToHome(homeRoot, homeLevel)`：
  - `lvl <= homeLevel`：显示该等级房屋；
  - `lvl > homeLevel`：缓存到 `hiddenHousesCache[homeRoot][lvl]` 并执行 `Parent = nil`。
- 这样实现了真正的：
  - 视觉移除；
  - 物理移除；
  - 层级树移除。

#### （3）槽位收集逻辑补扫隐藏房屋

- 已重写 `collectSlots(homeRoot)`。
- 新逻辑不再只扫描 `homeRoot:GetDescendants()`。
- 现在会先扫描当前在场景中的结构，再额外扫描：

```lua
hiddenHousesCache[homeRoot]
```

- 这样即使 2/3 级房屋被隐藏到缓存中，内部的 `怪放置区域11~30 / Platform / Collector` 也能被完整收集。
- 该修改用于修复：**升级后或隐藏房屋状态下，11~30 槽位收集不到、无法正常放置/收币的问题。**

#### （4）升级交互改为 ProximityPrompt

- 已废弃旧的 ClickDetector 交互链路。
- 已新增 `ensureUpgradePrompt()`。
- 在升级交互零件上创建 `HomeUpgradePrompt`，属性包括：
  - `ActionText = "升级家园"`
  - `ObjectText = "家园"`
  - `KeyboardKeyCode = Enum.KeyCode.E`
  - `HoldDuration = 0.5`
  - `RequiresLineOfSight = false`

#### （5）升级触发逻辑迁移完成

- 已通过 `Prompt.Triggered` 替代原 `MouseClick`。
- 原有核心流程保持不变：
  - 校验归属玩家；
  - 读取当前家园等级；
  - 计算升级消耗；
  - 扣金币；
  - 写回新等级；
  - 刷新房屋显示；
  - 刷新升级 UI；
  - 刷新 Prompt 状态；
  - `DataDirtyService.MarkDirty(...)`；
  - toast 提示。

### 2.4 Studio 场景/属性调整情况

**截至当前，没有通过 MCP 对 Roblox Studio 场景做实际修改。**

也就是说：

- **已改动：本地 Lua 脚本**
- **未改动：Studio 场景对象属性 / 模型结构 / BillboardGui 模板资源**

如果后续实机出现异常，需要再通过 MCP 检查以下场景资源是否符合代码假设：

- `Workspace` 下是否存在名为 `收益显示` 的模板对象
- 该模板内部是否确实存在唯一可用的 `BillboardGui + TextLabel`
- `HOME01 ~ HOME08` 结构是否完整
- 各 `怪放置区域01 ~ 30` 下是否都有正确的 `Platform / Collector`
- 各 HOME 的 `1级房屋 / 2级房屋 / 3级房屋` 命名是否完全一致
- 各 HOME 下 `升级区域` 的交互 Part 是否就是代码实际命中的那个 BasePart

---

## 3. 核心逻辑

### 3.1 家园等级房屋显示/隐藏逻辑

当前复杂功能之一是：**根据玩家家园等级（1~3）动态控制房屋模型是否真实存在于场景树中。**

当前实现思路：

1. 每个 HOME 下默认存在 `1级房屋 / 2级房屋 / 3级房屋`。
2. 运行时调用 `applyHomeLevelToHome(homeRoot, homeLevel)`。
3. 对于大于当前等级的房屋：
   - 缓存到 `hiddenHousesCache[homeRoot][lvl]`
   - 执行 `house.Parent = nil`
4. 对于当前应显示的房屋：
   - 优先从 `homeRoot` 查找；
   - 查不到则从缓存恢复；
   - 再挂回 `homeRoot`。
5. 由于隐藏房屋会脱离场景树，因此 `collectSlots(homeRoot)` 必须同时扫描：
   - `homeRoot` 当前可见结构；
   - `hiddenHousesCache[homeRoot]` 中缓存结构。

这一套机制的目标是：

- 让房屋隐藏是真隐藏，而不只是透明；
- 避免残留碰撞、交互、遮挡；
- 同时不丢失高等级房屋内部的槽位结构信息。

### 3.2 家园升级交互逻辑

当前复杂功能之二是：**家园升级交互链路统一基于 `ProximityPrompt`。**

实现思路：

1. 在升级区域交互 Part 上创建 `HomeUpgradePrompt`。
2. 玩家触发时先校验该 HOME 的 `OwnerUserId` 是否与触发玩家一致。
3. 读取当前家园等级，计算下一次升级价格：
   - 1 → 2：`10000`
   - 2 → 3：`50000`
   - 3 级：不可继续升级
4. 若金币足够则扣费并升级。
5. 升级后同步执行：
   - `PlayerData.SetHomeLevel(...)`
   - `applyHomeLevelToHome(...)`
   - `updateUpgradeGui(...)`
   - `refreshUpgradePromptEnabled(...)`
   - `DataDirtyService.MarkDirty(...)`

### 3.3 解锁提示站位判定逻辑

当前复杂功能之三是：**解锁提示只在玩家真正站上对应槽位时出现，且不受旋转影响。**

旧问题：

- 原逻辑依赖 `slotPart.CFrame:PointToObjectSpace(hrp.Position)`；
- 当二三层平台在建模时发生旋转，本地 `Y` 轴与视觉上“站在上面”的方向不再一致；
- 最终导致玩家明明站在区域上，解锁提示却不出现。

当前实现：

- 直接使用世界坐标：
  - `HRP.Y - slotPart.Y` 在 `0 ~ 8` 之间；
  - `XZ` 平面距离小于 `math.max(slotPart.Size.X, slotPart.Size.Z)`。

这样即使地块发生旋转，判定仍然稳定。

### 3.4 放置区与收币区逻辑拆分

当前复杂功能之四是：**将同一块区域上的两种碰撞行为彻底拆分。**

旧问题：

- 以前 `slot.Part.Touched` 同时处理：
  - 放置怪；
  - 收金币。
- 这会导致站上平台时逻辑混乱，出现误触发。

当前实现：

- `slot.Part.Touched`：只做放置怪。
- `slot.Collector.Touched`：只做收取收益。

并且两条链路都保留：

- 数据加载完成判定；
- 玩家角色判定；
- 独立 debounce key。

### 3.5 收益显示 UI 逻辑

当前复杂功能之五是：**收益显示 UI 已从“克隆整块 Part”重构为“直接挂 BillboardGui”，并适配房屋显隐机制。**

实现思路：

1. 模板通过全局搜索 `Workspace:GetDescendants()` 获取名为 `收益显示` 的对象。
2. 在该对象内部递归寻找 `BillboardGui` 作为模板。
3. 每个槽位初始化时，克隆一个 `BillboardGui`：
   - 优先挂到 `Collector`
   - 若没有 `Collector`，则回退挂到 `slotPart`
4. 每秒刷新时，不再重建 UI，只更新 `TextLabel.Text`。
5. 槽位是否可显示，只判断其是否仍在 `Workspace` 内。

这一套逻辑的目标是：

- 消除频繁 Destroy / Clone 引发的闪烁；
- 解决透明 Platform 导致 UI 永远不刷新的问题；
- 降低对模板层级的耦合度，提高场景容错性。

---

## 4. 待办任务

下一轮对话建议立即执行以下步骤：

### 第一优先级：Roblox Studio 实机回归

需要在 Studio Play 模式下重点验证以下内容：

1. **HOME 分配与释放**
   - 玩家进入是否会正确分配到一个空 HOME。
   - 玩家离开后 HOME 是否正确释放。

2. **房屋等级显隐与槽位完整性**
   - 1 级时仅显示 `1级房屋`。
   - 升到 2 级后 `2级房屋` 是否正确恢复显示。
   - 升到 3 级后 `3级房屋` 是否正确恢复显示。
   - 隐藏状态下 `11~30` 槽位是否仍被正确收集。
   - 2/3 级区域中的 `Platform / Collector` 是否可正常工作。

3. **解锁提示是否恢复正常**
   - 二三层平台上站立时 `UnlockPrompt` 是否正确出现。
   - 即使平台有旋转，提示是否仍能稳定触发。
   - “升级家园解锁 / 先解锁上一个 / 解锁(价格)” 文案切换是否正确。

4. **升级交互是否正常**
   - `HomeUpgradePrompt` 是否出现。
   - 是否只能由地块主人触发。
   - 金币不足提示是否正常。
   - 满级后 Prompt 是否禁用/隐藏符合预期。

5. **放置 / 收币逻辑是否彻底分离**
   - 踩 `Platform` 时是否只放置怪。
   - 触碰 `Collector` 时是否只领取收益。
   - 两者是否都存在 debounce 防止重复触发。

6. **收益显示 UI 是否稳定**
   - `Collector` 下是否成功挂载 BillboardGui。
   - 未放置时是否显示默认“未放置”文案。
   - 已放置后 `每秒收益 / 未领取收益 / 价值` 是否持续刷新。
   - 是否还存在闪烁、丢失、重建抖动问题。

### 第二优先级：若实机异常则继续排查场景资源

重点检查：

- `Workspace` 下是否存在名为 `收益显示` 的模板对象
- 模板内部是否确实存在 `BillboardGui + TextLabel`
- 是否存在多个 `TextLabel` 导致取错
- `Collector` 是否都实际存在于每个槽位
- `升级区域` 的交互 Part 是否就是代码命中的那个 BasePart
- 各 HOME 的 `1级房屋 / 2级房屋 / 3级房屋` 命名是否完全一致
- 二三层中 `怪放置区域11~30` 是否都位于对应房屋结构内

### 第三优先级：补一轮交付性整理

如验证通过，可继续补以下内容：

- 将本交接文档引用到 `README.md`
- 追加一份“实机验证记录”
- 整理本轮改动摘要，便于以后继续追踪

---

## 5. 操作规范

### 必须遵守的规则

**代码改本地，场景动 MCP。**

具体含义：

1. **本地代码修改**
   - 所有 `.luau` / `.lua` 源码修改，都在本地工作区文件内完成。
   - 本轮已经这样执行。

2. **Studio 场景修改**
   - 任何 Roblox Studio 内的场景对象、属性、模型结构、Prompt/Gui 实例检查与调整，优先通过 **Roblox Studio MCP 工具**完成。
   - 不要把“场景资源问题”误当成“本地脚本问题”盲改代码。

3. **先读现状再动手**
   - 下一轮若继续开发，优先先确认：
     - 当前激活的是正确的 Studio 实例；
     - 场景对象命名是否与代码假设一致；
     - 再进入 Play 做回归。

4. **若继续接手本模块，优先关注这两个文件**
   - `src/server/ServerScriptService/Modules/HomeService.luau`
   - `src/server/ServerScriptService/Modules/PlacementService.luau`

5. **当前阶段判断**
   - 目前不建议继续盲目扩写逻辑；
   - 更适合先做 Studio 实机验证；
   - 再根据真实现象决定是修本地脚本，还是改场景资源。

---

## 交接结论

本轮核心模块已继续推进到新的稳定阶段，当前最重要的不是再做大规模重构，而是：

1. 进入 Roblox Studio 做完整 Play 回归；
2. 重点验证 **隐藏房屋缓存下的槽位收集、二三层解锁提示、收益 BillboardGui 刷新**；
3. 如仍有异常，再基于实机现象做小范围修补。

如果新会话继续接手，请直接从：

**“确认 Studio 实例 → 启动 Play → 验证 HOME / 2-3级房屋 / 11~30 槽位 / UnlockPrompt / Collector / 收益 BillboardGui”**

这一套流程开始。