# SpellHotReload

LuaSTG Editor Sharp 的 **Spell Practice（符卡练习）热重载** 调试插件。
支持直接在符卡节点下编写逻辑，也支持回调调用同文件的具名局部函数；
普通符卡练习和 **SC Debugger** 进入的游戏都可以热重载。

编辑器重新生成 `*_Boss.lua` 后，插件等待两次读取字节一致，再显示候选。
点击 **Apply & Restart Current**，插件按 Boss 类名、加载时的实时槽位和捕获到的
符卡名定位当前卡，编译它的回调，保留运行时已捕获的局部变量，发布后重开符卡练习。
新练习创建新的 Boss 和任务；旧 Boss、旧 coroutine 不做原位迁移。
从 SC Debugger 进入时 Apply 会离开 `SC Debugger`，以普通符卡练习重启当前卡。

实现位于 `game/plugin/SpellHotReload/`。无需改动编辑器、项目源文件或生成文件。

## 安装与更新

在游戏项目根目录（包含 `game/` 的目录）执行：

```powershell
git submodule add https://github.com/Airofact/LuaSTG_SpellHotReload.git game/plugin/SpellHotReload
```

克隆已经引用本插件的项目后，用 `git submodule update --init --recursive`
取回项目记录的版本。更新插件时执行：

```powershell
git -C game/plugin/SpellHotReload pull --ff-only origin main
git add game/plugin/SpellHotReload
```

主项目提交新的 gitlink 后，其他使用者再执行 `git submodule update --init`
即可取得相同版本。也可直接下载本仓库，把含 `__init__.lua` 的根目录放到
`game/plugin/SpellHotReload/`。

运行需要提供 `lib.Ldebug`、插件事件、ImGui、`lstg.FileSystemWatcher` 以及
THlib 符卡练习接口的 LuaSTG 环境；已验证环境为 THDiMS 的 LuaSTG Sub
v0.21.111 / LuaJIT 2.1.1744887079。Lua 5.1 可运行独立 spec，不能据此
推断其它引擎包的运行兼容性。启用插件后重启游戏，使加载捕获先于 mod 执行。

## 使用

1. 将本目录放在 `game/plugin/` 下并启用插件，重新启动游戏。
2. 进入符卡练习或 SC Debugger，打开 `Tool → Spell Hot Reload`。
3. 在 Editor Sharp 修改符卡节点逻辑，使用 **只打包、不运行** 的入口：
   GUI `ExportZip(run=false)` 或 `Cli2 pack`。
4. 等待 Monitor 中候选显示 stable，点击 **Apply & Restart Current**。

SC Debug / Test 产物（包含 `scdebugger`）可以直接使用。插件不加载候选文件，
只重编译当前卡的回调，所以文件末尾 `Include 'THlib\UI\scdebugger.lua'` 之类的
调试启动和场景注册代码不会再次执行；Apply 通过 `_sc_table["EXT_POS"]` 交接到
普通符卡练习，不会重新进入 SC Debugger。

插件需在 mod 加载之前安装捕获 hook。watcher 在 `afterTHlib` 建立：此时
`setting.mod` 和 `mod/<mod>/` 搜索路径已经确定，baseline 记录的就是 mod
即将执行的字节，监视覆盖整个游戏会话（`afterMod` 只作为兜底，重复触发是
幂等的）。更新插件代码后，应重启游戏一次。

候选被 **Dismiss** 后，插件记住被拒绝的那一份字节：周期性 drift 扫描和 Rescan
都不会用相同字节重新弹出候选。再次导出不同内容时仍会正常出现新候选，Apply
发布的字节也会作废旧记忆。若编辑器只是重复保存了同一份内容，可先 Dismiss，
不必反复点。

## 支持范围

- 目录模式 `game/mod/<setting.mod>/`，普通符卡练习与 SC Debugger 均可，拒绝 replay。
- Editor Sharp 生成的 `_tmp_sc = boss.card.New(...)` 和
  `table.insert(_editor_class[...].cards, _tmp_sc)` 结构。
