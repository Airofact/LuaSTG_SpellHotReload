# SpellHotReload

LuaSTG Editor Sharp 的 **Spell Practice（符卡练习）热重载** 调试插件。
支持直接在符卡节点下编写逻辑，也支持回调调用同文件的具名局部函数；
当前真实验收通过的范围是普通符卡练习；SC Debugger 有定位支持，完整切关路径仍待验收。

编辑器重新生成 `*_Boss.lua` 后，插件等待两次读取字节一致，再显示候选。
点击 **Apply & Restart Current**，插件按 Boss 类名、加载时的实时槽位和捕获到的
符卡名定位当前卡，按实际已发布版本选择回调与依赖函数的变化，保留原共享局部状态，
发布后重开符卡练习。
新练习创建新的 Boss 和任务；旧 Boss、旧 coroutine 不做原位迁移。
从 SC Debugger 进入时 Apply 会请求普通符卡练习重启；请求返回不等于异步切关已完成。

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
   使用当前编辑器版本对应的导出命令；本机 0.7.9.1 CLI 只生成 ZIP。
4. 确保生成的物理 `game/mod/<mod>/*_Boss.lua` 已更新（仅生成 ZIP 不会更新此目录）。
5. 等待 Monitor 中候选显示 stable：
   - 候选行的 **Apply**：一次发布该文件可安全对应、依赖与绑定校验通过的回调和局部函数，不重开练习。
   - 窗口级 **Apply & Restart Current**：只发布当前卡及其依赖 helper，然后重开当前练习。
   - **Dismiss**：隐藏这份候选字节，不撤销已经发布的定义，也不修改磁盘文件。

文件级 Apply 不需要当前卡或先 Inspect/选择内部条目。它逐卡复用严格对应证明，
再按定义点可见性、真实捕获和原状态单元检查依赖；所有安全根合为一次发布事务。
可证明的头/尾偏移、单槽改名或其它类缺失，不再仅因整文件布局不同而阻断独立卡。
无法对应、歧义、新增或缺失的卡保留 pending，Result 显示原因；不猜测身份、
不重放初始化/注册、不增删活体列表，也不把旧消费者的 helper 传播算成其回调已发布。
回调定义在下次调用时生效，已经运行中的 task/coroutine 不迁移；若需立即看当前卡，
使用窗口级 Apply & Restart Current。Replay 和待 Retry Restart 时不能文件级 Apply。
资源、外部模块、普通状态初始化及名称/构造元数据不热更；不会因文件级 Apply
而整份接受未支持的改动；这些改动仍保留候选。暂不提供自动 Apply。

文件级 Apply 只放宽可隔离的卡表布局：顶层 local 声明集合、顺序和种类仍固定；
未知顶层调用、全局/字段写入或类实现的变更无法界定影响时整文件拒绝，显示字节位置。
仅字面量标量（含第六参数 `{n,n,n}` 掉落元组）的生成卡构造、精确列表接线及
字面量 `_sc_table` 插入可以保留为结构 pending，不执行参数或注册。
新定义若引用布局尚未发布的类（包括列表别名）、不存在的类、动态类索引，
或依赖已改但未重放的 `_tmp_sc` / `_sc_table` 接线，则阻断该根及依赖它的根。
未重执行的顶层别名/调用若读取这些待应用绑定而无法缩窄影响，也整文件拒绝。
这不是通用 Host/Value 热更；任意中间插入/重排、新类创建或非字面量构造仍不保证可隔离。
文件级门禁与完整剩余核对由 `SpellHotReload/Apply/FileApply.lua` 负责；Card 仅提供
卡接线/绑定影响的证据和已证明的定义语句覆盖，不比较无关语句、不决定整文件完成。
Host/Value 尚未接入生产 Apply，文件级发布仍限定在 Card 事务内。
独立的全局 `Include 'path'` / `Include('path')`（含长字符串、尾随分号）不参与
符卡热重载：增删或改路径不阻断 Apply，也不单独保留候选；不会执行 Include，
不会加载所指文件，也不记为已发布。动态参数、别名、同名 local 遮蔽或控制块内调用
不在此排除范围；原有身份、词法绑定、依赖及活体目标校验不变。
两种 Apply 成功后都按实际发布版本核对整份候选：参与热重载的改动全部已经发布，
或仅有注释/空白等无语义变化时，移除该份候选；仍有未发布或无法确认的内容则保留，
Result 和候选行显示上次核对的剩余种类、字节位置与原因，不需要先 Inspect。
名字、构造、列表、注册和状态初始化不会因定义发布而被一并接受。
完成记忆与首载字节、部分发布、Dismiss 分开；有效的完成字节不会被 Rescan、
周期扫描或同字节再导出复活。新字节、实际版本或活体绑定变化会作废记忆。
提交后检查失败时保留候选，已提交的定义不会假装回滚。此检查会额外分析完整
文件，但不再次提交；Watcher 的完成复查只读活体身份/函数值/共享单元，不编译。
定义完成与重启结果独立：候选已经移除但重启失败时，仍使用 Retry Restart，
它只重试冻结的重启目标，不重新读取、编译或提交。

