#!/bin/bash
# ===========================================================================
# YouTube 视频 -> 繁体转写 -> 简体译稿
#
# 用法:
#   bash yt2md.sh <视频URL> [输出目录]
#
# 流程:
#   1. 先查该视频有没有字幕轨
#      - 有「人工字幕」-> 直接抓（最准，不用跑 ASR）
#      - 只有「自动字幕」-> 也抓一份，供与 ASR 结果交叉核对
#   2. 没有字幕 -> 下载音频（yt-dlp 2026 + bgutil PO token）
#   3. ffmpeg 转 16kHz/单声道/PCM16
#   4. mlx-whisper large-v3 分块转写（每块独立检测语言，防中英夹杂出错）
#   5. OpenCC 繁->简 + 粤语口语书面化
#
# 产出:
#   <目录>/<标题>_繁体转写.txt     时间戳 [mm:ss] 文本
#   <目录>/<标题>_繁体转写.json
#   <目录>/<标题>_简体.txt          简体书面语
#   <目录>/<标题>_字幕原文.vtt/.srt  （若视频自带字幕）
# ===========================================================================
set -uo pipefail

URL="${1:?用法: bash yt2md.sh <视频URL> [输出目录]}"
OUTDIR="${2:-$HOME/Desktop/yt_$(date +%Y%m%d_%H%M)}"
WORK="$OUTDIR/work"

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${YT_PY:-$HOME/.local/bin/python3.11}"
VENV="${YT_VENV:-$HOME/.local/share/yt-transcript/venv_mlx}"
SERVER="${YT_POT_SERVER:-$HOME/bgutil-ytdlp-pot-provider/repo/bgutil-ytdlp-pot-provider-2.0.2/server}"
FFMPEG="${YT_FFMPEG:-$HOME/.local/share/yt-transcript/bin/ffmpeg}"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg || echo ffmpeg)"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

for _req in "$PY" "$VENV/bin/python" "$FFMPEG"; do
  [ -x "$_req" ] || { echo "!! 缺少可执行文件: $_req"; exit 1; }
done

mkdir -p "$WORK" "$OUTDIR"
cd "$WORK"

echo "==> 输出目录: $OUTDIR"

# ---------------------------------------------------------------- 1. 字幕轨
echo "==> 1/5 检查字幕轨"
"$PY" -m yt_dlp --js-runtimes node --list-subs "$URL" 2>&1 | tee subs_list.txt | tail -25
HAS_MANUAL=0
HAS_AUTO=0
grep -qE "^zh-Hant.*\[[0-9]+" subs_list.txt && HAS_MANUAL=1
grep -qE "\(auto\)|auto-generated" subs_list.txt && HAS_AUTO=1
echo "    人工字幕: $HAS_MANUAL   自动字幕: $HAS_AUTO"

# 抓字幕（人工优先）
SUB_LANG=""
if [ "$HAS_MANUAL" = 1 ]; then
  SUB_LANG="zh-Hant,zh-HK,zh,en"
elif [ "$HAS_AUTO" = 1 ]; then
  SUB_LANG="zh-Hant,zh-HK,zh,en"
fi
if [ -n "$SUB_LANG" ]; then
  echo "    下载字幕 ($SUB_LANG)..."
  "$PY" -m yt_dlp --js-runtimes node --skip-download --write-subs --write-auto-subs \
    --sub-langs "$SUB_LANG" --sub-format "vtt/srt/best" \
    -o "%(title)s.%(ext)s" "$URL" 2>&1 | tail -5
fi

