# SpellHotReload

LuaSTG Editor Sharp 的 **Spell Practice（符卡练习）热重载** 调试插件。
支持直接在符卡节点下编写逻辑，也支持回调调用同文件的具名局部函数；
普通符卡练习已有历史限定实机证据；文件级共同发布已有离线回归，
对象类 File Apply 也已完成当前引擎的限定场景验收。
SC Debugger 有定位支持，完整切关路径仍待验收。

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
v0.21.111 / LuaJIT 2.1.1744887079。生产发布和本次共享状态回归均要求真实
`debug.upvaluejoin` 能力。启用插件后重启游戏，使加载捕获先于 mod 执行。

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
全局/字段值及 Host 场景不在生产支持范围；Local、Card 和 Object 的安全定义集合
由一次共同文件事务发布，各自保存私有定义规则和版本。
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
提交后检查失败时保留候选，已提交的定义不会假装回滚。此检查复用当次完整
FileAnalysis，针对实际新快照重新发现、协调和核算，不再次提交；复用语法事实
不省略实际版本、定位、活体或 Guard。Watcher 的完成复查只读活体身份、函数值
和共享单元，不编译。
定义完成与重启结果独立：候选已经移除但重启失败时，仍使用 Retry Restart，
它只重试运行工作流冻结并关联成功 receipt 的目标，不重新读取、编译或提交。
结果 `restart requested` 表示切关请求已发出；尚未证明异步新场景或 Boss 已就绪。
生产路径由 `Runtime/CurrentRestart.lua` 执行，不调用 Card 的 Restart 钩子；
适配器不再提供 Restart/Restartable，Driver 不再自动重启或提供重试；
旧版 discovery 契约不再注册，缺少首次加载记录时直接拒绝 Apply。

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
- 删除一个可选回调时恢复首载保存的默认函数身份，不读取后来改写的默认表。
- 按所选卡回调的真实捕获关系递归选择必要的顶层 `local function` 变化；
  未变化定义沿用其已发布依赖，别名和普通状态单元终止依赖遍历。
  多个难度共用 helper 时，共享单元更新可能影响其它消费者，但不算它们的
  回调定义已经发布；未选择的定义变化仍保留 pending。
- 生产发布要求 `debug.upvaluejoin`，保留原共享 upvalue 单元。
  缺少该能力时可正常加载文件，但禁用热重载；能力替身不证明共享单元发布可用。

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

对象类 File Apply 仅处理已监视 `*_Boss.lua` 中经真实首载捕获的
`_editor_class["name"]=Class(_object/bullet/enemy/laser/laser_bent)`。保持类表和已有对象字段，
成对发布类自身显式定义的 `init/del/frame/render/colli/kill` 与 `[1]..[6]`。
Apply 不执行 Class、注册或 init；后续调用/新建对象使用更新定义，已有 coroutine 保持原闭包。
Current 不自动选择对象方法；对象变化仍计入候选剩余。新增/删除回调、类名/基类变化、
重复/动态键、类表漂移和来源不明的派生继承副本保持 pending 或拒绝。
不扩大监视范围至 Global/Mid 文件。需重启游戏建立构造来源证据；不从后来活体补种。
正式离线回归覆盖三 owner 共同发布及写后失败回滚。当前 LuaSTG Sub v0.21.111 /
LuaJIT 2.1.1744887079 的限定实机验证覆盖真实首载、原生 watcher、活体回调、
后续 New/init、旧/新 task、实际 receipt、漂移拒绝和候选剩余。另以原 THlib
脚本及贴图验证 ball_small、直线 laser、sample4 曲线 laser 的渲染、碰撞接收和
Del 消亡；enemy 仍仅有同一协议的离线覆盖，Kill 掉落、完整自机系统、所有
弹型/材质及性能未纳入这些限定证据。

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
  完整文件只建立公共语法与绑定事实；Local 从已有节点匹配定义并按实际版本选择，
  Source 为需要的定义探测捕获、准备闭包。探测结果不等于发布许可；不重载
  `require` 模块或资源。
- 不执行整个候选文件，不重建 `_editor_class`、`_sc_table` 或 `all_class`。
  重启练习仍使用 `_sc_table["EXT_POS"]` 传递当前卡。
- 编译、结构检查、局部变量解析失败时不发布改动。发布成功但练习重启失败时，
  **Retry Restart** 仅重试切关。

## 架构

生产入口和发布流程如下；首载发生在普通 mod 加载时，Apply 不重跑顶层：

1. **首载捕获**：`__init__.lua` 在 `afterTHlib` 安装 `LoadHook`，经
   `AnchorLoad` 从一次正常文件执行取得完整 FileAnalysis、函数身份和共享单元锚点。
   `Plugin:AdoptLoad` 收齐 Local、Card 和 Object 的独立首载贡献，再由 `FileVersions`
   一次建立共同文件快照。任一贡献失败都保留拒绝原因，不从后来的活体补建历史。
   同文件再次执行时保留原首载记录并禁用热重载。