SC Debug / Test 产物可参与卡定位，候选末尾的字面量 Include 按上述规则排除，
调试启动与注册不会再次执行。Current 通过 `_sc_table["EXT_POS"]` 请求普通练习。
该切关路径曾有黑屏报告；后续用户实测多轮切关正常，文件 Apply 成功但有卡顿。
这些反馈不代替当前版本的完整首载、状态保持、故障与 Retry 集成验收。

插件需在 mod 加载之前安装捕获 hook。watcher 在 `afterTHlib` 建立：此时
`setting.mod` 和 `mod/<mod>/` 搜索路径已经确定，baseline 记录的就是 mod
即将执行的字节，监视覆盖整个游戏会话（`afterMod` 只作为兜底，重复触发是
幂等的）。更新插件代码后，应重启游戏一次。

候选被 **Dismiss** 后，插件记住被拒绝的那一份字节：周期性 drift 扫描和 Rescan
都不会用相同字节重新弹出候选。再次导出不同内容时仍会正常出现新候选，Apply
发布的字节也会作废旧记忆。若编辑器只是重复保存了同一份内容，可先 Dismiss，
不必反复点。

## 支持范围

- 目录模式 `game/mod/<setting.mod>/`，普通符卡练习已有限定真实验收；
  SC Debugger 定位支持不等于完整切关已验收，拒绝 replay。
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
- 按所选卡回调的真实捕获关系递归选择必要的顶层 `local function` 变化；
  未变化定义沿用其已发布依赖，别名和普通状态单元终止依赖遍历。
  多个难度共用 helper 时，共享单元更新可能影响其它消费者，但不算它们的
  回调定义已经发布；未选择的定义变化仍保留 pending。
- 生产发布要求 `debug.upvaluejoin`，保留原共享 upvalue 单元。
  缺少该能力时可正常加载文件，但禁用新版热重载；Lua 5.1 离线测试中的
  值注入兼容路径或能力替身不证明生产共享单元发布可用。

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
  避免序号错位。Current 在形状变化时只重定位当前卡，并核对其它槽的对应证据：
  具名卡按唯一名字跟随，未命名的非符卡阶段按头部或尾部索引对齐。捕获名在候选
  中消失或出现多次、未命名槽位两侧都对齐或都不对齐、以及移动/对话槽位本身，
  都拒绝应用并提示重启游戏。回调体内的弹幕逻辑和调用参数可更新；
  卡构造参数（包括血量、时限）及名称元数据不随回调发布。
- Current 只定位当前卡；文件 Apply 对各已捕获卡分别证明对应，但不会修复
  其它槽位的新增、删除或改名。无法证明的部分保留，安全集合一次提交。
