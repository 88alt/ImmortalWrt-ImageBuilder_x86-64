#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 清理旧的目录
rm -rf "$TEMP_DIR" "$TARGET_DIR"
mkdir -p "$TEMP_DIR" "$TARGET_DIR"

# 解压 .run 文件
for run_file in "$BASE_DIR"/*.run; do
    [ -e "$run_file" ] || continue
    echo "🧩 解压 $run_file -> $TEMP_DIR"
    sh "$run_file" --target "$TEMP_DIR" --noexec
done

# 1. 收集 run 解压出的 .ipk 文件
find "$TEMP_DIR" -type f -name "*.ipk" -exec cp -v {} "$TARGET_DIR"/ \;

# 2. 收集 extra-packages/*/ 下的 .ipk 文件（只查一级子目录）

find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.ipk" ! -path "$TEMP_DIR/*" \
  -exec echo "👉 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

# ======= 修改点：同名包去重，只保留最新版本 =======
echo "🔧 正在对 $TARGET_DIR 中的同名包去重，保留最新版本..."
cd "$TARGET_DIR"

# ✏️ 改进1：兜底判断，无ipk文件时提前退出
[ -e *.ipk ] || { echo "⚠️ 未找到任何 ipk 文件，跳过去重"; cd - >/dev/null; exit 0; }

for pkgname in $(ls *.ipk 2>/dev/null | sed 's/_[0-9~].*//' | sort -u); do
    count=$(ls ${pkgname}_*.ipk 2>/dev/null | wc -l)
    if [ "$count" -gt 1 ]; then
        # ✏️ 改进2：xargs加-r参数，空输入时不执行rm
        ls ${pkgname}_*.ipk | sort -V | head -n -1 | xargs -r rm -f
        echo "🗑️ 已删除 $pkgname 旧版本，保留: $(ls ${pkgname}_*.ipk)"
    fi
done
cd - > /dev/null
# ======= 修改点结束 =======

echo "✅ 所有 .ipk 文件已整理至 $TARGET_DIR/"