2. **稳定候选与公共分析**：`Watcher` / `SnapshotStore` 双读字节一致后标为 stable；
   `Plugin` 复读磁盘并取得新鲜活体绑定。`Source/FileAnalysis` 对完整候选做语法
   编译校验、建立全文 AST、词法绑定和节点位置；不执行候选。各 owner 消费同一事实。
3. **发现、依赖与定向准备**：`Driver:DiscoverPublished` 将公共 source 和共同实际
   publication 交给原 owner 的 `Match / Reconcile`，保留候选零命中时的旧侧记录。
   Local 拥有局部定义匹配、支持范围、实际版本和选择；Card 拥有回调、卡表对应及
   业务绑定规则。公共 `Dependencies` 只以 unit 为节点路由有限需求和 root 来源，
   细粒度映射由 owner 私有维护。各 owner 约束后，`Locate / Inject` 为最终安全集合
   定向准备；`FunctionPlan` 保留完整词法上下文下的捕获探测、闭包准备和接线计划，
   不再分析整文件、重建局部定义索引或选择根。`FileApply` 核对完整文件门禁。
4. **共同原子发布**：`Driver:CommitDiscovery` 调用每个原 owner 的 `Commit`，
   仅登记其精确 handle/fragment/context；收齐后才调用一次中立 `FileCommit`。
   owner 的 Commit 不独立发布。公共事务封存动作、检查权限和冲突，执行两轮
   owner Guard 与新鲜复读，消耗 `CommitPhase` 令牌后接线、写共享单元和回调，
   最后安装唯一共同快照并返回 receipt。写后失败按日志逆序恢复；恢复失败污染
   本会话，后续控制器也不能绕过。零动作 owner 保留原私有记录，无变化事务保留
   原快照，不伪造版本推进。不是循环单 owner 事务。
5. **完成核对与重启**：`Plugin` 消费真实共同 receipt，复用当次 source，针对已安装
   快照重新发现、协调并以全 owner 无写见证核对完整剩余，再决定保留或移除候选。
   文件 Apply 到此结束；Current 在提交前要求精确根仍安全，冻结运行目标，关联成功
   receipt 后经 `Runtime/CurrentRestart` 请求练习切换。失败 Retry 只重验冻结目标，
   不读候选、编译或再次提交；重启与定义完成分别记账。

公共发现契约为5：`Match / Reconcile / Locate / Inject / Commit`，其中 Locate/Inject
区分逐 unit 解析和逐 owner 聚合准备，Commit 只登记片段；所有 owner 由一个事务发布。
提交作用域由 Monitor 的 layout 按钮打开，`View:update` → `Plugin:Tick` 仅驱动监视。
令牌验证主线程、生命周期与重入，调用时机仍由可信 UI 入口保证。
没有旧载体发布、直接 upvalue Patch、map 回退、并行版本账本或单 owner 发布路径。

## 窗口

- **Monitor**：监视状态、当前卡（`Source: Spell Practice` / `Source: SC Debug`）、
  稳定候选，以及 Apply、Retry Restart、Dismiss、Rescan、Start/Stop Watching。
- **Change Log**：最多 500 条事件，记录候选、应用和重启结果。

## 模块

模块位于仓库的 `SpellHotReload/` 下，`__init__.lua` 是引擎入口。

