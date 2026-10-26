<div align="center">

# LuckyPet

**macOS 原生桌宠 + 定时久坐提醒**

Swift / AppKit 实现 · 无 Python 运行时 · 106 段透明动画 · 全程本地运行、不联网

<img src="docs/screenshot.png" width="380" alt="LuckyPet 提醒气泡">

</div>

---

## 这是什么

一只常驻桌面的小女仆，到点会喊你起来活动。

和常见的桌宠实现不同，本项目**不是**打包 Electron 或 Python 运行时，而是用 Swift + AppKit
直接写成原生 `.app`：透明无边框窗口、AVFoundation 硬件解码带 Alpha 通道的 HEVC 动画、
自绘气泡、菜单栏常驻。安装体积 344MB，其中 343MB 是动画素材。

提醒功能是本项目相对原版桌宠的主要增补：固定间隔循环、可编辑文案池、
午休/夜间免打扰、临时暂停、今日计数。

## 功能

**提醒**

- 固定间隔循环，默认 **45 分钟**，可调 1–240 分钟（另有 25 / 45 / 60 / 90 快捷按钮）
- 提醒文案池，每行一条随机使用，可自行增删
- 免打扰时段：午休 + 夜间，各自独立开关与起止时间
- 临时暂停 15 / 30 / 60 / 120 分钟，或「本轮重新计时」
- 触发时：桌宠播放回应动画 + 头顶气泡（默认 25 秒）+ 系统通知 + 提示音
- 菜单栏实时显示「下次提醒 X:XX 后」「今日已提醒 N 次」

**桌宠**

| 操作 | 效果 |
|---|---|
| 单击 | 摸头：回应动画 + 随机傲娇台词 |
| 按住拖动 | 拎起来，窗口跟随鼠标 |
| 快速甩动后松手 | 抛物线飞出，撞屏幕边缘反弹，落地恢复待机 |
| 右键 | 摸头 / 立即提醒 / 暂停 30 分钟 / 设置 / 隐藏 / 退出 |
| 空闲 22–45 秒 | 随机表演一段动作（89 段素材） |
| 菜单栏图标 | 提醒状态、设置、大小、置顶、退出 |

## 系统要求

- macOS 13 或更高
- Apple Silicon（arm64）**已实机验证**；Intel 未验证，理论上可自行编译
- 系统通知需手动授权（首次启动会弹窗）

## 安装

### 方式一：下载打包好的应用

