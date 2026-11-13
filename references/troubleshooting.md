# 排障速查

按「症状 → 原因 → 处理」组织。全部来自 2026-11-13 处理《Heep Yunn School Admission Talk》时的实测。

---

## A. 转写结果退化

### A1. 输出是 `we would we would we would...` 这类自旋重复

**原因**：PyTorch 的 MPS 后端跑 whisper 有数值缺陷。**不是音频坏了**——用 ffmpeg 体检（`volumedetect`）确认音频正常：mean −32.8 dB、max −9.9 dB、394 处句间静音，各 5 分钟窗口响度均匀。

**处理**：改用 mlx-whisper。`~/.local/share/yt-transcript/venv_mlx/bin/python -c "import mlx_whisper"` 确认装好，模型 `mlx-community/whisper-large-v3-mlx`。

### A2. 某一块开始重复（如「他家族好多人」×20）

**原因**：两个原因可能叠加——(a) `condition_on_previous_text=True` 让上下文自旋；(b) 并行跑多个实例导致 GPU/内存争抢，解码退化。

**处理**：`asr_mlx.py` 已设 `condition_on_previous_text=False` + `temperature=(0.0,0.2,...,1.0)` 自动升温重试。同时**确认只有一个实例在跑**。

### A3. 转写跳过了开头/结尾一大段

**原因**：whisper 的 `no_speech_threshold` 把片头音乐判成静音。若音频该段确实有人说话，就是漏转。

**处理**：用 ffmpeg 单独量该段响度确认。`volumedetect` 显示有声但没转出来时，把 `no_speech_threshold` 调低重跑该块。

### A4. 中英夹杂的段落整段转错

**原因**：whisper 全局只做一次语言检测，整段锁定一种语言。

**处理**：`asr_mlx.py` 已按 5 分钟分块逐块检测。块太大（>10 分钟）时可调小 `--chunk`。

---

## B. 下载失败

### B1. `TypeError: debug() got an unexpected keyword argument 'once'`

**原因**：bgutil 插件 2.0.2 调用 `logger.debug(msg, once=True)`，而旧版 yt-dlp 的 `IEContentProviderLogger.debug(self, message)` 没有这个参数。

**处理**：升级 yt-dlp 到 2026.10.26+。注意 **yt-dlp 2026 要求 Python ≥ 3.10**，系统 python3.9 不行，用 `~/.local/bin/python3.11`。

### B2. `Requested format is not available` / `Only images are available`

**原因**：嵌在网页里的 player response 里 `url`/`signatureCipher` 是空的。

**处理**：加 `player_skip=webpage` 强制走 player API。

### B3. `WARNING: No supported JavaScript runtime could be found. Only deno is enabled by default`

**原因**：yt-dlp 2026 解挑战需要 JS 运行时。

**处理**：加 `--js-runtimes node`。**连 `--list-subs` 也要加**，否则字幕轨可能识别不全。

### B4. PO token 日志显示拿到了，但仍然没有任何格式

**原因**：token 与请求的 visitor 不匹配。

**处理**：三件套必须配套——全新匿名 cookie jar + 从 **同一份 watch.html** 取出的 `VISITOR_DATA` + `--js-runtimes node`。

### B5. `VISITOR_DATA` 取到了但没效果

**原因**：取错了字段。

**处理**：从 watch 页正则 `"VISITOR_DATA":"([^"]+)"` 取。它是 **base64 的 ytcfg 字段**，不是 `VISITOR_INFO1_LIVE` cookie。后者要放在 cookie jar 里，两者不能互换、也不能只用一个。

### B6. `android_vr` 403

**原因**：bgutil provider 的 `_SUPPORTED_CLIENTS = WEBPO_CLIENTS`，不含 android_vr。

**处理**：只用 web/mweb/tv 系。

### B7. `FileNotFoundError: 'deno'`

**原因**：插件在枚举 JS provider 时找不到 deno。

**处理**：**无害**，可以忽略，不是真正的阻塞点。

### B8. 视频有会员/付费/限龄/地区限制

**原因**：不属于匿名抓取能解决的范畴。

**处理**：需要另外的手段，且要先跟用户确认是否有权访问。

---

## C. 环境与脚本

### C1. `NotImplementedError: aten::_sparse_coo_tensor_with_dims_and_tensors ... SparseMPS`

**原因**：whisper 把 `alignment_heads` 注册成稀疏 COO buffer（`whisper/model.py`），torch 2.8 的 SparseMPS 后端不支持。

**处理**：搬设备前转 dense——`model.alignment_heads = model.alignment_heads.to_dense()`。该 buffer 只服务逐词时间戳，不参与常规推理。**走 MLX 路线就不需要这一步。**

### C2. `FileNotFoundError: 'ffmpeg'`（来自 `whisper/audio.py: load_audio`）

**原因**：`load_audio()` 对字符串输入会 fork 外部 ffmpeg 进程。

**处理**：直接用 Python `wave` 模块读 16 kHz/单声道/PCM16 的 wav 成 float32 numpy 数组传给 `transcribe()`。`asr_mlx.py` 已这么做，**完全不依赖 ffmpeg**（ffmpeg 只在下载后转 wav 时需要）。

### C3. macOS 自带 bash 是 3.2

**症状**：`local a=1 b=2` 这类一行多赋值会把 `$b` 当成 `local` 的变量名报 `unbound variable`——因为 bash 会先展开整行的所有词。

**处理**：拆成多行 `local`。

### C4. 分类器拦截「安装并执行刚下载的外部包」

**现象**：`pip install` 后执行、或直接跑 `yt_dlp` 带插件的下载命令时被拒。

**处理**：把完整命令写出来交给用户执行（用户在自己的会话里运行，命令对他们完全可见）。不要反复自行重试，也不要试图改写命令形态来绕过。

### C5. 分类器拦截 `kill`

**现象**：`kill <pid>` 被拒。

**处理**：把 `kill` 命令交给用户执行。另外注意：**进程处于 `U` 状态（内核不可中断等待）时，SIGTERM 送不进去**，需要 `kill -9`；但 `U` 状态下 `SIGKILL` 同样要等它回到用户态才生效。

### C6. 内存吃穿、swap 飙高

**现象**：`sysctl vm.swapusage` 显示用了 15 GB，进程状态是 `U`，解码速度掉到 50 frames/s。

**原因**：多个 whisper 实例各占约 3 GB。

**处理**：只跑一个实例；跑之前 `sysctl vm.swapusage` 看一眼基线；结束后确认没有残留进程。

---

## D. 常用体检命令

```bash
# 音频响度（判断音频是否真的有声）
./bin/ffmpeg -hide_banner -nostats -i audio16k.wav -af volumedetect -f null - 2>&1 | grep -E "mean_volume|max_volume"

# 句间静音（判断是不是语音为主）
./bin/ffmpeg -hide_banner -i audio16k.wav -af silencedetect -f null - 2>&1 | grep silence | wc -l

# 模型离线可用性
HF_HUB_OFFLINE=1 venv_mlx/bin/python -c \
  "from huggingface_hub import snapshot_download; print(snapshot_download('mlx-community/whisper-large-v3-mlx', local_files_only=True))"

# 视频标题与时长
grep -oE '"title": *"[^"]+"' fmt.log | head -1
grep -oE '"lengthSeconds":"[0-9]+"' watch.html
```
