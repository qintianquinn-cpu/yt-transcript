---
name: yt-transcript
description: 把 YouTube 视频（尤其是无字幕的粤语/中文视频）转写并整理成简体中文文字稿与要点摘要。当用户给出 YouTube 链接并希望提取音频、生成字幕/文字稿、把讲座/采访/课程录音转成笔记，或要求翻译转录内容时使用。流程覆盖字幕轨检查、音频下载（yt-dlp + bgutil PO token）、Whisper large-v3（Apple MLX）分块转写、繁简转换与粤语书面化、以及专有名词人工订正。不负责视频剪辑、把字幕压制回视频文件、批量分发，或非 YouTube 平台的音视频抓取。
---

# YouTube 视频转简体文字稿

把一条 YouTube 视频变成可交付的简体中文文字稿。流程是顺序的，不要拆成并行分支；ASR 跑完前不要开始写稿。

## 核心约束（先读，避免重蹈覆辙）

1. **禁用 PyTorch MPS 跑 whisper。** MPS 后端会数值退化，输出 `we would we would we would...` 这类自旋重复幻觉，看起来像音频坏了，其实音频是好的。改用 **mlx-whisper**（Apple Silicon 原生，正确且快）。
2. **不要并行开多个转写实例。** 两个 whisper 各加载一份 large-v3 权重 ≈ 6 GB，会把内存吃穿、swap 飙到 15 GB，解码速度从 200 frames/s 掉到 50，37 分钟音频跑了 44 分钟。**一次只跑一个。**
3. **Whisper 全局只做一次语言检测。** 粤语夹英文的香港讲座，整段锁定一种语言会把另一种语言的段落整体转错。**必须分块（5 分钟一块）逐块检测语言**，`scripts/asr_mlx.py` 已实现。
4. **不能臆造。** 转写里听不清、被 ASR 听错的地方，标〔听不清〕或列入「订正记录」，不要靠语意脑补填空。专有名词尤其危险：一次实测中「協恩」被听成 **協音 / 協定 / 協議** 三种。
5. **本流程会下载并运行外部代码**（yt-dlp 插件、bgutil POT provider、mlx-whisper 模型）。执行前把要跑的命令完整写出来给用户看，按会话的正常权限确认流程走。

## 环境自检

首次使用或报错时执行：

```bash
[ -x ~/Desktop/yt_XUynngoQQto/venv_mlx/bin/python ] && \
  ~/Desktop/yt_XUynngoQQto/venv_mlx/bin/python -c "import mlx_whisper; print('mlx_whisper', mlx_whisper.__version__)"
~/.local/bin/python3.11 -m yt_dlp --version
ls ~/bgutil-ytdlp-pot-provider/repo/bgutil-ytdlp-pot-provider-2.0.2/server/build/main.js
```

模型 `mlx-community/whisper-large-v3-mlx`（约 2.9 GB）已缓存在 `~/.cache/huggingface/hub/`，正常情况下**新视频不用重新下载**。用 `HF_HUB_OFFLINE=1` 可以验证离线可用。

## 执行流程

### Step 0 · 判断有没有字幕轨（必做，能省 40 分钟）

```bash
~/.local/bin/python3.11 -m yt_dlp --js-runtimes node --list-subs "<URL>"
```

- **有「人工字幕」** → 直接抓，最准，不用跑 ASR：
  ```bash
  ~/.local/bin/python3.11 -m yt_dlp --js-runtimes node --skip-download \
    --write-subs --sub-langs "zh-Hant,zh-HK,zh,en" --sub-format "vtt/srt/best" \
    -o "%(title)s.%(ext)s" "<URL>"
  ```
- **只有「自动字幕」** → 也抓一份，与 ASR 结果交叉核对（自动字幕对粤语同音字错得厉害：唔/係/唔该 常被听错）。
- **完全没有** → 走 ASR（本次就是这个情况）。

### Step 1 · 一键管线（推荐）

`scripts/yt2md.sh` 把「查字幕 → 下载音频 → 转 wav → 转写 → 转简体」串起来了：

```
bash ~/.claude/skills/yt-transcript/scripts/yt2md.sh "<URL>"
```

它会扫 `player_client × player_skip` 组合找到能拿到音频的那一组，产出 `_繁体转写.txt / .json` 与 `_简体.txt`。

**下载环节的关键配方**（`yt2md.sh` 已实现，改动前先读 `references/troubleshooting.md`）：