- 生成源码重建整张表时按引擎实际建出的列表定位：
  `_editor_class[...].cards={boss.move.New(...),_tmp_sc}` 会重置列表，其中的
  `_tmp_sc` 复用上一个构造的 descriptor，`boss.move.New` 等内联元素只占位、
  不可选中。形状一致时，候选与已加载源码的列表长度、元素种类、构造参数和
  perform 标记逐槽必须一致。
- 重新定位当前卡时按「实时槽位 + 捕获名 + 正/逆索引」判定：候选在同一槽位仍是
  同名卡就用该槽位；否则当捕获名在候选中唯一出现时跟随到新槽位（用于 SC Debug
  包 → 普通全量包的槽位偏移）；两侧形状一致且只有当前槽改名时判定为原地改名，
  仍在原槽位。非符卡阶段没有名字可用，改为对齐索引：候选与实时列表只在头部
  （尾部追加了槽位）或只在尾部（SC Debug 导出省略了前缀，只在头部留一个
  `boss.move.New` 占位）逐槽一致时按该侧索引跟随；两侧都一致或都不一致即拒绝。
  判定不出来时拒绝应用并报告原因。
- 回调 `before / init / frame / render / beforedel / del / after`：
  支持 `function _tmp_sc:init() ... end` 和
  `_tmp_sc.frame = function(self) ... end` 两种声明。
- 回调内的任务、循环、匿名函数和调用参数均随回调一起更新。
- 删除一个可选回调时恢复 `boss.card._default_card` 中的默认实现。
- 回调直接引用的、加载时已捕获的顶层 `local function` 也会重新编译。
  原有共享函数引用继续生效：多个难度共用同一函数时，函数体更新仍可能同时
  影响这些难度；回调本身的替换只作用于当前卡。
- LuaJIT 下保留原有 upvalue 单元，包括回调之间共享的局部状态。
  Lua 5.1 的独立测试使用值注入回退。

例如以下两种 init 都支持：

```lua
function _tmp_sc:init()
    task.New(self, function()
        task.Wait(30)
        -- 直接由符卡节点生成的弹幕逻辑
    end)
end

-- 同文件已定义 local function pattern(self, difficulty)
function _tmp_sc:init()
    pattern(self, 2) -- 函数体和这里的调用参数都可更新
end
```

## 边界

- 卡片定位以加载时的生成源码为基准，计数包含对话、移动和非符卡阶段，
  并以 live 索引（`_sc_table` 记录的那个序号）为准，不是文本里的注册次数。
- 形状一致时严格要求列表长度、元素种类、构造参数和 perform 标记逐槽相同，
  避免序号错位。形状变化时只重定位当前卡，且要求除当前槽外逐槽构造参数一致：
  具名卡按唯一名字跟随，未命名的非符卡阶段按头部或尾部索引对齐。捕获名在候选
  中消失或出现多次、未命名槽位两侧都对齐或都不对齐、以及移动/对话槽位本身，
  都拒绝应用并提示重启游戏。血量、时限、弹幕参数等改动随回调重编译生效，
  但不要借此增删其它卡片或重排整张表。
- 名字重定位只针对当前卡。其它槽位的新增、删除或改名不会被连带修复；
  插件要么按上面的规则安全重编译当前卡，要么拒绝并提示重启。
- 生成源码中途重建列表时，重建之前登记进 `_sc_table`、重建后不再位于该序号上的
  卡会先按名字尝试重新定位；名字不唯一或已消失时按身份校验失败被安全拒绝，
  需要重启游戏。
- 文件顶层初始化代码不重新执行。已有局部变量使用运行时的值；
  新引用了未捕获的局部变量时拒绝应用，需重启游戏。修改局部变量的初始化
  表达式也需要重启。
- 只重编译当前卡回调及其直接引用的具名函数；不会递归更新全部函数依赖，
  也不会重载 `require` 模块或资源。
- 不执行整个候选文件，不重建 `_editor_class`、`_sc_table` 或 `all_class`。
  重启练习仍使用 `_sc_table["EXT_POS"]` 传递当前卡。
- 编译、结构检查、局部变量解析失败时不发布改动。发布成功但练习重启失败时，
  **Retry Restart** 仅重试切关。

