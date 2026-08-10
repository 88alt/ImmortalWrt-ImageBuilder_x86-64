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

# ======= 修改点：先白名单强制覆盖，再同名同架构去重只保留最新版本（ipk 版）=======
# 包名切分规则（与去重逻辑保持一致）：先剥离已知 arch 后缀，
# 再取剩余部分最后一个 "_" 前的内容作为包名，
# 避免包名自带数字/连字符时被误切（如 i18n-zh-cn、lib_ffi）。
#
# ★★★ 白名单区域 —— 手动维护，按需增删 ★★★
# 命中 (包名, arch) 相同即强制只保留白名单文件，其余同包版本
# （不论新旧、不论来源仓库）全部删除，不比较版本号。
# 填写：完整文件名，一行一个，不加路径，例如：
#   luci-app-quickstart_0.12.8-r1_x86_64.ipk
# 删除某行 = 该包回退到下方版本去重兜底逻辑（保留最新版本）。
# 若某条目未在 TARGET_DIR 中找到，只警告不中断构建。
# ============================================================
WHITELIST_FILES="
luci-app-turboacc_27.207.56979~bf03fd2_all.ipk
"
# ============================================================
# ★★★★★ 白名单区域结束 ★★★★★
# ============================================================

ARCH_LIST="x86_64 all"   # 按需修改为实际平台架构 + all（架构无关的luci包）
echo "🔧 正在整理 $TARGET_DIR 中的包（白名单强制模式 + 版本去重兜底，arch 列表: $ARCH_LIST）..."
cd "$TARGET_DIR"

if ! ls *.ipk >/dev/null 2>&1; then
    echo "⚠️ 未找到任何 ipk 文件，跳过整理"
    cd - >/dev/null
    exit 0
fi

# 解析单个文件名 -> 包名/版本/arch（按 ARCH_LIST 顺序尝试剥离后缀）
# 用法: parse_ipk <文件名>，成功时输出 "pkgname\tversion\tarch"，失败无输出
parse_ipk() {
    f="$1"
    base="${f%.ipk}"
    for a in $ARCH_LIST; do
        nv="${base%_${a}}"
        if [ "$nv" != "$base" ]; then
            pn="${nv%_*}"
            ver="${nv#${pn}_}"
            printf '%s\t%s\t%s\n' "$pn" "$ver" "$a"
            return 0
        fi
    done
    return 1
}

# 建立全量索引：文件名 \t 包名 \t 版本 \t arch
index=$(for f in *.ipk; do
    rec=$(parse_ipk "$f")
    [ -z "$rec" ] && { echo "⚠️ 跳过无法识别 arch 后缀的包: $f" >&2; continue; }
    printf '%s\t%s\n' "$f" "$rec"
done)

if [ -z "$index" ]; then
    echo "⚠️ 未能解析任何包，跳过整理"
    cd - >/dev/null
    exit 0
fi

# ------------------------------------------------------------
# 阶段一：白名单强制覆盖（按 包名+arch 精确匹配，非文件名前缀）
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
    wpa=$(printf '%s' "$wline" | cut -f4)

    # 找出同 包名+arch 的所有文件（含白名单文件自己）
    same=$(printf '%s\n' "$index" | awk -F'\t' -v pn="$wpn" -v ar="$wpa" \
        '$2==pn && $4==ar {print $1}')

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
# 阶段二：版本去重兜底（跳过已被白名单处理的分组，按版本号 sort -V 保留最新）
# ------------------------------------------------------------
keys=$(printf '%s\n' "$index" | awk -F'\t' '{print $2"\t"$4}' | sort -u)

printf '%s\n' "$keys" | while IFS="$(printf '\t')" read -r pkgname arch; do
    [ -z "$pkgname" ] && continue

    if printf '%s\n' "$handled_keys" | grep -q -F -x "$(printf '%s\t%s' "$pkgname" "$arch")"; then
        continue
    fi

    lines=$(printf '%s\n' "$index" | awk -F'\t' -v pn="$pkgname" -v ar="$arch" \
        '$2==pn && $4==ar {print $3"\t"$1}')
    count=$(printf '%s\n' "$lines" | grep -c .)
    if [ "$count" -gt 1 ]; then
        keep=$(printf '%s\n' "$lines" | sort -t"$(printf '\t')" -k1,1V | tail -n1 | cut -f2)
        printf '%s\n' "$lines" | cut -f2 | grep -v -F -x "$keep" | xargs -r rm -f --
        echo "🗑️ 已删除 $pkgname($arch) 旧版本，保留: $keep"
    fi
done

cd - > /dev/null
# ======= 修改点结束 =======

echo "✅ 所有 .ipk 文件已整理至 $TARGET_DIR/"
