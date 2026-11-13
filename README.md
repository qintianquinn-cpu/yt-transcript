# yt-transcript

把没有字幕的 YouTube 粤语／中文视频，变成可交付的**简体中文文字稿 + 要点摘要**。

作为 [Claude Code](https://claude.com/claude-code) Skill 使用，也可以当普通脚本跑。

> **一句话**：YouTube 上大量香港学校讲座、家长会、行业分享**没有字幕轨**，粤语 ASR 又比英文难得多——这条管线把「下载 → 转写 → 繁简转换 → 人工订正」整条链路固化成可复用的 Skill。

---

## 解决的问题

| 环节 | 卡点 | 本项目的处理 |
|---|---|---|
| 下载音频 | yt-dlp 2026 起 YouTube 要 PO token，没有就只返回缩略图 | 挂官方 [bgutil-ytdlp-pot-provider](https://github.com/Brainicism/bgutil-ytdlp-pot-provider)，配 `VISITOR_DATA` + `player_skip=webpage` |
| 转写 | **PyTorch MPS 跑 whisper 会数值退化**，输出 `we would we would...` 这类幻觉 | 改用 [mlx-whisper](https://github.com/ml-explore/mlx-examples)（Apple Silicon 原生，正确且快） |
| 中英夹杂 | whisper 全局只做一次语言检测，整段锁定一种语言会把另一种全转错 | 按 5 分钟分块，**逐块独立检测语言** |
| 专有名词 | 粤语专名错得离谱（实测「協恩」被听成 協音／協定／協議 三种） | `YT_ASR_PROMPT` 领域词表 + 人工订正环节 + 同音字速查表 |

---

## 快速开始

### 1. 安装 Skill

```bash
git clone https://github.com/qintianquinn-cpu/yt-transcript.git \
  ~/.claude/skills/yt-transcript
```

### 2. 准备环境

```bash
bash ~/.claude/skills/yt-transcript/scripts/setup_env.sh
```

会做三件事：建 venv 装 mlx-whisper、克隆并编译 bgutil PO token provider、打印要 export 的环境变量。

**前置条件**：macOS on Apple Silicon、Node.js ≥ 18、Python ≥ 3.10、ffmpeg。

### 3. 跑

```bash
bash ~/.claude/skills/yt-transcript/scripts/yt2md.sh "<视频URL>"
```

产出：

```
<标题>_繁体转写.txt / .json   ← 原始转写（带时间戳）
<标题>_简体.txt                ← 简体书面语初稿
```

然后把 `_繁体转写.txt` 交给 Claude，做专有名词订正、口语书面化、要点摘要，产出最终三件套：

- `<标题>_简体文字稿.md` —— 分节、带时间戳、附订正记录与存疑清单
- `<标题>_简体文字稿.txt` —— 纯文本版
- `<标题>_要点摘要.md` —— 关键数字表、分类要点、行动清单、要点索引

---

## 工作原理

```
YouTube URL
   │
   ├─ Step 0  查字幕轨 ─────────────► 有「人工字幕」？直接抓，最准，不用跑 ASR
   │                                  只有「自动字幕」？也抓一份，供交叉核对
   │
   ├─ Step 1  下载音频
   │          yt-dlp 2026 (python3.11)
   │          + bgutil PO token provider (Node)
   │          + 匿名 cookie jar + ytcfg VISITOR_DATA
   │          + player_skip=webpage + --js-runtimes node
   │
   ├─ Step 2  ffmpeg → 16 kHz / 单声道 / PCM16
   │
   ├─ Step 3  mlx-whisper large-v3 分块转写
   │          逐块检测语言 · condition_on_previous_text=False
   │          temperature 回退 · initial_prompt 喂领域词表
   │
   ├─ Step 4  OpenCC 繁→简 + 粤语口语→书面语
   │
   └─ Step 5  人工订正  ← 真正决定成品质量的一步
              专有名词 / 同音错字 / 整句重写 / 标〔听不清〕
```

---

## 三个必须知道的坑

**1. PyTorch MPS 跑 whisper 会产生幻觉。**
输出长这样：`we would we would we would we would...`。看起来像音频坏了，其实音频是好的（ffmpeg 体检：mean −32.8 dB、max −9.9 dB、句间静音分布均匀）。这是 MPS 后端的数值缺陷，不是音频问题。**直接用 mlx-whisper。**

**2. 不要并行跑多个转写实例。**
两个 whisper 各加载一份 large-v3 权重 ≈ 6 GB，会把内存吃穿、swap 飙到 15 GB，解码速度从 200 frames/s 掉到 50。实测 37 分钟音频因此跑了 44 分钟。**一次只跑一个。**

**3. Whisper 全局只做一次语言检测。**
粤语夹英文的讲座，整段锁定一种语言会把另一种语言的段落整体转错。**必须分块逐块检测**（脚本已实现）。

更完整的排障清单见 [`references/troubleshooting.md`](references/troubleshooting.md)。

---

## 目录结构

```
yt-transcript/
├── SKILL.md                          # Skill 主文件（Claude Code 读这个）
├── scripts/
│   ├── setup_env.sh                  # 环境准备
│   ├── yt2md.sh                      # 一键管线
│   ├── asr_mlx.py                    # mlx-whisper 分块转写
│   ├── convert.py                    # 繁→简 + 粤语口语书面化
│   └── check_probe.py                # 重复幻觉检测
├── references/
│   ├── troubleshooting.md            # 排障速查（下载/转写/环境）
│   ├── hk-homophones.md              # 香港场景同音错字速查
│   └── delivery.md                   # 交付物规范
└── examples/
    └── heep-yunn-2023-24/            # 完整样例
```

---

## 环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `YT_VENV` | mlx-whisper 所在 venv | `~/Desktop/yt_XUynngoQQto/venv_mlx` |
| `YT_POT_SERVER` | bgutil provider 的 server 目录 | `~/bgutil-ytdlp-pot-provider/.../server` |
| `YT_PY` | 跑 yt-dlp 的 Python（需 ≥3.10） | `~/.local/bin/python3.11` |
| `YT_FFMPEG` | ffmpeg 路径 | `~/Desktop/yt_XUynngoQQto/bin/ffmpeg` |
| `YT_ASR_PROMPT` | 转写提示词，**按视频领域改** | 香港小一入学相关词汇 |

提示词对专有名词帮助很大。换领域时照着这个格式写：

```bash
export YT_ASR_PROMPT="以下是……的粵語分享，內容關於……、……、……。"
```

---

## 样例

[`examples/heep-yunn-2023-24/`](examples/heep-yunn-2023-24/) 是完整跑通的样例：香港協恩小學 2023/24 小一入学讲座（37 分钟粤语，家长 Q&A 分 8 大类）。

含四份文件：繁体原始转写、简体文字稿（Markdown + 纯文本）、要点摘要。

可以从中看到这份管线的真实产出——包括 13 处专有名词订正（協音／協定／協議 → 協恩）和 16 处标为〔听不清〕的存疑点。**不确定的地方就是标出来，不编。**

---

## 说明

- 模型 `mlx-community/whisper-large-v3-mlx` 首次运行自动下载（约 2.9 GB），之后离线可用。
- 本项目只处理你有权访问的公开视频。
- 转写质量取决于音频本身：现场讲座（有掌声、嘈杂、多人抢话）比录音室内容差。
- 版权：脚本产出的是转录与摘要，请自行确认使用范围。

---

## English summary

A Claude Code Skill that turns subtitle-less YouTube videos (especially Cantonese) into polished Simplified Chinese transcripts plus key-point summaries.

Handles the two hard parts that make this non-trivial: **downloading** audio from YouTube in 2026 (needs a PO-token provider, `VISITOR_DATA`, `player_skip=webpage`, and a JS runtime) and **transcribing** Cantonese correctly (PyTorch's MPS backend silently hallucinates — `mlx-whisper` is the fix; language detection must be done per-chunk, not once globally).

The human step still matters: Cantonese proper nouns get mangled (協恩 → 協音/協定/協議), so the Skill includes a homophone reference table and a delivery spec that requires marking unclear audio rather than guessing.

See `examples/` for a full worked output.
