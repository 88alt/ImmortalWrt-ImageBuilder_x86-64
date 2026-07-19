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

# 1. 收集 run 解压出的 .apk 文件
find "$TEMP_DIR" -type f -name "*.apk" -exec cp -v {} "$TARGET_DIR"/ \;

# 2. 收集 extra-packages/*/ 下的 .apk 文件（只查一级子目录）

find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.apk" ! -path "$TEMP_DIR/*" \
  -exec echo "👉 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

# ======= 修改点：同名包去重，只保留最新版本（apk 版）=======
# - apk 文件名不带 arch 后缀、分隔符是连字符（如 https-dns-proxy-2023.12.26-r1.apk），
#   与 ipk 命名规则不同，不能照搬 ipk 的切分逻辑；改为直接从包内 .PKGINFO 读取
#   真实的 pkgname/pkgver/arch（tar 遇内部 tar-EOF 会自动停在控制信息段，不会
#   继续解析数据段）。
# - 按 (pkgname, arch) 分组比较，避免不同架构互相误删。
# - 用 pkgver（sort -V，只取纯版本号字段）判断新旧，不用 mtime，原因同 ipk 版。
# - ls/rm 前加 -- 防御包名以 "-" 开头时被误当命令行选项解析。
echo "🔧 正在对 $TARGET_DIR 中的同名包去重（apk），保留最新版本..."
cd "$TARGET_DIR"
if ! ls -- *.apk >/dev/null 2>&1; then
    echo "⚠️ 未找到任何 apk 文件，跳过去重"
    cd - >/dev/null
    exit 0
fi
index=$(for f in *.apk; do
    info=$(tar -xzf "$f" -O .PKGINFO 2>/dev/null)
    if [ -z "$info" ]; then
        echo "⚠️ 跳过无法解析元数据的包: $f" >&2
        continue
    fi
    pn=$(printf '%s\n' "$info" | sed -n 's/^pkgname[[:space:]]*=[[:space:]]*//p' | head -n1)
    pv=$(printf '%s\n' "$info" | sed -n 's/^pkgver[[:space:]]*=[[:space:]]*//p'  | head -n1)
    pa=$(printf '%s\n' "$info" | sed -n 's/^arch[[:space:]]*=[[:space:]]*//p'    | head -n1)
    [ -z "$pn" ] && continue
    printf '%s\t%s\t%s\t%s\n' "$f" "$pn" "$pa" "$pv"
done)
if [ -z "$index" ]; then
    echo "⚠️ 未能解析任何包元数据，跳过去重"
    cd - >/dev/null
    exit 0
fi
keys=$(printf '%s\n' "$index" | awk -F'\t' '{print $2"\t"$3}' | sort -u)
printf '%s\n' "$keys" | while IFS="$(printf '\t')" read -r pkgname arch; do
    [ -z "$pkgname" ] && continue
    lines=$(printf '%s\n' "$index" | awk -F'\t' -v pn="$pkgname" -v ar="$arch" \
        '$2==pn && $3==ar {print $4"\t"$1}')
    count=$(printf '%s\n' "$lines" | grep -c .)
    if [ "$count" -gt 1 ]; then
        keep=$(printf '%s\n' "$lines" | sort -t"$(printf '\t')" -k1,1V | tail -n1 | cut -f2)
        printf '%s\n' "$lines" | cut -f2 | grep -v -F -x "$keep" | xargs -r rm -f --
        echo "🗑️ 已删除 $pkgname($arch) 旧版本，保留: $keep"
    fi
done
cd - > /dev/null
# ======= 修改点结束 =======

echo "✅ 所有 .apk 文件已整理至 $TARGET_DIR/"