## 架构

一次 Apply 分五段，前四段都不碰活体：

1. **加载捕获**（`__init__.lua` → `GeneratedBossLoader`）：`afterTHlib` 时拦截
   `lstg.DoFile`，把 `*_Boss.lua` 的顶层具名函数与原始源码写进 `UpvalueRegistry`。
   baseline 记录的就是 mod 即将执行的字节，热重载不重跑文件顶层。
2. **候选**（`Watcher` / `SnapshotStore`）：两次读取字节一致才升级为 stable 候选；
   Dismiss 记住被拒绝的那一份字节，drift 扫描与 Rescan 都不会复活它。
3. **路由与复查**（`Plugin`）：挑出定义当前 class 的候选文件，重读磁盘字节与候选
   快照比对，再重新捕获一次活体绑定，确认 class / card / slot 都没变。
4. **规划**（`Card.Plan` → `Driver`）：`Card.Request` 把捕获到的绑定归一化成请求，
   适配器按四钩子契约先做结构身份匹配（`Locate`，即 `CardCallbacks.Select`），
   再在新闭包上重编译回调与具名局部函数（`Inject`，即 `CardCallbacks.Build`）。
   生成接线从不执行，回调体也不运行。
5. **提交与重启**（`Driver:Commit`）：唯一的活体变更点是 `CardCallbacks.Publish`；
   提交成功后按 `Card.Restartable` 重启符卡练习（`PracticeBinding.Restart`）。
   重启失败时定义已经就位，run 被保留，**Retry Restart** 走 `Driver:Restart(run)`
   只重试切关，不重新编译。

适配器契约（`Adapter.lua` / `Driver.lua` 文件头有完整版）：

```
Locate(node, env)          -> handle|nil, reason   结构身份匹配，不碰活体
Inject(handle, node, env)  -> plan|nil, reason     只造新值（新闭包/新表达式）
Commit(handle, plan, env)  -> ok, reason           唯一活体变更点，帧边界
Restart(handle, plan, env) -> ok, reason           可选、可失败、可单独重试
```

四钩子之外还有四件事由 `Plugin` 承担，不能跟着适配器一起搬走：

- **候选文件路由**：一个 driver run 只规划一个文件，没有「哪份候选管这张卡」的
  概念，所以「挑出定义当前 class 的候选」留在 Plugin。
- **活体绑定复查**：Driver 的变更检测比对语句文本，撞不上「活体绑定变了」；
  解析与提交之间这张卡被换掉，必须在这里拦下。
- **提交后 `registry:SetAll`**：把新编译的具名函数写回 `UpvalueRegistry`，供下一次
  热重载解析同文件其它闭包。漏掉不会立刻报错，下一次重载才会绑到旧闭包。
- **重启重试状态**：已提交的 run 由 Plugin 持有，失败的重启交给 `Driver:Restart`。

提交只允许从帧边界的 UI 阶段进入，由 `View:update` → `Plugin:Tick` 天然满足。
同一个驱动已经为 `stage.group.DefStageFunc` 准备了宿主适配器（`Host.lua`），
但它尚未接入 Apply 事务。

## 窗口

- **Monitor**：监视状态、当前卡（`Source: Spell Practice` / `Source: SC Debug`）、
  稳定候选，以及 Apply、Retry Restart、Dismiss、Rescan、Start/Stop Watching。
- **Change Log**：最多 500 条事件，记录候选、应用和重启结果。

## 模块

