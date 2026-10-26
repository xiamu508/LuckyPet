# 从旧素材重建 2K 画质

面向已经拿到旧版产物的用户：如果你手上是 640×360 的初版、或 1280×720 的早期 v1.1.0，
可以按本文在**本地**把 106 段动画重建为 2560×1440。全流程离线，不上传任何文件，
也不需要 Apple 开发者账号。

## 重建改变了什么

| | 旧管线 | 本管线 |
|---|---|---|
| 源解码 | FFmpeg 默认 VP9 解码器，只取 RGB | `libvpx-vp9` 解码，保留源 alpha 位流 |
| 背景处理 | 把 RGB 当黑底重新抠图 | 按源 alpha 反解白底污染 |
| 分辨率 | 640×360 或 1280×720 | **2560×1440** |
| 边缘 | 亮色碎边，随动画闪烁 | 亚像素轮廓收缩 + 运动补偿稳定 |
| 素材体积 | 152 MB / 343 MB | 2.42 GiB |

源素材本身就是 **640×360 VP9 with Alpha**，不是黑底视频。旧管线的错误在于丢掉独立
alpha 位流后再按黑底重抠，背景残色因此变成碎边。重建保留原始 alpha，只对不稳定边缘
做反解与稳定。

## 前提

- macOS 13 或更高；Apple Silicon 可用 MPS 加速，Intel 走 CPU
- 约 8 GB 可用磁盘：原始素材 52 MB、模型 2.3 MB、Python 环境约 1.5 GB、2K 成品 2.4 GB、临时空间
- 网络：从上游拉 109 个源文件（逐文件 SHA-1 校验）+ 2.3 MB 模型
- 命令行工具：`ffmpeg` / `ffprobe`、`swiftc`（Xcode Command Line Tools）、`uv`

```bash
xcode-select --install        # 若尚未安装
brew install ffmpeg uv        # 或使用你自己的包管理器
```

## 步骤

### 1. 取得源码

```bash
git clone https://github.com/xiamu508/LuckyPet.git
cd LuckyPet
```

### 2. 建立项目内 Python 环境

```bash
UV_CACHE_DIR="$PWD/.cache/uv" uv venv --python 3.12 .venv
UV_CACHE_DIR="$PWD/.cache/uv" uv pip install --python .venv/bin/python -r requirements-hd.txt
```

缓存和虚拟环境都落在项目目录，不改动系统 Python。

### 3. 拉取原始素材与模型

```bash
.venv/bin/python scripts/fetch_assets.py
.venv/bin/python scripts/download_model.py
```

- 素材写入 `assets_raw/`，按 `scripts/assets_manifest.json` 固定到上游 revision，逐个校验 Git blob SHA-1
- 模型写入 `tools/models/realesr-animevideov3.pth`，加载前校验 SHA-256

### 4. 先试一段

```bash
mkdir -p inspection
.venv/bin/python scripts/animation_hd.py \
  --one "assets_raw/idle/待机呼吸休闲.webm" --preview
```

输出单帧 PNG 到 `inspection/`。确认终端打印的是 `Real-ESRGAN animevideov3: mps, torch.float16`
（或 `cpu, torch.float32`）、颜色与透明度正常，再跑全量。

### 5. 全量重建

```bash
.venv/bin/python scripts/animation_hd.py --device mps --workers 2
```

- 输出 `Assets/clips/**/*.mov`，2560×1440 HEVC with Alpha
- 每完成一段即写入 `Assets/hd_manifest.json`，包含源/成品 SHA-256、帧数、帧率、模型版本

### 6. 校验

```bash
.venv/bin/python scripts/verify_assets.py
```

核对 106 段是否齐全、源与成品 SHA-256、分辨率、帧数、帧率。全部通过会输出
`"passed": true` 并写出 `Assets/clip_manifest.json`。

需要额外做 macOS 原生逐帧解码验证（较慢，需先编译 `scripts/VideoProbe.swift`）：

```bash
swiftc -O scripts/VideoProbe.swift -o tools/video-probe \
  -framework AVFoundation -framework ImageIO -framework UniformTypeIdentifiers
.venv/bin/python scripts/verify_assets.py --native
```