从 [Releases](https://github.com/xiamu508/LuckyPet/releases) 下载 `LuckyPet.zip`，解压后拖到「应用程序」文件夹。

首次打开需 **右键 → 打开**（本项目使用 ad-hoc 签名，未做 Apple 公证）。

### 方式二：从源码构建

需要 Xcode 命令行工具（Swift 6+）、ffmpeg 与 numpy（`pip install numpy`）。

```bash
git clone https://github.com/xiamu508/LuckyPet.git
cd LuckyPet

# 1. 下载动画素材（约 52MB，来自上游 MIT 项目）
python3 scripts/fetch_assets.py

# 2. 抠图 + 转码：黑底 WebM → 颜色反混合 → 带 Alpha 的 HEVC（1280×720）
python3 scripts/rematte.py --src assets_raw --dst Assets/clips

# 3. 构建 .app
./build.sh
```

> `scripts/transcode.py` 与 `scripts/upscale_hd.py` 是旧管线（`colorkey` 直接出 alpha），
> 边缘会残留黑边，仅为兼容保留；新管线用 `rematte.py`。

产物：`dist/LuckyPet.app`

> 素材没有放进仓库（153MB），由脚本从上游获取并按上述管线在本地转码。
> 这样既避免仓库臃肿，也让素材的来源与许可关系保持清晰。

## 关于清晰度

素材上限是上游的 **640×360**，角色在画面中实际只占 **213×271 px**。显示时的对应关系：

| `petScale` | 角色显示宽度 | 物理像素（2× 屏） | 相对源素材 |
|---|---|---|---|
| 0.45 | 约 96pt | 约 192px | 缩小，有余量 |
| 0.70（默认） | 约 149pt | 约 298px | 放大 1.4× |
| 1.00 | 约 213pt | 约 426px | 接近 1:1 |

1280×720 素材属于 **2× 超采样**，本质是超采样抗锯齿，**不会凭空产生细节**。

影响观感的**主要因素其实是抠图质量，不是分辨率**：

- 旧管线用 `ffmpeg colorkey` 出 alpha，边缘像素的 RGB 仍是被黑底压暗的混合值
  （`C = α·F`），播放端再按 straight alpha 合成一次 → 角色被描上一圈断续黑边。
  实测边缘色差均值 **78.5**，57–63% 的边缘像素偏暗，全库 106 段一致。
- `scripts/rematte.py` 改为**颜色反混合**：先由纯黑背景得到确定前景（core），
  用邻域 core 色估计真实颜色 `F`，`alpha = max_c(C/F)`，边缘输出 `F` 而非观测值。
  色差降至 ~60，暗边基本消失，帧间边缘抖动从 **53.7% → 13.2%**（更稳定，不闪）。
- 顺带把编码从 `q:v 42 / alpha_quality 0.50` 提到 `q:v 62 / 0.85`，块效应与 alpha
  阶梯同时改善。代价是码率从约 1.1 Mbps 升到 2.2–2.5 Mbps，素材 153MB → 343MB。

仍然存在的硬限制：源素材角色仅 213×271 px，`petScale > 0.7` 时属于放大显示，
边缘会偏软。要真正提升只有两条路 —— AI 超分，或重绘/重建模。

## 配置

配置文件：`~/Library/Application Support/LuckyPet/config.json`

可以直接编辑，也可以在设置窗口修改（改完即时生效并写回）。主要字段：

| 字段 | 默认 | 说明 |
|---|---|---|
| `intervalMinutes` | 45 | 提醒间隔（分钟） |
| `reminderMessages` | 6 条 | 提醒文案池 |
| `breakSeconds` | 25 | 气泡停留秒数 |
| `quietHoursEnabled` / `quietStart` / `quietEnd` | 开 / 12:00 / 13:30 | 午休免打扰 |
| `nightSilenceEnabled` / `nightStart` / `nightEnd` | 开 / 23:00 / 08:00 | 夜间免打扰 |
| `petScale` | 0.70 | 桌宠大小 |
| `alwaysOnTop` | true | 始终置顶 |
| `randomActionsEnabled` | true | 空闲随机动作 |

## 项目结构

```
LuckyPet/
├── src/                      Swift 源码（约 1500 行）
│   ├── main.swift            入口
│   ├── AppDelegate.swift     生命周期、菜单栏、右键菜单、通知、提醒投递
│   ├── PetWindow.swift       透明置顶窗口、动画调度、拖拽与抛掷物理、气泡
│   ├── BubbleOverlay.swift   气泡视图（CALayer 卡片 + 文字层）
│   ├── ClipLibrary.swift     素材索引
│   ├── ReminderEngine.swift  提醒引擎
│   ├── SettingsWindow.swift  设置窗口（纯 AppKit）
│   └── Preferences.swift     配置模型与持久化
├── scripts/
│   ├── fetch_assets.py       从上游下载素材（MIT）
│   ├── rematte.py            颜色反混合抠图 + HEVC Alpha 编码（当前管线）
│   ├── transcode.py          旧管线：colorkey 抠图（保留兼容）
│   ├── upscale_hd.py         旧管线：2× 超采样（保留兼容）
│   └── assets_manifest.json  素材清单（109 个文件）
├── icon_work/gen_icon.swift  应用图标生成脚本
├── build.sh                  一键构建
├── Info.plist
├── LICENSE                   MIT（仅覆盖源代码）
└── NOTICE.md                 ★ 素材与角色形象的来源和许可说明
```

## 实现要点

几个在 macOS 上踩过的坑，记录在此以免后来者重复：

1. **`contentView.wantsLayer = true` 会让子视图/子图层的合成失效**
   表现为子视图 `draw` 正常调用、frame 正确、`isVisible == true`，但屏幕上什么都不显示；
   而直接设置 `contentView.layer.backgroundColor` 却能看见。
   → 解决：contentView 不启用图层，视频层与气泡各自 layer-backed。

2. **borderless 窗口动态 `setFrame` 不会提交到 WindowServer**
   `NSWindow.frame` 已是 313，`CGWindowListCopyWindowInfo` 仍报 217。
   → 解决：窗口高度固定，顶部预留 96pt 气泡区，不再动态 resize。

3. **独立透明气泡窗口在 `LSUIElement` 应用下不上屏**
   `windowNumber` 有效、`CGWindowList` 查不到；试过 `canBecomeKey`、`NSPanel`、
   `becomesKeyOnlyIfNeeded` 均无效。
   → 解决：气泡内嵌主窗口，不做第二个窗口。

4. **LSUIElement 应用未激活时 Core Animation 淡入不推进**
   `alphaValue` 停在 0 → 不要用 `NSAnimationContext` 做首次显示。

5. **SwiftUI 的宏在命令行 `swiftc` 下不可用**（`swift-plugin-server` 报 malformed response）
   → 设置窗口用纯 AppKit 实现，避免依赖宏插件。

## 许可与来源

**本仓库的源代码**采用 [MIT 许可](LICENSE)。

**动画素材不是本项目的原创**，来自开源项目
[MerZlin/dsh-pet-indesktop](https://github.com/MerZlin/dsh-pet-indesktop)（MIT，Copyright (c) 2026 Merzlin），
其素材又可追溯至 [PC2005-cloud/dsh-pet](https://github.com/PC2005-cloud/dsh-pet) 与
[zhiyou-conder/deepseek-pet](https://github.com/zhiyou-conder/deepseek-pet)（Unlicense）。

**角色形象「DeepSeek 娘」源自百度贴吧社区创作**，不是 DeepSeek 官方形象，
本项目与深度求索公司无任何关联。详见 [NOTICE.md](NOTICE.md)。

分发本项目（含二进制包）时请一并保留 `NOTICE.md`——MIT 许可要求保留版权声明。

## 免责

这是一个技术演示与个人自用项目。角色形象的权利归原作者所有；若相关权利人认为
使用方式不妥，请提 Issue，会立即移除相关内容。
