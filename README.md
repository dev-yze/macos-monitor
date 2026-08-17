# MacOSMonitor

面向 Apple Silicon Mac 的轻量级菜单栏能耗监控工具（适配 M5 Pro）。用 Swift + SwiftUI 编写，通过 Swift Package Manager 构建。

## 功能

- **菜单栏实时指标**：功耗（W）/ CPU 使用率 / 温度，可切换（设置里选，持久化）。
- **左键单击** → 监控参数面板：
  - CPU：使用率、频率、**每核占用竖条图**（带 `E1–E12` 效率核 / `P1–P6` 高性能核标签）
  - GPU：使用率、功耗
  - 内存：已用/总量、压力、Swap
  - 电池：电量、功率、状态
  - 磁盘：读取/写入吞吐
  - 外部存储、显示器刷新率、温度
  - 顶部功耗趋势 sparkline（最近约 5 分钟）
- **右键单击** → 设置面板：采样间隔、菜单栏显示指标、采集状态、退出。
- 采样间隔 1/2/5/10 秒可选，历史数据只在内存保留约 5 分钟、不落盘。

## 架构

```
┌─────────────────────┐   读   ┌──────────────┐   写   ┌──────────────────────┐
│  MacOSMonitorApp     │ ─────▶ │   命名管道    │ ◀───── │  LaunchDaemon (root)  │
│  (普通用户, 菜单栏)   │        │  FIFO        │        │  常驻跑 powermetrics   │
└─────────────────────┘        └──────────────┘        └──────────────────────┘
```

- App 只读 FIFO，**运行时不需要 root 权限**，因此**不再弹管理员密码框**。
- root 的 LaunchDaemon 负责常驻运行 `powermetrics` 并把输出写到 FIFO，`RunAtLoad + KeepAlive` 保证**开机自启、崩了自动重启**。
- 首次运行 App 会弹一次授权框安装 LaunchDaemon，之后永久免密。

## 目录结构

```
Package.swift                                  SwiftPM 清单（App / Core / Tests 三 target）
Sources/
  MacOSMonitorApp/                             菜单栏 UI + 后台服务安装逻辑
    MacOSMonitorApp.swift                      入口（NSStatusItem 无 Dock 图标）
    AppDelegate.swift                          采样循环 + 状态栏 + popover 管理
    MonitorMenuView.swift                      左键：监控参数面板
    SettingsView.swift                         右键：设置/状态/退出
    HelperInstaller.swift                      LaunchDaemon 安装（授权一次）
  MonitorCore/                                 核心库（无 UI）
    Models/                                    指标模型 + 格式化
    Collectors/                                各类采集器 + PowermetricsStream（读 FIFO）
    Parsers/                                   powermetrics 文本解析 + 样本切分
    Store/MetricsStore.swift                   状态合并 + 5 分钟历史 + 设置持久化
Tests/MonitorCoreTests/                        单元测试
scripts/package.sh                             打包 + 签名 + 公证脚本
```

## 本地构建与运行

```bash
# 构建（debug）
swift build

# 直接运行
swift run MacOSMonitorApp
# 或
./.build/debug/MacOSMonitorApp
```

> 说明：`swift test` 需要完整 Xcode（Command Line Tools 不含 XCTest），如报 `no such module 'XCTest'`，用：
> ```bash
> DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
> ```

## 测试

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

覆盖：单位格式化、快照合并/历史裁剪、powermetrics 解析、样本切分、状态/过期判断。

## 后台服务（LaunchDaemon）

### 自动安装

App 首次启动时检测到后台服务未安装，会弹一次管理员授权框自动安装。之后不再弹框。

安装的文件：

| 文件 | 路径 |
|---|---|
| LaunchDaemon plist | `/Library/LaunchDaemons/com.zhangenyang.macosmonitor.helper.plist` |
| helper 脚本 | `/Library/PrivilegedHelperTools/com.zhangenyang.macosmonitor.helper.sh` |
| 命名管道 | `/tmp/macosmonitor.powermetrics.fifo` |

### 卸载

```bash
sudo launchctl unload /Library/LaunchDaemons/com.zhangenyang.macosmonitor.helper.plist
sudo rm /Library/LaunchDaemons/com.zhangenyang.macosmonitor.helper.plist
sudo rm /Library/PrivilegedHelperTools/com.zhangenyang.macosmonitor.helper.sh
sudo rm -f /tmp/macosmonitor.powermetrics.fifo
```

### 手动管理

```bash
# 查看是否在运行
launchctl list | grep macosmonitor

# 手动加载 / 卸载
sudo launchctl load /Library/LaunchDaemons/com.zhangenyang.macosmonitor.helper.plist
sudo launchctl unload /Library/LaunchDaemons/com.zhangenyang.macosmonitor.helper.plist
```

## 打包 / 签名 / 公证（分发）

### 前置：证书 + App 专用密码

1. **证书**：`Developer ID Application`（G2 中间证书），装进「钥匙串」后确认：
   ```bash
   security find-identity -v -p codesigning
   # 应显示 1 valid identity: "Developer ID Application: 你的名字 (TEAMID)"
   ```
   若显示「证书不受信任」，去 [apple.com/certificateauthority](https://www.apple.com/certificateauthority/) 下载安装 **Worldwide Developer Relations - G2** 中间证书。

2. **App 专用密码**：去 [appleid.apple.com](https://appleid.apple.com) → 登录与安全 → App 专用密码 → 生成（公证用，只显示一次）。

### 打包

```bash
export APPLE_ID="你的 Apple ID 邮箱"
export NOTARY_PASSWORD="你的 App 专用密码"
./scripts/package.sh
```

脚本会：构建 release → 打 `.app`（含 `Info.plist`、`LSUIElement` 隐藏 Dock）→ `codesign` 签名（hardened runtime + 时间戳）→ `notarytool` 公证 → `stapler` 钉票 → 产出 zip。

产物：`build/MacOSMonitorApp.app` 和 `build/MacOSMonitorApp.zip`（后者可直接分发）。

验证：

```bash
spctl -a -vv build/MacOSMonitorApp.app
# 应显示: accepted / source=Notarized Developer ID
```

## 配置项（`scripts/package.sh` 顶部）

| 变量 | 默认值 |
|---|---|
| `BUNDLE_ID` | `com.zhangenyang.macosmonitor` |
| `VERSION` | `1.0.2` |
| `TEAM_ID` | 自动从钥匙串检测（可用 `TEAM_ID` 环境变量覆盖） |
| `DEVELOPER_ID` | 自动从钥匙串检测（可用 `DEVELOPER_ID` 环境变量覆盖） |

换 Bundle ID 或升级版本后，需重新跑 `package.sh` 重新公证。

## 已知限制

- 仅支持 Apple Silicon（Intel 未适配）。
- 温度读数：M5 Pro / macOS 26 的 `powermetrics` 不提供 SMC 温度（只有 thermal pressure），温度区块会显示「不可用」。
- 历史数据只在内存，不落盘；重启即清空。
- 菜单栏「双击」未区分（macOS 上双击会先触发单击），故用**右键**访问设置。