### 7. 构建应用

```bash
source .venv/bin/activate   # build.sh 内部调用 python3 做素材校验
./build.sh
```

`build.sh` 会先跑 `verify_assets.py`，再编译 Swift、组装 `.app`、复制素材、ad-hoc 签名。
产物为 `dist/LuckyPet.app`。

`verify_assets.py` 用到 `hashlib.file_digest`（Python 3.11+）。如果跳过激活环境，
请确认 PATH 上的 `python3` 满足该版本，否则 `build.sh` 会在第一步报
`AttributeError: module 'hashlib' has no attribute 'file_digest'`。

## 断点续跑

中断后重跑第 5 步即可。脚本按 `hd_manifest.json` 逐项比对 `pipeline` 版本、`erosion`
参数、源与成品 SHA-256，一致则打印 `VERIFIED` 直接跳过。

修改 `--erosion` 会让已有记录全部失效并触发重算，这是有意设计：该参数影响轮廓像素，
不同取值不能混用。

## 耗时与体积（本机实测）

验收机为 Apple Silicon + MPS，`--workers 2`：

| 指标 | 值 |
|---|---|
| 106 段串行处理合计 | 52.4 分钟 |
| 单段中位 / 最短 / 最长 | 28.0 s / 12.6 s / 53.7 s |
| 总帧数 | 25,423 |
| 成品素材 | 2.42 GiB（2,600,608,922 字节） |

并发 2 的**理论下限**为 26 分钟；本次验收只逐段计时，未记录整体墙钟时间，因此不给实际总时长。
CPU 模式没有实测数据，按同类模型的常见经验会慢 5–10 倍，建议先用 `--one` 测单段再决定是否全量。

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--device` | `auto` | `mps` / `cpu` / `auto`；auto 在 MPS 可用时选 MPS |
| `--workers` | `2` | 并发段数，内部上限 2；每段本身已用 4 个 CPU 线程 |
| `--one` | 无 | 只处理指定文件 |
| `--preview` | 关 | 只输出单帧 PNG 到 `inspection/`，不写成品 |
| `--output` | 无 | 覆盖输出路径 |
| `--erosion` | `0.6` | 轮廓收缩像素；改动会触发全量重算 |

## 常见问题

**`original VP9 alpha channel is required`**
源文件不是带 alpha 的 VP9。请用 `fetch_assets.py` 重新拉取，不要用第三方转码过的文件。

**MPS 报错、结果出现色块**
改用 `--device cpu`。MPS 在部分 macOS 版本上对 float16 卷积存在兼容问题。

**内存占用高、系统卡顿**
把 `--workers` 降到 1。单段会把整段 RGBA 帧读入内存，长动画（>600 帧）占用更高。

**下载中断**
`fetch_assets.py` 可以重复执行，已下载且校验通过的文件会跳过。

**只替换素材、不重新编译**
可以，但需要重新签名，否则 Gatekeeper 会拒绝启动：

```bash
rsync -a Assets/clips/ dist/LuckyPet.app/Contents/Resources/clips/
codesign --force --deep --sign - dist/LuckyPet.app
```

更稳妥的做法仍是重跑 `./build.sh`。

## 可复现性说明

`Assets/hd_manifest.json` 记录每段的 `pipeline` 版本、模型 SHA-256、`erosion` 参数、
源与成品哈希、帧数与帧率；`scripts/assets_manifest.json` 固定上游 revision 与每个源
文件的 Git blob。两者合起来保证输入与参数可追溯。

同一份源码、同一批源文件、同一模型、相同 `--erosion` 在不同机器上得到的**分辨率、帧数、
时长与画面内容**应当一致；但 HEVC 编码器和 MPS/CPU 卷积的浮点行为可能带来字节级差异，
`output_sha256` 不保证跨设备相同。因此：

- 跨设备比较应看分辨率、帧数、时长与抽样画面，而不是哈希值
- `verify_assets.py` 校验的是**本机成品**与**本机** `hd_manifest.json` 记录是否一致，
  它证明"产物没有在生成后被替换或损坏"，不等于"与其他机器的输出逐字节相同"