- 生成源码中途重建列表时，重建之前登记进 `_sc_table`、重建后不再位于该序号上的
  卡会先按名字尝试重新定位；名字不唯一或已消失时按身份校验失败被安全拒绝，
  需要重启游戏。
- 文件顶层初始化代码不重新执行。已有局部变量使用运行时的值；
  新引用了未捕获的局部变量时拒绝应用，需重启游戏。修改局部变量的初始化
  表达式也需要重启。
- Current 只发布当前卡变化及其必要函数依赖；文件 Apply 合并安全根的变化。
  规划可能编译更多定义用于分析，分析结果不等于发布；不重载 `require` 模块或资源。
- 不执行整个候选文件，不重建 `_editor_class`、`_sc_table` 或 `all_class`。
  重启练习仍使用 `_sc_table["EXT_POS"]` 传递当前卡。
- 编译、结构检查、局部变量解析失败时不发布改动。发布成功但练习重启失败时，
  **Retry Restart** 仅重试切关。

## 架构

生产入口和发布流程如下；首载发生在普通 mod 加载时，Apply 不重跑顶层：

1. **首载捕获**：`__init__.lua` 在 `afterTHlib` 安装 `LoadHook`，经
   `AnchorLoad` 从一次正常文件执行取得首载源码、局部变量共享单元的锚点及
   可重载判定。`Plugin:AdoptLoad` 留存首载记录并捕获函数/符卡版本。
   同文件再次执行时保留首载记录并禁用热重载，不从新活体状态补建首载历史。
2. **稳定候选**：`Watcher` / `SnapshotStore` 双读字节一致后标为 stable；
   `Plugin` 路由候选、复读磁盘并取得新鲜活体绑定。首载拒绝不能回退旧路径。
3. **发现与准备**：`Driver:Discover` 经 `FileMatch` 与 Card 的 `Match` 发现
   单元；`Card.PrepareVersioned` / `PrepareFileVersioned` 经
   `Driver:PrepareDiscovery` 调用 `Locate` / `Inject`，证明卡对应关系并按
   实际已发布版本选择回调和必要 helper。`CardVersions` / `FunctionVersions`
   负责版本与依赖；`FileApply` 负责文件门禁。候选顶层与回调体不执行。
4. **原子发布**：`Driver:CommitDiscovery` 将单个准备好的 Card 聚合计划
   交给调用方绑定的一次性事务入口，经 Card 的 `Commit` 调用 `CardCommit`。
   事务复读并执行 `CommitCheck`，消耗 `CommitPhase` 令牌后完成闭包接线、
   共享单元写入和回调发布，最后安装版本快照；可恢复失败按日志逆序回滚，
   恢复失败则禁用该会话的后续发布。这不是跨适配器事务。
5. **完成核对与重启**：`Plugin` 以真实提交 receipt 经 `FileApply` 核对整文件
   剩余，决定保留或移除候选。文件 Apply 到此结束；Current 使用 Card 冻结的
   目标请求 `PracticeBinding.Restart`。失败后 Retry 仅消费冻结目标，重查身份
   并重试切关，不重读候选、编译或提交；重启与定义完成分别记账。

公共发现契约位于 `Pipeline/Adapter.lua` / `Pipeline/Driver.lua`：
`Match` 发现单元，`Locate` 匹配身份，`Inject` 准备新值，`Commit` 发布，
可选的 `Restart` 请求重启。具体适配器独立放在 `Adapters/`；生产 Card 的
`Commit` 只能使用上述原子事务入口，不自行调用旧 `CardCallbacks.Publish`。
Host/Value 仍是保留的适配器实现，未接入生产 Apply。

