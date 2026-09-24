#!/bin/zsh
# 把 pubspec.yaml 的构建号 +1：0.1.0+1 → 0.1.0+2。
#
#   zsh tool/ota/bump_version.sh [pubspec路径]
#
# 出包前跑一下，手机上就能看出装的是不是新包（iOS 用「短版本 + 构建号」
# 判断新旧，短版本不变、构建号不变的话，装完你分不清装的是哪一版）。
set -e

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PUBSPEC="${1:-$ROOT/pubspec.yaml}"
[ -f "$PUBSPEC" ] || { echo "找不到 $PUBSPEC"; exit 1; }

python3 - "$PUBSPEC" <<'PY'
import re, sys

path = sys.argv[1]
src = open(path, encoding='utf-8').read()
# 用 [ \t] 而不是 \s 收尾：\s 会把行尾的换行（连后面的空行）一起吃掉，
# 改完版本号顺带把文件里的一行空行删了，diff 里就莫名其妙多出一行改动。
m = re.search(r'^version:[ \t]*(\d+\.\d+\.\d+)(?:\+(\d+))?[ \t]*$', src, re.M)
if not m:
    print('pubspec.yaml 里的 version 不是 x.y.z 或 x.y.z+N 的形式，没动它')
    sys.exit(1)
old = m.group(0)
new = f"version: {m.group(1)}+{int(m.group(2) or 0) + 1}"
open(path, 'w', encoding='utf-8').write(src.replace(old, new, 1))
print(f"{old.strip()}  →  {new}")
PY
