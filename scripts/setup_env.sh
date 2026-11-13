#!/bin/bash
# ===========================================================================
# 环境准备：mlx-whisper（转写）+ bgutil-ytdlp-pot-provider（下载 PO token）
#
# 用法:
#   bash scripts/setup_env.sh
#
# 做四件事：
#   1. 找一个 Python >= 3.10（yt-dlp 2026 要求；系统自带的 3.9 不行）
#   2. 建 venv 并装 mlx-whisper（Apple Silicon 专用转写后端）
#   3. 克隆并编译官方 bgutil PO token provider（Node）
#   4. 打印需要 export 的环境变量
#
# 注意：本脚本会从网络下载并安装软件包。执行前请确认你同意这些来源。
# ===========================================================================
set -uo pipefail

VENV="${YT_VENV:-$HOME/Desktop/yt_XUynngoQQto/venv_mlx}"
POT_DIR="${YT_POT_DIR:-$HOME/bgutil-ytdlp-pot-provider}"
POT_REPO="https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git"

echo "==> 1/4 找 Python >= 3.10"
PY=""
for c in "$HOME/.local/bin/python3.13" "$HOME/.local/bin/python3.12" \
         "$HOME/.local/bin/python3.11" python3.13 python3.12 python3.11 python3; do
  command -v "$c" >/dev/null 2>&1 || continue
  if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
    PY="$(command -v "$c")"; break
  fi
done
[ -z "$PY" ] && { echo "!! 找不到 Python >= 3.10"; exit 1; }
echo "    $PY ($("$PY" -V 2>&1))"

echo
echo "==> 2/4 建 venv 并装 mlx-whisper"
if [ ! -x "$VENV/bin/python" ]; then
  "$PY" -m venv "$VENV" || { echo "!! venv 创建失败"; exit 1; }
fi
"$VENV/bin/python" -m pip install -q --upgrade pip
if ! "$VENV/bin/python" -c "import mlx_whisper" 2>/dev/null; then
  echo "    安装 mlx-whisper（约几分钟）..."
  "$VENV/bin/python" -m pip install -q mlx-whisper || { echo "!! 安装失败"; exit 1; }
fi
"$VENV/bin/python" -c "import mlx_whisper; print('    mlx_whisper', mlx_whisper.__version__)"

echo
echo "==> 3/4 准备 bgutil PO token provider"
if [ ! -d "$POT_DIR/.git" ]; then
  git clone --depth 1 "$POT_REPO" "$POT_DIR" || { echo "!! clone 失败"; exit 1; }
fi
POT_SERVER=$(find "$POT_DIR" -maxdepth 3 -type d -name server | head -1)
[ -z "$POT_SERVER" ] && { echo "!! 找不到 server 目录"; exit 1; }
if [ ! -f "$POT_SERVER/build/main.js" ]; then
  echo "    编译 server（npm ci + tsc，约 1-2 分钟）..."
  (cd "$POT_SERVER" && npm ci --silent && npx tsc) || { echo "!! 编译失败"; exit 1; }
fi
echo "    $POT_SERVER"

echo
echo "==> 4/4 完成。把这几行加进 ~/.zshrc："
cat <<EOF

# --- yt-transcript skill ---
export YT_VENV="$VENV"
export YT_POT_SERVER="$POT_SERVER"
export YT_PY="$PY"
EOF

echo
echo "模型会在第一次转写时自动下载（约 2.9 GB），之后离线可用。"
