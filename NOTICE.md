# 第三方素材与来源声明

本项目的**源代码**（Swift / Shell / Python）为原创，采用 [MIT 许可](LICENSE)。
**角色动画素材**与**角色形象**不适用 MIT 许可，来源与授权情况如下。

---

## 1. 动画素材

本项目使用的 106 段角色动画（640×360 黑底 WebM，以及由其转码得到的带 Alpha 通道 HEVC 文件）
来自以下开源项目：

| 项目 | 地址 | 许可 |
|---|---|---|
| **dsh-pet-indesktop** | https://github.com/MerZlin/dsh-pet-indesktop | MIT，Copyright (c) 2026 Merzlin |

该项目的素材本身又来自更早的两个项目：

| 项目 | 地址 | 许可 |
|---|---|---|
| dsh-pet | https://github.com/PC2005-cloud/dsh-pet | — |
| deepseek-pet | https://github.com/zhiyou-conder/deepseek-pet | Unlicense（public domain） |

**MIT 许可要求保留版权声明**，因此在分发本项目（含二进制包）时，必须同时分发本文件。

素材在本项目中的处理方式（均为本地离线转码，未改变原始内容）：

1. 黑底抠图：`ffmpeg colorkey` 把纯黑背景转为透明通道
2. 编码转换：VP9 → HEVC with Alpha（`hevc_videotoolbox`）
3. 2× 超采样：640×360 → 1280×720（Lanczos + 轻锐化）

---

## 2. 角色形象

角色「DeepSeek 娘」（蓝色长发、鲸鱼鳍耳、女仆装、白色大碗，别称「蓝色大肥鱼」）
源自**百度贴吧 deepseek 吧的社区创作**，并非 DeepSeek（深度求索）官方形象。

- 本项目为**技术演示与个人使用**目的，对角色形象不主张任何权利
- 本项目与 DeepSeek / 深度求索公司**无任何关联**，未获其授权或背书
- 未使用 DeepSeek 的商标、Logo 或官方素材
- 如在商业场景使用，请自行联系角色原作者取得授权

---

## 3. 本项目未包含的内容

- 未复制上游项目的 Python 源代码。本项目的桌宠逻辑（窗口、动画调度、物理、
  提醒引擎、设置界面）为 Swift 重写实现
- 未包含上游项目的 API Key、配置文件或硬件绑定信息
  （上游仓库曾公开提交过含 API Key 的 config.json，本项目不含任何密钥）

---

## 4. 参考与致谢

在设计交互与动画调度时参考了以下项目的思路，特此致谢：

- **MerZlin/dsh-pet-indesktop** — 动画分类（idle / click / drag / move / turn / random）、
  物理抛掷与边缘反弹、待机随机动作节奏
- **zhiyou-conder/deepseek-pet** — 最初的角色设定与交互范式
  （注意：该项目仓库中主程序仅有 `.pyc` 字节码，本项目未使用其代码）

---

## 5. 免责

素材与角色形象的权利归各自原作者所有。若相关权利人认为本项目使用方式不妥，
请通过 Issue 联系，将立即移除相关内容。