提交作用域由 Monitor 的 layout 按钮调用 `ApplyFromUI`、`ApplyFileFromUI`
或 `RetryRestartFromUI` 打开。`View:update` → `Plugin:Tick` 只驱动激活和监视，
不打开提交作用域。令牌负责主线程、生命周期与重入门禁；实际调用时机仍由
可信 UI 入口保证，令牌本身不证明引擎相位。

`GeneratedBossLoader`、`Legacy/Functions` 和无首载 entry 的旧 Apply 分支
保留给兼容调用与历史回归。旧 `Card.Plan` → `Driver:Commit` / `Driver:Restart`
以及提交后更新 `UpvalueRegistry` 的说明仅适用于这条旧路径。
生产入口使用首载锚点和实际发布版本，不靠旧 map 或整文件源码推进版本。

## 窗口

- **Monitor**：监视状态、当前卡（`Source: Spell Practice` / `Source: SC Debug`）、
  稳定候选，以及 Apply、Retry Restart、Dismiss、Rescan、Start/Stop Watching。
- **Change Log**：最多 500 条事件，记录候选、应用和重启结果。

## 模块

| 文件 | 职责 |
| --- | --- |
| `__init__.lua` | afterTHlib 安装捕获 hook 并初始化 watcher（baseline + start）|
| `Runtime/Plugin.lua` | 生命周期、候选路由、绑定复查、提交与重启事务 |
| `Runtime/Watcher.lua` / `Runtime/SnapshotStore.lua` | 去抖、双读验证、显式 stable 状态、字节快照 |
| `Load/AnchorLoad.lua` / `Load/LoadHook.lua` | 一次正常加载的锚点捕获与 hook |
| `Load/UpvalueRegistry.lua` | 首载值与源码的兼容视图，不是生产版本账本 |
| `GeneratedBossLoader.lua` / `Legacy/Functions.lua` | 旧加载/值注入兼容入口与函数片段实现 |
| `Adapters/Card/GeneratedBossScanner.lua` | 产物格式检查、UI 类名提示 |
| `Adapters/Card/PracticeBinding.lua` | 当前卡解析、练习重启及旧函数补丁工具 |
| `Pipeline/Adapter.lua` / `Pipeline/NodeRegistry.lua` / `Pipeline/Driver.lua` | 公共契约、发现路由与准备/事务调度；保留旧驱动接口 |
| `Adapters/Card/Card.lua` | 符卡适配器：身份/绑定证据、版本准备、事务委托和冻结重启目标 |
| `Adapters/Card/CardTarget.lua` / `Adapters/Card/CardVersions.lua` | 当前/文件根对应证明与实际发布版本选择 |
| `Source/FunctionVersions.lua` | 局部函数版本比较与必要依赖选择 |
| `Apply/FileApply.lua` | 文件门禁、Include 排除与完整剩余核对 |
| `Apply/CardCommit.lua` / `Apply/CommitCheck.lua` / `Apply/CommitPhase.lua` | 原子提交、最终只读校验与提交作用域 |
| `Adapters/Card/CardCallbacks.lua` | 卡结构读取证据；保留旧回调编译/绑定/发布接口 |
| `Source/TopLevelIR.lua` / `Load/LoadCapture.lua` | 顶层分析与捕获工具 |
| `Adapters/Host.lua` / `Adapters/Value.lua` | 保留的宿主/值适配器，均未接入生产 Apply |
| `UI/View.lua` / `UI/Tab/` / `Runtime/ChangeLog.lua` | 调试窗口和日志 |
| `tests/` | 离线 spec 与待适配新版入口的历史引擎 smoke |

表中模块路径均相对于本目录的 `SpellHotReload/`（引导文件除外）。

### 目录布局

- 仓库根 `__init__.lua` 是 LuaSTG 插件入口。
- `SpellHotReload/UI/View.lua` 管理 Tool 窗口与每帧 Tick；
  `SpellHotReload/UI/Tab/` 放 Monitor、Change Log 和页签枚举。