- yt-dlp 必须用 **python3.11** 环境（2026 版要求 Python ≥ 3.10）
- 必须挂 **bgutil PO token provider**：`--extractor-args "youtubepot-bgutilscript:server_home=$SERVER"`
- 必须 `--js-runtimes node`
- 必须新建**匿名** cookie jar，并从 watch 页取 ytcfg 的 `VISITOR_DATA` 一起传：`--extractor-args "youtube:player_client=mweb;player_skip=webpage;visitor_data=$VD"`
  - `VISITOR_DATA` 是 base64 的 ytcfg 字段，**不是** `VISITOR_INFO1_LIVE` cookie，两者不能互换
- `player_skip=webpage` 强制走 player API，绕开嵌入播放页那个空的 `url`/`signatureCipher`

### Step 2 · 分块转写

```bash
cd <workdir>
YT_ASR_PROMPT="以下是……的粵語分享，內容關於……" \
  ~/Desktop/yt_XUynngoQQto/venv_mlx/bin/python \
  ~/.claude/skills/yt-transcript/scripts/asr_mlx.py \
  --src audio16k.wav --out transcript_raw
```

- `YT_ASR_PROMPT` 按视频领域改，**对专有名词帮助很大**（校名、术语、人名）
- 输入必须是 **16 kHz / 单声道 / PCM16** 的 wav
- 跑之前先跑 180 秒探针，再用 `scripts/check_probe.py` 检查有没有重复幻觉
- 时长参考：无争用时约 2.5 倍实时

### Step 3 · 繁简与书面语

```bash
~/Desktop/yt_XUynngoQQto/venv_mlx/bin/python \
  ~/.claude/skills/yt-transcript/scripts/convert.py transcript_raw.json > transcript_simp.txt
```

`convert.py` 做 OpenCC 繁→简 + 粤语口语→书面语（係→是、嘅→的、咗→了…）。**这一步只是初稿**，见 Step 4。

### Step 4 · 人工订正（这一步是核心产出，不能省）

逐段通读 `transcript_simp.txt`，做三件事：

1. **修专有名词**：校名、人名、机构名、术语、代号。香港场景高频错法见 `references/hk-homophones.md`。
2. **把粤语口语改成通顺书面语**：不只是转换字，还要重写句子（「女女」→「小朋友」、「我都就著申請」→「接着我就着申请补充几点」）。
3. **标出听不清的地方**：确实听不出的用〔听不清〕，不要编。

同时维护两份清单，最后写进交付物：
- **订正记录表**：原文 → 改正 → 依据
- **存疑处清单**：时间码 + 原句 + 为什么不确认

### Step 5 · 交付

产出三份（详见 `references/delivery.md`）：

- `<标题>_简体文字稿.md` —— 分节、带时间戳、附订正记录与存疑清单
- `<标题>_简体文字稿.txt` —— 纯文本版
- `<标题>_要点摘要.md` —— 关键数字表、按问题/主题分类的要点、行动清单（如有截止日期）、制度背景补充（须标注非视频内容）

文件名用视频标题，不要用 URL 里的随机 ID。

## 表达原则

- 讲**已经确定的事实**和**仍需人工确认的部分**，分开说。
- 日期、比例、金额这类硬数字，原样保留并注明出处（哪个时间码）。
- 如果视频录于往年，在文件顶部明确写「以下日期为当年原始安排，不可直接套用于今年」。
- 补充视频之外的通用知识时，单独成节并标注「非视频内容」，不要和视频观点混在一起。
- 用户可以自己读原始转写；交付物要做的是让人**读得下去**，不是逐字复述 ASR 输出。

## 排障

遇到报错、下载失败、输出退化，读 `references/troubleshooting.md`（含实测到的全部坑：MPS 幻觉、swap 争用、PO token 失效、`VISITOR_DATA` 取错位置、`player_skip` 缺失、ffmpeg 依赖等）。

## 脚本清单

| 路径 | 作用 |
|---|---|
| `scripts/yt2md.sh` | 一键管线（字幕检查 → 下载 → 转码 → 转写 → 转简体） |
| `scripts/asr_mlx.py` | mlx-whisper 分块转写，支持 `YT_ASR_PROMPT` |
| `scripts/convert.py` | 繁→简 + 粤语口语书面化 |
| `scripts/check_probe.py` | 重复幻觉检测（退出码 0 = 正常） |
