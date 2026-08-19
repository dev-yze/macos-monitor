# MacOSMonitor 优化与完善计划（2026-08-17，v2 按评审意见修订）

## 一、项目现状总结

### 是什么
面向 Apple Silicon（首要适配 M5 Pro）的 macOS 菜单栏能耗监控工具，Swift + SwiftUI，SwiftPM 构建，当前 v1.0.2，约 2170 行代码，3 个 commit，17 个单元测试全部通过。

### 架构（当前最成功的设计决策）
```
MacOSMonitorApp（普通用户）──读──▶ FIFO 命名管道 ◀──写── LaunchDaemon(root, 常驻 powermetrics)
```
- App 运行时**零权限要求**，仅首次安装 LaunchDaemon 时授权一次，`RunAtLoad + KeepAlive` 保证常驻。
- 关注点分离清晰：`MonitorCore`（无 UI：模型/采集器/解析器/Store）与 `MacOSMonitorApp`（菜单栏 UI + 安装逻辑）分 target，解析器用捕获样本做测试，可独立于硬件迭代。

### 已实现功能
- 菜单栏单指标显示（功耗/CPU/温度可切换，UserDefaults 持久化）
- 左键监控面板：CPU（含 E/P 核每核竖条图）、GPU、内存/Swap/压力、电池、磁盘 IO、外置存储、显示器刷新率、实时屏幕 FPS（ScreenCaptureKit，可选）、功耗 sparkline（5 分钟内存历史）
- 右键设置面板：采样间隔、菜单栏指标、FPS 开关、采集器状态、退出
- 打包链路完整：release 构建 → .app → hardened runtime 签名 → 公证 → 钉票 → zip

### 健康度
| 维度 | 评价 |
|---|---|
| 构建/测试 | ✅ 17/17 通过（本机需 `DEVELOPER_DIR` 指向 Xcode + `--disable-sandbox`） |
| 代码质量 | ✅ 良好：类型化模型、显式不可用状态、采集器职责单一 |
| 文档 | ✅ README 详尽（构建/测试/服务管理/公证全流程） |
| 版本管理 | ⚠️ 版本号硬编码在 `package.sh` 和 `SettingsView` 两处（发布流程问题） |
| CI | ❌ 无 |
| 健壮性 | ⚠️ 高级指标断流后无自动恢复（**当前最大缺陷**） |

---

## 二、确认的问题与优先级（评审修订版）

### P0 — 立刻修
1. **高级指标断流不重连**：`onEnd/onFailure` 只标失败，不会再建流；FIFO 被 helper 重建后 App 持有的旧 fd 读到 EOF，之后永久「失败」，必须重启 App。
   → 修复：断线后指数退避重开 FIFO（1s→2s→…→30s 上限），重连成功恢复 `running`。

### P1 — 其次修（数据模型与安全边界）
2. **电池空态误导**：`isCharging == nil`（桌面 Mac / 读取失败）显示「未充电」。改为三分支：充电中 / 未充电 / 无电池或不可用。（若面向台式机则升 P0）
3. **历史数据语义不干净（数据模型）**：基础循环每轮 merge 4 次（system/battery/display/storage），每次 merge 都 append 一条 history —— 历史里全是「半成品」快照，sparkline 的时间语义不干净，内存也有冗余。
   → 修复：基础采集改为「一轮收集完 → 合并成一条完整快照 → merge 一次」。
4. **重连时的样本有效性（数据模型）**：parser 用 `Date()` 打时间戳，无法识别旧样本；powermetrics 文本输出不带时间戳。
   → 修复：重连时以 `O_NONBLOCK` 排空管道 + 重置 splitter（丢弃不完整样本）；排空后 `Date()` 即近似采集时刻。
