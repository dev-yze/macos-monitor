# Changelog

所有重要变更都会记录在这个文件里，格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.1.1] - 2026-08-19

### 新增
- `Assets/MacOSMonitorAppIcon.png` 作为 App 图标源文件（1254×1254）
- `package.sh` 新增图标构建步骤：打包时自动从 PNG 生成各尺寸 `.iconset` → 编译为 `AppIcon.icns` → 拷进 `.app/Contents/Resources/`
- Info.plist 新增 `CFBundleIconFile`，Finder / Dock / 关于窗口显示正式图标

## [1.1.0] - 2026-08-19

### 新增
- 高级指标断线后**指数退避自动重连**（1 s → 2 s → … → 30 s 封顶），收到样本后自动重置退避计数
- **10 秒周期健康巡检兜底**：事件驱动重连存在盲区（重连瞬间 helper 尚未重建 FIFO，App 可能停在已删除 inode 上等不到任何事件），巡检发现 12 s 无样本即强制重建流
- 重连时**排空管道缓冲**（`O_NONBLOCK` 读至 EAGAIN）+ 重置切分器，丢弃积压的旧样本与不完整数据，避免旧字节被 parser 打上「现在」的时间戳混进历史
- `PowermetricsParser` 新增 `parseDetailed`，返回解析结果与**越界数值计数**（功耗 0–500 W、频率 0–10 GHz、占用率 0–100 %、温度 -40–150 ℃），越界值直接丢弃，为后续告警功能铺路
- 设置面板新增**后台服务生命周期管理**：显示「卸载后台服务…」/「安装后台服务…」按钮，带确认弹窗与结果反馈，root daemon 不再只能靠终端命令卸载
- `MetricsStore` 新增持久化开关 `advancedMonitoringEnabled`，卸载后台服务后置 false，下次启动不会再自动弹安装授权框
- `HelperInstaller` 新增 `uninstall()` 与 `needsUpgrade` 检测，支持 helper 脚本版本标记与升级路径（v2：FIFO 权限收紧）
- 设置面板新增**屏幕录制权限引导**：开启 FPS 采集但权限不足时，显示「未授予屏幕录制权限」+「前往授权…」按钮，直达系统设置 → 隐私与安全性 → 屏幕录制
- App 重新激活时自动重试 FPS 流（用户在系统设置授完权回来不用手动拨开关）
- 电池指标新增三分支状态：`charging` / `notCharging` / `unavailable`，桌面 Mac 或读取失败时显示「无电池」，不再误显示「未充电」
- `MetricsSnapshot` 新增快照级 `merge(_:)`，字段级合并逻辑从 Store 下沉到模型层，Store 与采集循环复用同一套
- `MetricsStore.merge` 新增 `recordsHistory` 参数，高级 powermetrics 样本只更新当前状态不单独入历史
- 基础采集循环改为「一轮收集 → 合成单条完整快照 → merge 一次」，历史严格一周期一条，不再出现半成品快照
- 新增 `ReconnectBackoff` 可独立测试的指数退避器
- 新增单元测试 6 个：FIFO 排空、快照合并语义、历史记录计数、幂等持久化、越界丢弃、电池空态

### 修复
- 修复高级指标断流后永不恢复的问题（原实现仅 onEnd/onFailure 标记失败，不会自动重建流）
- 修复 observation 递归观察模式偶发双触发导致的**安装后台服务弹两次密码框**问题（Store 幂等 setter + AppDelegate 安装互斥锁双层防御）
- 修复设置面板「温度」选项在温度不可用时仍可选的误导（未显式禁用，保持现有优雅降级文案；通过数值校验确保即使注入也不显示荒谬值）

### 优化
- helper 脚本从 v1 升级到 v2：FIFO 权限由 `666` 收紧为 `0660 root:admin`，本机非 admin 进程无法再伪造监控数据或干扰可用性
- 历史记录条数大幅减少（2 s 间隔 5 分钟约 150 条完整快照，取代之前 600+ 条半成品）
- 版本号改为单一来源：`SettingsView` 徽标从 `Info.plist` 读取 `CFBundleShortVersionString`，裸跑 debug 时显示 `dev`
- `package.sh` 支持 `SWIFT_BUILD_FLAGS` 环境变量透传（如沙箱受限环境下需要 `--disable-sandbox`）

### 安全
- FIFO 权限收紧至 `0660 root:admin`（CWE-749 暴露危险功能面：本机任意进程可伪造监控数据）
- powermetrics 解析数值加入合理性校验（为将来阈值告警消除注入风险）

## [1.0.2] - 2026-08-17

### 新增
- 新增可选的**实时屏幕 FPS 采集**（基于 ScreenCaptureKit），按显示器刷新率采样，带节流上报与过期保护
- 显示器区块新增「实时屏幕 FPS」行（仅在 FPS 采集开启时显示）
- 设置面板新增「采集实时屏幕 FPS」开关（需屏幕录制权限，首次使用会弹系统授权框）
- `MetricFormatters` 新增 `framesPerSecond` 格式化
- `MetricsSnapshot` 新增 `screenFramesPerSecond` 字段
- `MetricsStore` 新增 FPS 持久化开关与 `setScreenFramesPerSecond` 实时更新（不写入历史）
- 新增 FPS 计数与上报器的单元测试

### 优化
- 状态栏更新节流：FPS 高频回调不频繁触发 UI 刷新
- 包版本升至 1.0.2，同步更新 package.sh 元数据

## [1.0.1] - 2026-08-17

### 新增
- 马卡龙配色体系（`Macaron` 色板 + `MacaronBadge` 胶囊标签组件）
- 各区块使用对应主题色圆点 + 胶囊 badge 区分状态

### 修复
- 修复左键面板点击外部无法关闭的问题（新增全局鼠标点击监听兜底 `.transient` 行为）

## [1.0.0] - 2026-08-17

### 新增
- **菜单栏实时指标**：功耗（W）/ CPU 使用率 / 温度，可在设置中切换，持久化保存
- 左键监控面板：CPU（使用率、频率、E/P 核每核竖条图）、GPU（使用率、功耗）、内存（已用/总量、压力、Swap）、电池（电量、功率、状态）、磁盘（读取/写入吞吐）、外部存储、显示器刷新率、温度、顶部功耗 sparkline（最近约 5 分钟）
- 右键设置面板：采样间隔（1/2/5/10 s）、菜单栏显示指标、采集状态、退出
- **LaunchDaemon 架构**：root helper 常驻跑 `powermetrics` 写 FIFO 命名管道，App 以普通用户身份只读管道，运行时零权限需求；`RunAtLoad + KeepAlive` 保证开机自启、崩溃自愈
- HelperInstaller：首次运行弹一次管理员授权框安装，之后永久免密
- 五个采集器：`SystemStatsCollector`、`BatteryCollector`、`DisplayCollector`、`StorageCollector`、`PowermetricsStream`
- `PowermetricsParser` + `PowermetricsSampleSplitter` 文本解析，使用捕获样本做单元测试，可独立于硬件迭代
- `MetricsStore`（Observation 驱动）：快照合并、5 分钟内存历史、采集器状态、用户设置持久化
- 完整打包链路：release 构建 → .app → hardened runtime 签名 → notarytool 公证 → stapler 钉票 → zip 分发
- 17 个单元测试，覆盖解析、切分、存储、格式化