- `SpellHotReload/Source/` 放源码处理模块：`Lexer`、`TopLevelIR`、`Binding`、
  `CodeCache`、`Compose`、`FunctionPlan`，分别负责词法、顶层分析、可见绑定、
  编译缓存、闭包接线和函数准备。
- `SpellHotReload/Load/` 放首载与会话模块：`Anchor`、`AnchorSession`、
  `AnchorRegistry`、`AnchorLoad`、`LoadCapture`、`LoadHook`、`LoadVersions`、
  `UpvalueRegistry`。
- `SpellHotReload/Adapters/` 独立放具体适配器：`Host.lua`、`Value.lua`，以及
  `Card/` 下的 `Card`、`CardCallbacks`、`CardTarget`、`CardVersions`、
  `PracticeBinding`、`GeneratedBossScanner`。公共契约 `Pipeline/Adapter.lua`、调度器
  `Pipeline/Driver.lua` 和注册表 `Pipeline/NodeRegistry.lua` 位于 `Pipeline/`。
  Host/Value 的接线状态保持。
- `SpellHotReload/Apply/` 放 `FileApply`、`CardCommit`、`CommitCheck`、`CommitPhase`，
  分别负责文件门禁与剩余核对、原子提交、最终只读校验和提交作用域。
- `SpellHotReload/Source/FunctionVersions.lua` 负责局部函数的版本比较和依赖选择，
  与同目录的源码分析、函数准备配合；它不直接提交或重启。
- `SpellHotReload/Runtime/` 放 `Plugin`、`Watcher`、`SnapshotStore`、`ChangeLog`，
  负责会话编排、文件监视、候选快照与事件记录。
- `SpellHotReload/Pipeline/` 放 `Adapter`、`NodeRegistry`、`FileMatch`、`UnitIndex`、
  `Driver`，负责公共适配器契约、注册路由、全文件发现、单元索引与规划/提交调度。
  具体适配器仍独立放在 `Adapters/`，文件门禁与原子提交仍放在 `Apply/`。
- `SpellHotReload/tests/` 包含离线 spec 与引擎 smoke。

UI 的 require 路径为 `SpellHotReload.UI.View` 与
`SpellHotReload.UI.Tab.<模块名>`；旧 `SpellHotReload.View` /
`SpellHotReload.Tab.*` 不再提供入口。更新后需要重启游戏，让新路径重新加载。

Source 和 Load 模块使用 `SpellHotReload.Source.<模块名>` 与
`SpellHotReload.Load.<模块名>` 加载；原来的平铺 require 路径不再提供入口。
目录按职责分组，既有跨目录依赖保留；例如 `Source.Compose` 使用 `Load.Anchor`。
数据中的 `Kind` / `kind` 标识、版本号及调用接口保持原值，不随模块路径改名。

具体适配器以 `SpellHotReload.Adapters.Host`、`SpellHotReload.Adapters.Value` 和
`SpellHotReload.Adapters.Card.<模块名>` 加载；发布流程以
`SpellHotReload.Apply.<模块名>` 加载，函数版本服务以
`SpellHotReload.Source.FunctionVersions` 加载。对应旧平铺路径不再提供入口。
本次只调整模块路径；数据中的 Kind/kind、适配器 Id、版本及接口保持原值。
更新后需要重启游戏。现有跨目录引用保留，目录不代表严格的依赖分层。

运行编排和公共调度分别以 `SpellHotReload.Runtime.<模块名>` 与
`SpellHotReload.Pipeline.<模块名>` 加载；对应旧平铺 require 路径不再提供入口。
仓库根 `__init__.lua`、调试注册 ID、事件名称、Watcher 日志前缀和数据协议保持。
`GeneratedBossLoader.lua` 与 `Legacy/Functions.lua` 保留原路径；此分组不退役兼容入口。
更新后需要重启游戏，让新路径和会话 hook 重新加载。

## 验证

在 `THDiMS/game/` 运行：