5. **FIFO 安全边界**：管道 `chmod 666` 且路径可预测，本机任意进程可伪造监控数据、干扰可用性（当前不直接导致提权，但引入告警功能后风险上升）。约束：FIFO 由 root 创建、App 以普通用户读取，不能直接 600。
   → 修复（分层）：① 权限收紧 `0660 root:admin`；② parser 增加数值合理性校验；③ 远期迁移 `SMAppService.daemon` + XPC 根治。
6. **后台服务无生命周期 UI**：装了 root daemon 却无法在 App 内卸载，体验与信任双重问题。
   → 修复：设置面板加「卸载后台服务」（确认弹窗 + osascript 授权一次 + 结果反馈）。
7. **监控面板不滚动**：固定宽 360，内容随外接设备数量增长，多显示器+多外置盘时 popover 溢出。
   → 修复：包 `ScrollView`，限最大高度（如 560pt）。
8. **高级采样不随设置联动**：UI 改的只是基础循环间隔；helper 永远 `--sample-rate 2000`。
   → 修复：helper 改为读取配置文件（用户可写路径，helper 只做纯数字校验后使用），App 改设置后 `launchctl kickstart -k` 重启 daemon 生效。

### P2 — 第三批
9. **版本号双硬编码**：`package.sh` 与 `SettingsView` 人肉同步。→ 版本号写入 Info.plist，App 从 `Bundle.main` 读取。
10. **温度选项误导**：M5 Pro/macOS 26 温度已优雅降级，但设置里仍可选「温度」，菜单栏只会显示 `-- C`。→ 无温度数据时禁用该选项（或显示但标注不可用）；同时在目标机验证 `powermetrics --samplers smc` 是否有输出。
11. **菜单栏标题无节流**：当前最高频约 FPS 4Hz 或基础采集频率，非阻断问题。→ 变化才赋值 + ≥1s 节流即可。
12. **全分辨率抓屏 FPS**：可选功能，用户主动开启。→ 先实测开启前后 App 自身功耗，再决定是否降捕获分辨率。
13. **登录时启动**：产品缺口，非缺陷。→ `SMAppService.mainApp` + 设置 Toggle。
14. **CI 优先于 lint**：GitHub Actions（macos runner）跑 `swift build` + `swift test`；SwiftLint 后置。

### P3 — 路线图功能（不算现有 bug）
- 网络吞吐监控（getifaddrs / sysctl，上下行速率）
- 功耗/温度阈值告警（`UNUserNotificationCenter`）——依赖 P1-⑤ 的数值校验先行
- 菜单栏「图标 + 指标」/ 双指标显示
- 历史落盘 / 导出 CSV
- collector mock 单测、`MetricsStore.merge` key-path 驱动重构
- `SMAppService.daemon` + XPC 替代 osascript + FIFO

---

## 三、执行计划（按修订优先级分批）

### 批次 A：止血（预计半天）— P0 ✅ 已完成（2026-08-18）
- [x] A1 高级流断线自动重连：`onEnd/onFailure` → 指数退避重开（1s~30s），成功恢复 `running` 状态；App 退出时取消退避任务
  - **实机验证发现**：FIFO 的 EOF 事件驱动路径不可靠（pkill 后 `readabilityHandler` 未收到 EOF），纯事件驱动会再次卡死。已加**周期巡检兜底**：每 10s 检查样本新鲜度，>12s 无样本直接重建流
  - 实机验收通过：`sudo pkill -f powermetrics` 后 12s 巡检发现并重建，数据流持续恢复稳定
  - 新增 DEBUG 日志 `Sources/MacOSMonitorApp/DebugLog.swift`（仅 debug 构建写入 `/tmp/macosmonitor-debug.log`）
- [x] A2 电池空态三分支：充电中 / 未充电 / 无电池或不可用
- **验收**：~~`sudo pkill -f powermetrics` 后 30s 内面板自动恢复「正常」~~ ✅ 实测 12s 恢复；24/24 单测通过