| 位置 | 职责 |
| --- | --- |
| `Load/LoadHook.lua`、`Load/AnchorLoad.lua` | 正常首载执行一次，保存完整 entry、公共 FileAnalysis、原始字节、函数身份及共享 cell anchor |
| `Load/AnchorRegistry.lua` | 持有首载 entry，提供只读 cell 查询；Missing 保留引用至会话释放 |
| `Pipeline/Adapter.lua`、`NodeRegistry.lua`、`FileMatch.lua`、`UnitIndex.lua`、`Driver.lua` | 契约5注册、完整候选发现、逐 unit/owner 准备及全部片段收齐后的事务调度 |
| `Pipeline/FileVersions.lua`、`Dependencies.lua` | 唯一文件快照/owner贡献与实际 unit 图、有限需求和 root 来源；不拥有适配器细粒度规则 |
| `Adapters/Local/Local.lua`、`LocalDefinitions.lua`、`LocalVersions.lua` | 已有全文节点上的局部定义匹配、支持范围、私有映射、实际版本、依赖需求和最终选择 |
| `Adapters/Card/Card.lua`、`CardCallbacks.lua` | 回调结构解释、所有权与业务绑定约束、最终回调准备和片段登记；不选择 Local 定义或独立发布 |
| `Adapters/Card/CardTarget.lua`、`CardVersions.lua` | 精确对应/重启证明、Card 私有版本和公共实际图派生的依赖观察 |
| `Adapters/Object/` | 正常首载 Class 来源、已有对象类/六回调与数字槽、复制继承拒绝、私有版本及共同事务片段 |
| `Source/` | 公共语法/绑定/节点事实、编译与选中闭包准备/接线工具；不拥有 Local 领域规则、版本或发布权限 |
| `Apply/FileApply.lua` | 顶层效果门禁、Include 排除及完整候选剩余核对 |
| `Apply/FileCommit.lua`、`CommitCheck.lua`、`CommitPhase.lua` | 中立共同事务、所有 owner 权限/冲突/Guard、单次相位授权、日志、回滚及最后安装共同快照 |
| `Runtime/CurrentRestart.lua` | 冻结当前目标、关联实际 receipt、重验发布后身份、请求练习切换及重试去重 |
| `Runtime/Plugin.lua`、`Watcher.lua`、`SnapshotStore.lua` | 会话生命周期、文件监视、候选及具体 Apply 编排 |
| `Adapters/Card/PracticeBinding.lua`、`GeneratedBossScanner.lua` | 读取当前练习/SC Debug 绑定，格式检查及 UI 摘要 |
| `UI/View.lua`、`UI/Tab/`、`Runtime/ChangeLog.lua` | 调试界面与日志 |

两侧只读协调通过 `Driver:DiscoverPublished` 接收共同实际 publication 和同一次完整
FileAnalysis。`FileVersions.Publication` 投影每个原 owner 的实际记录；Local/Card
各自解释细粒度定义，候选零命中仍协调旧侧。解析/Match 失败或原 owner 不可用时
保留 unresolved，不从缺失推断删除；协调结果本身不授予选择、发布或版本推进许可。
本支持范围要求局部声明集合/顺序/种类及已有定义的词法支持保持；函数必须是唯一
直接定义/写入，控制块、重复定义或捕获变化按实际规则拒绝，普通状态不重新初始化。
可选回调删除要求原 owner、实际旧定义/版本、候选精确对应和完整文件效果 proof；
保存的默认函数进入同一次共同事务，前后 Guard 重验原证据。成功发布才推进版本，
重复扫描不重复删除，恢复源码按实际版本比较；整卡/整类消失保留活体。
零 Card 命中仍有原 owner 的读集；真正无动作时可以返回共同 no-op receipt，
以原快照核对完整剩余，不伪造回调或版本更新。Local 的独立安全定义仍按其 root
及完整文件门禁选择，不借零 Card 命中绕过；没有绑定清空或函数删除执行器。

适配器仅实现 `ContractVersion = 5` 的 `Match / Reconcile / Locate / Inject / Commit`。
Driver 仅注册 discovery Id，不提供旧载体路由或 `Plan / Commit / Apply / Restart`。
Card 不接收旧 request、平铺 env 或混合聚合计划；每个 owner 只登记自己的片段。
`GeneratedBossLoader`、`Legacy/Functions`、`UpvalueRegistry`、`LoadVersions`、
旧 Host/Value 适配器、`Source/FunctionVersions` 与 `Apply/CardCommit` 均已退役；
所有实际发布只经过一次 `FileCommit`，没有兼容入口或第二套账本。

首载 `entry.map` 是同步采集的 revision-zero 函数身份输入；它不随 Apply 更新。
Plugin 仅接收完整 entry，不从局部 map 重建版本历史，不提供直接 map 发布入口。
Card 和 PracticeBinding 不提供重启转发；重启属于 Runtime 工作流。
Current 在提交前冻结目标，成功 receipt 关联后请求切关；接受请求仍不证明 stage/Boss 已就绪。
Retry 消费同一冻结目标，不重读源码、不编译、不再次发布；文件 Apply 不请求重启。

## 验证

从游戏目录运行 LuaJIT 离线回归子集：

```powershell
luajit plugin/SpellHotReload/SpellHotReload/tests/Run.lua
```

`Run.lua` 保留原基础源码、发现、协调、监视和重启子集，并纳入公共依赖、Local、
Card、Object、共同事务、FileApply 和 Plugin 集成及退役断言。它要求真实共享 upvalue 能力，
不代表所有 spec，也不属于引擎 smoke。完整回归将每个 `tests/*Spec.lua` 的 `run()`
放在独立进程调用；部分故障注入 spec 还需对应源码路径参数。首载/释放、事务回滚、
Current/文件 Apply、候选剩余、连续共享状态和冻结 Retry 各有定向测试。
`PlanningFixture.lua` 只组装真实双 owner 首载→公共 source/协调→显式 operation→
共同准备/事务→发布后新发现，不执行候选或提供生产替代比较算法。
`RetiredInterfacesSpec.lua` 禁止旧导出和混合准备入口，允许 Card 私有的实际版本
`Compare`；独立冷加载测试另禁止装载已删除模块。离线测试不证明实际引擎按钮、
异步切关、完整视觉或性能。共同接口/事务/共享状态变更扩大相关回归，其余按影响面选择。

