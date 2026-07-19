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

# ======= 修改点：同名包去重，只保留最新版本（ipk 版）=======
# - 包名切分：先剥离已知 arch 后缀，再取剩余部分最后一个 "_" 前的内容作为包名，
#   避免包名自带数字/连字符时被误切（如 i18n-zh-cn、lib_ffi）。
# - 按 (包名, arch) 分组比较，避免不同架构互相误删。
# - 用 pkgver 版本号（sort -V）判断新旧，不用 mtime：cp 不带 -p 时 mtime 只反映
#   脚本里谁被复制得更晚，跟包的真实新旧无关。
# - sort -V 只比较纯版本号字段，不掺杂文件名/arch/扩展名，避免类似
#   3.0.13 vs 3.0.13-2 这种 release 后缀被字符边界干扰导致误判。
ARCH_LIST="x86_64 all"   # 按需修改为实际平台架构 + all（架构无关的luci包）
echo "🔧 正在对 $TARGET_DIR 中的同名包去重（arch 列表: $ARCH_LIST），保留最新版本..."
cd "$TARGET_DIR"
if ! ls *.ipk >/dev/null 2>&1; then
    echo "⚠️ 未找到任何 ipk 文件，跳过去重"
    cd - >/dev/null
    exit 0
fi
for TARGET_ARCH in $ARCH_LIST; do
    pkgnames=$(for f in *.ipk; do
        base="${f%.ipk}"
        nv="${base%_${TARGET_ARCH}}"
        [ "$nv" = "$base" ] && continue
        echo "${nv%_*}"
    done | sort -u)
    [ -z "$pkgnames" ] && continue
    printf '%s\n' "$pkgnames" | while IFS= read -r pkgname; do
        [ -z "$pkgname" ] && continue
        recs=$(for f in *.ipk; do
            base="${f%.ipk}"
            nv="${base%_${TARGET_ARCH}}"
            [ "$nv" = "$base" ] && continue
            pn="${nv%_*}"
            [ "$pn" = "$pkgname" ] || continue
            ver="${nv#${pn}_}"
            printf '%s\t%s\n' "$ver" "$f"
        done)
        count=$(printf '%s\n' "$recs" | grep -c .)
        if [ "$count" -gt 1 ]; then
            keep=$(printf '%s\n' "$recs" | sort -t"$(printf '\t')" -k1,1V | tail -n1 | cut -f2)
            printf '%s\n' "$recs" | cut -f2 | grep -v -F -x "$keep" | xargs -r rm -f --
            echo "🗑️ 已删除 $pkgname($TARGET_ARCH) 旧版本，保留: $keep"
        fi
    done
done
cd - > /dev/null
# ======= 修改点结束 =======

echo "✅ 所有 .ipk 文件已整理至 $TARGET_DIR/"