# ---------------------------------------------------------------- 2. 音频
echo "==> 2/5 下载音频"
curl -s --max-time 30 -c cookies.txt -A "$UA" "$URL" -o watch.html
VD=$("$PY" -c "
import re
h = open('watch.html', encoding='utf-8', errors='ignore').read()
m = re.search(r'\"VISITOR_DATA\":\"([^\"]+)\"', h)
print(m.group(1) if m else '')
")
[ -z "$VD" ] && { echo "!! 没取到 VISITOR_DATA"; exit 1; }

# 扫 client x player_skip，命中最快的组合
FOUND=""
for c in mweb web web_creator tv web_safari web_embedded; do
  for s in "player_skip=webpage" "player_skip=js" ""; do
    ARGS="youtube:player_client=$c"
    [ -n "$s" ] && ARGS="$ARGS;$s"
    ARGS="$ARGS;visitor_data=$VD"
    # shellcheck disable=SC2086
    "$PY" -m yt_dlp --js-runtimes node --cookies cookies.txt \
      --extractor-args "youtubepot-bgutilscript:server_home=$SERVER" \
      --extractor-args "$ARGS" -F "$URL" > fmt.log 2>&1
    if grep -q 'audio only' fmt.log; then
      FOUND="$c|$s"; break 2
    fi
  done
done
[ -z "$FOUND" ] && { echo "!! 所有 client 组合都拿不到音频"; exit 1; }
C="${FOUND%%|*}"; S="${FOUND##*|}"
echo "    命中 client=$C  ${S:-（不跳过）}"

ARGS="youtube:player_client=$C"
[ -n "$S" ] && ARGS="$ARGS;$S"
ARGS="$ARGS;visitor_data=$VD"
# shellcheck disable=SC2086
"$PY" -m yt_dlp --js-runtimes node --cookies cookies.txt \
  --extractor-args "youtubepot-bgutilscript:server_home=$SERVER" \
  --extractor-args "$ARGS" \
  -f "bestaudio[ext=m4a]/bestaudio" -o "audio.%(ext)s" "$URL" 2>&1 | tail -4

AUDIO=$(ls audio.* 2>/dev/null | head -1)
[ -z "$AUDIO" ] && { echo "!! 音频下载失败"; exit 1; }
echo "    音频: $AUDIO ($(du -h "$AUDIO" | cut -f1))"

# ---------------------------------------------------------------- 3. 转 wav
echo "==> 3/5 转 16kHz 单声道 wav"
"$FFMPEG" -y -i "$AUDIO" -ar 16000 -ac 1 -c:a pcm_s16le audio16k.wav 2>&1 | tail -2
DUR=$("$FFMPEG" -i audio16k.wav 2>&1 | grep Duration | awk '{print $2}' | tr -d ,)
echo "    时长 $DUR"

# ---------------------------------------------------------------- 4. 转写
echo "==> 4/5 mlx-whisper 转写（首次运行模型已缓存，无需下载）"
cd "$WORK"
PROMPT_ARG=""
[ -n "${2:-}" ] && PROMPT_ARG=""
"$VENV/bin/python" "$SKILL_DIR/scripts/asr_mlx.py" \
  --src audio16k.wav --out transcript_raw 2>&1 | grep -vE "^(Downloading|Fetching)|frames/s" | tail -20

# ---------------------------------------------------------------- 5. 转简体
echo "==> 5/5 繁->简 + 粤语书面化"
"$VENV/bin/python" "$SKILL_DIR/scripts/convert.py" transcript_raw.json > transcript_simp.txt

# ---------------------------------------------------------------- 归档
TITLE=$(grep -oE '"title": *"[^"]+"' fmt.log 2>/dev/null | head -1 | sed 's/.*"title": *"//;s/"$//')
[ -z "$TITLE" ] && TITLE="video_$(basename "$URL" | cut -d= -f2 | cut -c1-11)"
SAFE=$(echo "$TITLE" | tr '/:' '_' | tr -d '"' | cut -c1-60)

cp transcript_raw.txt "$OUTDIR/${SAFE}_繁体转写.txt"
cp transcript_raw.json "$OUTDIR/${SAFE}_繁体转写.json"
cp transcript_simp.txt "$OUTDIR/${SAFE}_简体.txt"
cp *.vtt "$OUTDIR/" 2>/dev/null
cp *.srt "$OUTDIR/" 2>/dev/null

echo
echo "==> 完成"
ls -lh "$OUTDIR" | tail -10
echo
echo "下一步: 把「${SAFE}_繁体转写.txt」给我，我做人工订正（专有名词/同音错字）"
echo "        + 粤语口语书面化 + 要点摘要，输出最终简体译稿。"