### 批次 B：数据模型（预计 1 天）— P1-③④ ✅ 已完成（2026-08-18）
- [x] B1 重连时排空管道（`O_NONBLOCK` 读至 EAGAIN）+ 重置 splitter，丢弃不完整样本
  - `PowermetricsStream.start()` 在清除 O_NONBLOCK 前把管道缓冲读空；路径改为可注入（`init(fifoPath:)`）便于测试
  - 新增 FIFO 级测试：预置完整旧样本入管道缓冲 → `start()` 后首个解析样本必须是新写入的（旧数据会产出 9.999W 假样本，可判别）
- [x] B2 基础采集一轮合并为单条快照再 merge/入历史；补 `MetricsStore` 历史语义测试
  - 字段级合并逻辑下沉为 `MetricsSnapshot.merge(_:)`（Store 与采集循环复用，顺带缓解「加字段改三处」）
  - `MetricsStore.merge(_:recordsHistory:)`：高级 powermetrics 样本只更新当前状态、不入历史
  - 基础循环每轮 4 个采集器合成单条快照 → 历史一条/周期
- **验收**：✅ 30/30 单测通过（新增 6 个）；`testOneHistoryEntryPerSamplingCycle` 保证一周期一条完整快照；`testStartDrainsStaleBufferedData` 保证重连后无旧数据突刺

### 批次 C：安全边界（预计 1 天）— P1-⑤⑥
- [ ] C1 FIFO 权限收紧 `0660 root:admin` + parser 数值合理性校验（功耗 0~500W、频率 0~10GHz 等，越界丢弃并计数）
- [ ] C2 设置面板「卸载后台服务」：确认弹窗 → osascript 授权 → unload + 删除 plist/脚本/FIFO → 状态反馈
- **验收**：非 admin 用户无法读管道；卸载后 `launchctl list | grep macosmonitor` 为空且 App 状态显示「未安装」

### 批次 D：体验补齐（预计 1 天）— P1-⑦⑧
- [ ] D1 面板 `ScrollView` + 最大高度 560pt
- [ ] D2 采样率联动：helper 读配置文件（纯数字校验），App 写配置 + `launchctl kickstart -k`
- **验收**：外接 3 台显示器 + 2 块外置盘时面板完整可滚动；设置 10s 后 `ps` 可见 powermetrics 参数同步变化

### 批次 E：发布与工程化（预计 1 天，可与 D 并行）— P2
- [ ] E1 版本号单一来源（Info.plist → `Bundle.main`）
- [ ] E2 温度选项：无数据时禁用/标注；目标机验证 `smc` sampler
- [ ] E3 菜单栏标题节流（变化才赋值 + ≥1s）
- [ ] E4 GitHub Actions：macos runner 跑 build + test
- **验收**：CI 绿灯；改版本号只动 `package.sh` 一处

### 批次 F：实测后再定 — P2
- [ ] F1 FPS 抓屏开销实测（开/关各 10 分钟，对比 App 自身 `powermetrics` 功耗），超标则降捕获分辨率（宽 ~320）
- [ ] F2 登录时启动（`SMAppService.mainApp`）

### Backlog（P3，路线图）
网络吞吐监控 / 阈值告警（依赖 C1 数值校验）/ 菜单栏图标 / 历史落盘与 CSV 导出 / collector mock 测试 / merge 重构 / XPC 迁移 / SwiftLint

### 优先级速查
| 批次 | 主题 | 关键收益 |
|---|---|---|
| A | 断流自愈 + 电池空态 | 消除「用一会儿就失败」与桌面机误导 |
| B | 数据模型：样本有效性 + 单快照历史 | sparkline 时间语义干净，内存减半 |
| C | 安全边界：FIFO 收紧 + 卸载 UI | 数据可信；root 组件生命周期可控 |
| D | 滚动面板 + 采样联动 | 多设备可用；root 进程不白耗 CPU |
| E | 版本号/温度选项/节流/CI | 发布流程与工程治理 |
| F | FPS 实测、登录启动 | 体验补齐，数据驱动决策 |