| 文件 | 职责 |
| --- | --- |
| `__init__.lua` | afterTHlib 安装捕获 hook 并初始化 watcher（baseline + start）|
| `Plugin.lua` | 生命周期、候选路由、绑定复查、提交与重启事务 |
| `Watcher.lua` / `SnapshotStore.lua` | 去抖、双读验证、显式 stable 状态、字节快照 |
| `UpvalueRegistry.lua` | 加载时捕获的顶层函数和真实加载源码 |
| `GeneratedBossLoader.lua` | 加载捕获、词法器、具名函数片段编译 |
| `GeneratedBossScanner.lua` | 产物格式检查、UI 类名提示 |
| `PracticeBinding.lua` | 当前卡解析、练习重启及旧函数补丁工具 |
| `Adapter.lua` / `NodeRegistry.lua` / `Driver.lua` | 四钩子契约、载体路由、规划与提交/重启驱动 |
| `Card.lua` | 符卡适配器：把 `Select` / `Build` / `Publish` / `Restart` 映射到四钩子 |
| `CardCallbacks.lua` | 卡片定位、结构核对、回调编译、局部变量绑定与发布 |
| `Host.lua` / `TopLevelIR.lua` / `LoadCapture.lua` / `Value.lua` | 宿主适配器与通用解析/捕获/值层（`Host` 尚未接入运行时）|
| `View.lua` / `Tab/` / `ChangeLog.lua` | 调试窗口和日志 |
| `tests/` | Lua 5.1 / LuaJIT 的 spec 与真实引擎 smoke |

表中模块路径均相对于本目录的 `SpellHotReload/`（引导文件除外）。

## 验证

在 `THDiMS/game/` 运行：

```powershell
lua plugin/SpellHotReload/SpellHotReload/tests/Run.lua
luajit plugin/SpellHotReload/SpellHotReload/tests/Run.lua
```

涵盖嵌套任务、所有回调、nil/false 局部变量、共享 upvalue、连续更新、
原有具名函数方式、结构变化拒绝、稳定候选、过期字节、replay 和重启重试，
以及重建类表（live 索引）、按名字跟随 SC Debug 包 → 全量包的槽位偏移、原地
改名（重启后交出新名字）、未命名槽位按正/逆索引跟随（含两侧都对齐时的歧义
拒绝），和 SC Debugger 到普通符卡练习的交接。

同一个入口还会跑通用层 spec：Sandbox 83、TopLevelIR 58、LoadCapture 46、
Driver 75、Card 63、Host 93、Watcher 14 全部 0 failed（InlineSpec 在 LuaJIT 下
88、Lua 5.1 下 86）。Plugin 的 Apply 走 `Card.Plan` + `Driver:Commit`，返回串
与调用约定由 InlineSpec 覆盖，真实引擎行为由下面的 smoke 覆盖。

真实引擎 smoke（会自动进入练习并退出，启动前关闭已有游戏实例）：

```powershell
.\LuaSTGSub.exe "start_game=true; setting.mod='DiMS'; setting.windowed=true; dofile('plugin/SpellHotReload/SpellHotReload/tests/EngineSmoke.lua')"
```

该测试依赖 DiMS 的 `DIMS_4B_Boss:Normal`，只在
`userdata/spell_hot_reload_smoke/` 写入测试生成文件和 `result.txt`。
成功标记为 `PASS`；实际覆盖生产加载 hook、文件监视、两次应用、新 Boss /
任务、局部状态保留，以及 class/符卡注册数量不变。
符卡 Apply 迁入 Driver 后于 2026-09-30 复跑通过，同时验证 Dismiss 在
周期扫描与 Rescan 后仍保持有效。

SC Debug 入口的 smoke 需要生成产物末端带 `Include 'THlib\UI\scdebugger.lua'`
（用 SC Debug 入口重新打包；当前 `game/mod/DiMS/` 产物不含该 Include，
直接跑会捕不到卡）：

```powershell
.\LuaSTGSub.exe "start_game=true; setting.mod='DiMS'; setting.windowed=true; dofile('plugin/SpellHotReload/SpellHotReload/tests/EngineSmokeScDebug.lua')"
```

它不修改 mod 文件，只把加载 hook 捕获到的源码字节当作候选交给完整的 Apply
事务，所以生成接线不会被再次执行。覆盖 debug 侧卡片捕获、`scdebugger` 的 stage
group 只注册一次、Apply 后离开 `SC Debugger` 并以普通符卡练习重启当前卡、
`_sc_table["EXT_POS"]` 与捕获到的 live 序号一致、卡片对象身份保留。
结果写入同一个 `userdata/spell_hot_reload_smoke/result.txt`（互相覆盖）。