```powershell
lua plugin/SpellHotReload/SpellHotReload/tests/Run.lua
luajit plugin/SpellHotReload/SpellHotReload/tests/Run.lua
```

`Run.lua` 仅调用 Sandbox、Inline、TopLevelIR、LoadCapture、Driver、Card、Host、
Watcher 八个 spec，包含兼容与旧管线回归；不是所有测试的总入口，也不证明
新版生产 Apply 或真实 SC Debug 切关已经验收。

新版定向测试均位于 `SpellHotReload/tests/`，按职责查找：

| 范围 | spec 文件 |
| --- | --- |
| 首载与释放 | `AnchorLoadSpec.lua`、`LoadHookSpec.lua`、`CardSeedVersionsSpec.lua`、`SessionReleaseSpec.lua` |
| 发现与准备调度 | `AdapterDiscoverySpec.lua`、`DriverDiscoverySpec.lua`、`DriverPrepareSpec.lua`、`DriverCommitSpec.lua` |
| 身份、版本与依赖 | `CardRemappingSpec.lua`、`FileCardTargetSpec.lua`、`CardVersionsSpec.lua`、`FunctionVersionsSpec.lua` |
| 提交与 UI 门禁 | `CommitCheckSpec.lua`、`CommitPhaseSpec.lua`、`CardCommitSpec.lua`、`CardCommitPolicySpec.lua`、`UICommitScopeSpec.lua` |
| Apply 与候选剩余 | `VersionedApplySpec.lua`、`FileApplySpec.lua`、`FileApplyPolicySpec.lua`、`CandidateCompletionSpec.lua`、`MonitorVersionsSpec.lua` |

例如在同一 `game/` 工作目录下，分别用独立进程运行以下集成 fixture：

```powershell
foreach ($runtime in 'lua', 'luajit') {
    foreach ($spec in 'VersionedApplySpec', 'FileApplySpec', 'CandidateCompletionSpec', 'UICommitScopeSpec') {
        & $runtime -e "package.path='plugin/SpellHotReload/?.lua;'..package.path;local r=require('SpellHotReload.tests.$spec').run();assert(r.failed==0)"
        if ($LASTEXITCODE -ne 0) { throw "$runtime / $spec failed" }
    }
}
```

这些 spec 使用合成首载和模拟宿主，不启动游戏。LuaJIT 才执行真实共享单元提交；
Lua 5.1 的缺能力拒绝或能力替身验证只证明各用例注明的范围。
目录迁移后的离线回归通过，不代替当前版本的真实按钮、异步切关、完整首载
初始化计数、标量状态保持及准备/提交故障与 Retry 验收。

历史引擎 smoke 保留原路径，尚未适配新版生产入口：

- `EngineSmoke.lua` 依赖 DiMS 的 `DIMS_4B_Boss:Normal`，创建
  `userdata/spell_hot_reload_smoke/InlineSmoke_Boss.lua` 并写 `result.txt`。
- `EngineSmokeScDebug.lua` 需要真实生成产物启动 SC Debugger（末端包含
  `Include 'THlib\UI\scdebugger.lua'`），以首载字节构造候选，只写同目录 `result.txt`。
- 上述两者新建 Plugin 后只复制旧 registry，并在 view:update 中直接调用无令牌的
  `Apply()`；未采用生产 `AdoptLoad` 会话与可信 layout 提交入口。不能将它们的
  历史 PASS 或 require 路径同步视为新版生产验证，运行前需适配并核对输入。
- `EngineSmokeHost.lua` 使用独立旧 Driver 的 `Plan` / `Commit` 测试宿主注册，
  不证明 Host 已接入生产 Apply；它也在上述目录生成输入并覆盖 `result.txt`。

这些脚本会改变运行中的测试场景并自动退出；各结果文件互相覆盖。
生产实机验证须另核对启动输入、输出及现有日志/存档保护，不能直接沿用旧脚本。
