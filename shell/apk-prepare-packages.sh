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

# ======= 修改点：同名包去重，只保留最新版本 =======
# 说明：
# 1) 不能简单按"第一个下划线+数字"切分包名，因为包名本身可能带
#    数字（如 abc_2 vs abc_3、i18n-zh-cn 等），会把本质不同的两个
#    包误判成同一包的不同版本，错误删除其中一个。这里先按已知的
#    arch 后缀（如 x86_64 / all）剥离，再按剩余部分【最后一个下划线】
#    切出版本号，包名前缀无论带不带数字都不会被误伤。
# 2) 按 arch 分组比较，避免不同架构的同名包互相误删。
# 3) 用"语义版本号"（sort -V）而不是文件 mtime 作为新旧判断依据：
#    因为 cp 不带 -p，mtime 只反映"脚本里谁被复制的顺序更靠后"，
#    与包的真实新旧毫无关系，按 mtime 保留反而可能留下更旧的版本。
# 4) 若同名同版本号来自不同仓库，文件名完全一致，cp 阶段后到的会
#    直接覆盖前一个，本去重逻辑不会再看到重复文件，不需要额外用
#    时间戳判断"两者都一样时留哪个"。
ARCH_LIST="x86_64 all"   # 按需修改为实际平台架构 + all（架构无关的luci包）

echo "🔧 正在对 $TARGET_DIR 中的同名包去重（arch 列表: $ARCH_LIST），保留最新版本..."
cd "$TARGET_DIR"

if ! ls *.apk >/dev/null 2>&1; then
    echo "⚠️ 未找到任何 apk 文件，跳过去重"
    cd - >/dev/null
    exit 0
fi

for TARGET_ARCH in $ARCH_LIST; do
    pkgnames=$(for f in *.apk; do
        base="${f%.apk}"
        nv="${base%_${TARGET_ARCH}}"
        [ "$nv" = "$base" ] && continue   # 不属于当前 arch，跳过
        echo "${nv%_*}"
    done | sort -u)

    [ -z "$pkgnames" ] && continue

    printf '%s\n' "$pkgnames" | while IFS= read -r pkgname; do
        [ -z "$pkgname" ] && continue
        matches=$(for f in *.apk; do
            base="${f%.apk}"
            nv="${base%_${TARGET_ARCH}}"
            [ "$nv" = "$base" ] && continue
            pn="${nv%_*}"
            [ "$pn" = "$pkgname" ] && echo "$f"
        done)
        # POSIX 安全计数，不用 wc -l <<<（BusyBox ash 可能不支持 here-string）
        count=$(printf '%s\n' "$matches" | grep -c .)
        if [ "$count" -gt 1 ]; then
            keep=$(printf '%s\n' "$matches" | sort -V | tail -n1)
            printf '%s\n' "$matches" | grep -v -F -x "$keep" | xargs -r rm -f
            echo "🗑️ 已删除 $pkgname($TARGET_ARCH) 旧版本，保留: $keep"
        fi
    done
done

cd - > /dev/null
# ======= 修改点结束 =======

echo "✅ 所有 .apk 文件已整理至 $TARGET_DIR/"
