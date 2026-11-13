"""探针质量门禁：判断转写是否退化成重复幻觉。

用法: python3 check_probe.py probe_raw.json
退出码 0 = 正常，1 = 疑似幻觉（应改用 CPU 版 PyTorch whisper）
"""

import collections
import json
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "probe_raw.json"
segs = json.load(open(path)).get("segments", [])
text = " ".join(s["text"] for s in segs)
toks = re.findall(r"[a-z']+", text.lower())

if len(toks) < 30:
    print(f"FAIL 探针文本太短（{len(toks)} 词），无法判定")
    sys.exit(1)

uniq_ratio = len(set(toks)) / len(toks)

tri = collections.Counter(tuple(toks[i:i + 3]) for i in range(len(toks) - 2))
bi = collections.Counter(tuple(toks[i:i + 2]) for i in range(len(toks) - 1))
max_tri = tri.most_common(1)[0]
max_bi = bi.most_common(1)[0]

print(f"词数={len(toks)}  去重比={uniq_ratio:.3f}")
print(f"最高频 3-gram: {max_tri[0]} x{max_tri[1]}")
print(f"最高频 2-gram: {max_bi[0]} x{max_bi[1]}")
print(f"样例: {text[:400]}")

degenerate = (
    max_tri[1] >= 8
    or max_bi[1] >= 15
    or (uniq_ratio < 0.30 and len(toks) > 80)
)
if degenerate:
    print("FAIL 疑似重复幻觉")
    sys.exit(1)
print("PASS 输出看起来正常")
sys.exit(0)