`EngineSmoke.lua` 与 `EngineSmokeScDebug.lua` 是显式启用的引擎 harness，
使用生产首载 entry 和 layout 中的 `ApplyFromUI` 集成入口，保留实际能力检查；
不据此声称点击了原生 Monitor 按钮。普通 harness 使用 userdata 人工夹具，观察
原共享状态、两次新练习 Boss/任务以及 Dismiss 跨 drift/rescan 持续生效；其 watcher
监视夹具目录，替换前先停止原 watcher，不改产品门禁。SC harness 消费真实首载
FileAnalysis 和相同物理字节，检查回调/共同快照不变，再等待普通练习新 Boss；
它不覆盖有定义变化或双向导出转换。调试 view 存活于跨 stage 的 Ldebug 注册表，
update 只轮询，Apply 在启用窗口的 layout 发起；关闭/折叠窗口或隐藏全局调试 UI
会使 layout 等待，超时需先区分观察器与环境，不能直接判为产品回归。

这些 harness 尚未在共同发布路径执行；保留已有冻结证据，不重跑旧包或覆盖旧输出。
实际执行前需单独核对启动、场景、observer生命周期、输入/输出和日志保护范围。
它们会写入 `userdata/spell_hot_reload_smoke/` 并可能切关或退出进程。性能仍须相同
输入下的真实 Apply 墙钟和帧阻塞对比，覆盖无定义变化和真实 changed receipt；
减少全文分析或解析次数只能解释结果，不能替代计时。

### Source statement boundaries and diagnostics

`Source/Lexer.lua` owns complete number, string and compound-symbol tokens.
Numeric spelling is validated once, without evaluation; unary minus remains a
separate operator. All consumers share these token categories and byte offsets.
Card policy accepts number tokens directly and still refuses arithmetic or calls.

`Source/LuaSyntax.lua` consumes those tokens directly with Lua 5.1 grammar,
so top-level statement boundaries do not depend on line breaks. It performs
no token coalescing, numeral rescanning, value evaluation or runtime type inference. It retains a syntax tree of nested blocks and expressions without compiling or executing the file. Lexer errors
and unsupported syntax produce no partial analysis. FileAnalysis additionally
checks full-source compiler limits before owner discovery; selected closure/capture
checks still run in preparation. Syntax boundaries alone are not a complete
binding or runtime identity proof. LuaJIT-only labels/goto, cdata and
hex-float numerals are currently unsupported; nesting over 160 analysis levels
is refused with a diagnostic.

`Source/StatementAlignment.lua` provides ordered exact-signature evidence for
file policy and remainder diagnostics. Unique signatures anchor unchanged
regions; repeated unanchored regions stay ambiguous. An insertion does not make
all following unchanged statements pending. Changed rows keep independent old
and candidate byte locations. Reordered effects are not accepted as equivalent.
Unknown top-level edits still refuse file Apply, and source alignment grants no
runtime ownership, publication or deletion permission. Actual old-only records
now enter reconciliation; callback deletion additionally requires its exact
owner/version tombstone, fresh location and the existing atomic transaction.

`LuaSyntaxSpec.lua` and `StatementAlignmentSpec.lua` exercise grammar boundaries,
invalid-source refusal, ordered changes, duplicates and large sparse inputs.
These are offline regression tests; current engine integration is still pending.


The shared syntax tree records declarations, assignment targets/values, calls and
arguments, members/indices, function parameters/bodies, table fields and control
blocks. Source.SyntaxTree supplies structural queries and byte extraction, not
another parser or runtime permission. FileAnalysis builds the shared whole-file
IR and binding facts; LocalDefinitions owns Local matching/support, while
FunctionPlan prepares only owner-selected descriptors with full lexical context.
Card discovery/registrations, file wiring/Include policy and closure nested-reference
checks consume these nodes. Their token-position grammar matchers are removed.
Lexer decodes string literals once without compiling them; raw spelling remains
available for conservative signatures. Name comparisons are adapter policy,
while signatures and source slices retain exact token/source evidence. Binding
confidence, ownership, final guards and actual upvalue checks remain separate.

String decoding uses the supported Lua 5.1 escape subset; unknown escapes are
refused explicitly. GeneratedBossScanner's class
key hint also consumes index-expression nodes; header/SC Debug text checks are
format hints and confer no structural or publication authority.

Function and callback version signatures reuse shared node/token ranges, including
method receiver normalization; they do not tokenize extracted bodies again.
