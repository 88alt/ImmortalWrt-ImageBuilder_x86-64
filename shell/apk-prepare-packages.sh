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

# ======= 修改点：先白名单强制覆盖，再同名同架构去重只保留最新版本（apk 版）=======
# ★★★ 白名单区域 —— 手动维护，按需增删 ★★★
# 命中 pkgname+arch 相同即强制只保留白名单文件，其余同包版本
# （不论新旧、不论来源仓库）全部删除，不比较版本号。
# 填写：完整文件名，一行一个，不加路径，例如：
#   luci-app-quickstart-0.12.8-r1.apk
# 删除某行 = 该包回退到下方版本去重兜底逻辑（保留最新版本）。
# 若某条目在 TARGET_DIR 中找不到同名文件，只警告不中断构建。
# ============================================================
WHITELIST_FILES="
luci-app-quickstart-0.12.8-r1.apk
quickstart-0.13.0-r1.apk
luci-app-turboacc-26.244.14891~b50b52f-r1.apk
luci-i18n-turboacc-zh-cn-26.244.14891~b50b52f.apk
"
# ============================================================
# ★★★★★ 白名单区域结束 ★★★★★
# ============================================================

echo "🔧 正在整理 $TARGET_DIR 中的包（白名单强制模式 + 版本去重兜底）..."
cd "$TARGET_DIR"

if ! ls -- *.apk >/dev/null 2>&1; then
    echo "⚠️ 未找到任何 apk 文件，跳过整理"
    cd - >/dev/null
    exit 0
fi

# 建立全量索引：文件名 \t pkgname \t arch \t pkgver
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
    echo "⚠️ 未能解析任何包元数据，跳过整理"
    cd - >/dev/null
    exit 0
fi

# ------------------------------------------------------------
# 阶段一：白名单强制覆盖（按 pkgname+arch 精确匹配，非文件名前缀）
# ------------------------------------------------------------
handled_keys=""

for wf in $WHITELIST_FILES; do
    [ -z "$wf" ] && continue

    # 精确匹配：文件名字段（第1列）与白名单条目完全相等
    wline=$(printf '%s\n' "$index" | awk -F'\t' -v want="$wf" '$1==want {print; exit}')

    if [ -z "$wline" ]; then
        echo "⚠️ 白名单条目未在 $TARGET_DIR 中找到，已跳过: $wf" >&2
        continue
    fi

    wpn=$(printf '%s' "$wline" | cut -f2)
    wpa=$(printf '%s' "$wline" | cut -f3)

    # 找出同 pkgname + arch 的所有文件（含白名单文件自己）
    same=$(printf '%s\n' "$index" | awk -F'\t' -v pn="$wpn" -v ar="$wpa" \
        '$2==pn && $3==ar {print $1}')

    # 删除除白名单文件外的其余同包文件
    to_remove=$(printf '%s\n' "$same" | grep -v -F -x "$wf")
    if [ -n "$to_remove" ]; then
        printf '%s\n' "$to_remove" | xargs -r rm -f --
        echo "🔒 白名单强制保留 [$wf]，已删除同包($wpn/$wpa)其余版本："
        printf '%s\n' "$to_remove" | sed 's/^/     - /'
    else
        echo "🔒 白名单强制保留 [$wf]（未发现同包其余版本，无需删除）"
    fi

    handled_keys="$handled_keys
$wpn	$wpa"
done

# ------------------------------------------------------------
# 阶段二：版本去重兜底（跳过已被白名单处理的分组，按 pkgver 保留最新）
# ------------------------------------------------------------
keys=$(printf '%s\n' "$index" | awk -F'\t' '{print $2"\t"$3}' | sort -u)

printf '%s\n' "$keys" | while IFS="$(printf '\t')" read -r pkgname arch; do
    [ -z "$pkgname" ] && continue

    # 跳过已被白名单处理过的 (pkgname, arch)
    if printf '%s\n' "$handled_keys" | grep -q -F -x "$(printf '%s\t%s' "$pkgname" "$arch")"; then
        continue
    fi

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
