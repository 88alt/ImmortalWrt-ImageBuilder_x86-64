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
# 说明：
# 1) apk 包文件名格式与 ipk 不同，不带 arch 后缀，分隔符也是连字符
#    而非下划线，例如: https-dns-proxy-2023.12.26-r1.apk
#    （对比 ipk: https-dns-proxy_2023.12.26-1_x86_64.ipk）
#    因此不能照搬 ipk 那套"剥离 arch 后缀 + 按最后一个分隔符切版本号"
#    的逻辑——文件名里根本没有 arch 子串可剥离，会导致过滤条件恒成立
#    从而整个去重逻辑被跳过；而且包名本身常含连字符（如 python3-pip、
#    luci-app-xxx），按"最后一个 -"切版本号也会把包名切错。
# 2) apk 是多段 gzip 拼接的归档：第一段是签名，第二段是控制信息
#    （含 .PKGINFO，记录 pkgname / pkgver / arch 等元数据），第三段
#    才是实际文件数据。用 tar 解出 .PKGINFO 时，GNU tar 遇到内部的
#    tar-EOF（连续两个全零块）就会停止读取，不会继续解析后面的数据
#    段，因此可以稳定、准确地拿到该包的真实 pkgname/pkgver/arch，
#    不依赖对文件名格式的猜测。
# 3) 按 (pkgname, arch) 分组比较，避免不同架构的同名包互相误删。
# 4) 用 pkgver 做"语义版本号"（sort -V）比较，而不是文件 mtime：
#    因为 cp 不带 -p，mtime 只反映"脚本里谁被复制的顺序更靠后"，
#    与包的真实新旧毫无关系，按 mtime 保留反而可能留下更旧的版本。
# 5) 若同名同版本号来自不同仓库，文件名完全一致，cp 阶段后到的会
#    直接覆盖前一个，本去重逻辑不会再看到重复文件，不需要额外用
#    时间戳判断"两者都一样时留哪个"。
echo "🔧 正在对 $TARGET_DIR 中的同名包去重（apk），保留最新版本..."
cd "$TARGET_DIR"

if ! ls *.apk >/dev/null 2>&1; then
    echo "⚠️ 未找到任何 apk 文件，跳过去重"
    cd - >/dev/null
    exit 0
fi

# 建立索引: "文件名<TAB>pkgname<TAB>arch<TAB>pkgver"
# 通过读取每个 apk 包内的 .PKGINFO 获取真实元数据，而非猜测文件名结构
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

# 取出所有出现过的 (pkgname, arch) 组合，逐组比较版本
keys=$(printf '%s\n' "$index" | awk -F'\t' '{print $2"\t"$3}' | sort -u)

printf '%s\n' "$keys" | while IFS="$(printf '\t')" read -r pkgname arch; do
    [ -z "$pkgname" ] && continue

    # 该 (pkgname, arch) 下所有文件: "pkgver<TAB>文件名"
    lines=$(printf '%s\n' "$index" | awk -F'\t' -v pn="$pkgname" -v ar="$arch" \
        '$2==pn && $3==ar {print $4"\t"$1}')

    # POSIX 安全计数，不用 wc -l <<<（BusyBox ash 可能不支持 here-string）
    count=$(printf '%s\n' "$lines" | grep -c .)

    if [ "$count" -gt 1 ]; then
        # 按 pkgver 做版本号排序（sort -V），取最新的一个保留
        keep=$(printf '%s\n' "$lines" | sort -t"$(printf '\t')" -k1,1V | tail -n1 | cut -f2)
        printf '%s\n' "$lines" | cut -f2 | grep -v -F -x "$keep" | xargs -r rm -f
        echo "🗑️ 已删除 $pkgname($arch) 旧版本，保留: $keep"
    fi
done

cd - > /dev/null
# ======= 修改点结束 =======

echo "✅ 所有 .apk 文件已整理至 $TARGET_DIR/"
