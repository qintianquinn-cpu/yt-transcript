"""用 Apple MLX 版 Whisper 转写（替代 PyTorch MPS 版）。

为什么换 MLX：PyTorch 的 MPS 后端跑 whisper large-v3 会产生数值退化，
输出成 "we would we would we would..." 这类重复幻觉（已实测）。MLX 是 Apple
针对 M 芯片的优化实现，数值路径正确且明显更快。

为什么要分块：香港学校讲座常见中英夹杂。whisper 全局只做一次语言检测，
整段锁定语言会把另一种语言的段落全部转错。这里按 5 分钟分块，每块独立
自动检测语言后再转写，时间戳平移回全局时间轴。

输出:
    <out>.json   完整分段（含 start/end/text/lang）
    <out>.txt    [mm:ss] 文本 每行一段
"""

import argparse
import json
import os
import shutil
import time
import wave

import numpy as np

# ffmpeg 只是兜底（本脚本直接用 wave 读 PCM16 wav，不 fork 外部进程）。
# 找不到也不影响运行。
for _d in (os.environ.get("YT_FFMPEG_DIR", ""),
           os.path.expanduser("~/.local/share/yt-transcript/bin"),
           "/opt/homebrew/bin", "/usr/local/bin"):
    if _d and os.path.isdir(_d):
        os.environ["PATH"] = _d + os.pathsep + os.environ.get("PATH", "")
        break
if shutil.which("ffmpeg") is None:
    print("提示: 未找到 ffmpeg（不影响本脚本，直接读 wav）", flush=True)

SR = 16000
MODEL = "mlx-community/whisper-large-v3-mlx"

# 提示词：把领域词汇喂给解码器，显著提高专有名词准确率
# （学额/叩门/派位/tsl、STS、banding 等 whisper 默认听不出来）
# 用 YT_ASR_PROMPT 环境变量覆盖，换视频时按领域改。
DEFAULT_PROMPT = ("以下是香港小學一年級入學家長會的粵語分享，"
                  "內容關於小一入學、學額、扣分、派位、面試、"
                  "資助小學、津校、直資校、私立校、叩門、"
                  "tsl、sts、學位分配、校車、課外活動。")
PROMPT = os.environ.get("YT_ASR_PROMPT", DEFAULT_PROMPT)


def transcribe_chunk(chunk, model, prompt):
    """转写一个音频块。

    condition_on_previous_text=False：切断块间的上下文串联，
    这是 whisper 陷入「他家族好多人」这类自旋重复的主因。
    temperature 用元组，压缩率/置信度不达标时会自动升温重试。
    """
    import mlx_whisper

    return mlx_whisper.transcribe(
        chunk,
        path_or_hf_repo=model,
        language=None,
        verbose=False,
        temperature=(0.0, 0.2, 0.4, 0.6, 0.8, 1.0),
        compression_ratio_threshold=2.4,
        logprob_threshold=-1.0,
        condition_on_previous_text=False,
        initial_prompt=prompt,
    )


def load_wav_16k(path):
    with wave.open(path, "rb") as w:
        if (w.getnchannels(), w.getframerate(), w.getsampwidth()) != (1, SR, 2):
            raise ValueError("需要 16kHz/单声道/16bit")
        frames = w.readframes(w.getnframes())
    return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", type=float, default=0, help=">0 只处理前 N 秒")
    ap.add_argument("--src", default="audio16k.wav")
    ap.add_argument("--chunk", type=float, default=300.0)
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--out", default="transcript_mlx")
    ap.add_argument("--prompt", default=PROMPT)
    args = ap.parse_args()

    import mlx_whisper

    audio = load_wav_16k(args.src)
    total = len(audio) / SR
    limit = min(args.probe, total) if args.probe else total
    print(f"mlx_whisper {getattr(mlx_whisper, '__version__', '?')}  "
          f"音频 {total:.1f}s  本次处理 {limit:.1f}s", flush=True)

    t0 = time.time()
    segs = []
    pos = 0.0
    while pos < limit:
        end = min(pos + args.chunk, limit)
        chunk = audio[int(pos * SR):int(end * SR)]
        if len(chunk) < SR:
            break
        # 每块独立自动检测语言（language=None）
        r = transcribe_chunk(chunk, args.model, args.prompt)
        lang = r.get("language", "?")
        cs = r.get("segments", [])
        print(f"--- 块 {pos:.0f}-{end:.0f}s  语言={lang}  段数={len(cs)}  "
              f"用时={time.time() - t0:.1f}s", flush=True)
        for s in cs:
            segs.append({
                "start": round(s["start"] + pos, 2),
                "end": round(s["end"] + pos, 2),
                "text": s["text"].strip(),
                "lang": lang,
            })
            m, sec = divmod(int(s["start"] + pos), 60)
            print(f"  [{m:02d}:{sec:02d}] {s['text'].strip()}", flush=True)
        if end >= limit:
            break
        pos = end - 1.0  # 1 秒重叠，避免切断句子

    out = {"segments": segs, "language": None}
    json.dump(out, open(f"{args.out}.json", "w"), ensure_ascii=False, indent=1)
    with open(f"{args.out}.txt", "w", encoding="utf-8") as f:
        for s in segs:
            m, sec = divmod(int(s["start"]), 60)
            f.write(f"[{m:02d}:{sec:02d}] {s['text']}\n")
    print(f"WROTE {args.out}.json / {args.out}.txt  "
          f"({len(segs)} segments in {time.time() - t0:.1f}s)", flush=True)


if __name__ == "__main__":
    main()
