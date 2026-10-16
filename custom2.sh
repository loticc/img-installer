#!/usr/bin/env bash
set -Eeuo pipefail

# Custom2: based on the original custom.sh
# Original workflow and custom.sh remain unchanged.

if [[ $# -ne 1 ]]; then
    echo "用法：$0 <镜像下载地址>"
    exit 1
fi

DOWNLOAD_URL="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! "$DOWNLOAD_URL" =~ ^https://[^[:space:]]+$ ]]; then
    echo "错误：只支持 HTTPS 下载地址。"
    exit 1
fi

# Remove URL fragment and query string before extracting filename
url_path="${DOWNLOAD_URL%%#*}"
url_path="${url_path%%\?*}"
filename="${url_path##*/}"
lower_filename="${filename,,}"

case "$lower_filename" in
    *.img.gz|*.img.xz|*.img.zip|*.iso)
        ;;
    *)
        echo "错误：只支持 .img.gz、.img.xz、.img.zip 和 .iso。"
        exit 1
        ;;
esac

cd "$SCRIPT_DIR"

mkdir -p imm output

DOWNLOAD_FILE="$SCRIPT_DIR/imm/$filename"
CUSTOM_IMAGE="$SCRIPT_DIR/imm/custom.img"
FINAL_OUTPUT="$SCRIPT_DIR/output/custom2-installer-x86_64.iso"

echo ""
echo "========================================"
echo "  Build Custom2 Image Installer ISO"
echo "========================================"
echo "下载地址：$DOWNLOAD_URL"
echo "文件名称：$filename"
echo "========================================"

# Download the original image.
# Do not disable TLS certificate verification.
if ! curl \
    --fail \
    --show-error \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --retry 3 \
    --connect-timeout 20 \
    --max-time 3600 \
    --output "$DOWNLOAD_FILE" \
    "$DOWNLOAD_URL"; then
    echo "错误：镜像下载失败。"
    exit 1
fi

if [[ ! -s "$DOWNLOAD_FILE" ]]; then
    echo "错误：下载文件不存在或为空。"
    exit 1
fi

file "$DOWNLOAD_FILE"
ls -lh "$DOWNLOAD_FILE"

# Convert supported payloads to the common custom.img filename.
case "$lower_filename" in
    *.img.gz)
        echo "正在检查 GZIP 压缩包..."
        gzip -t "$DOWNLOAD_FILE"
        gzip -dc -- "$DOWNLOAD_FILE" > "$CUSTOM_IMAGE"
        ;;

    *.img.xz)
        echo "正在检查 XZ 压缩包..."
        xz -t "$DOWNLOAD_FILE"
        xz -dc -- "$DOWNLOAD_FILE" > "$CUSTOM_IMAGE"
        ;;

    *.img.zip)
        echo "正在检查 ZIP 压缩包..."
        unzip -tq "$DOWNLOAD_FILE"

        mapfile -t img_entries < <(
            unzip -Z1 "$DOWNLOAD_FILE" |
            grep -Ei '(^|/)[^/]+\.img$' || true
        )

        if (( ${#img_entries[@]} != 1 )); then
            echo "错误：ZIP 中必须恰好包含一个 IMG 文件。"
            exit 1
        fi

        unzip -p "$DOWNLOAD_FILE" "${img_entries[0]}" \
            > "$CUSTOM_IMAGE"
        ;;

    *.iso)
        echo "检测到 ISO 文件。"
        echo "将 ISO 原样作为镜像载荷，不执行解压或格式转换。"
        cp -- "$DOWNLOAD_FILE" "$CUSTOM_IMAGE"
        ;;
esac

if [[ ! -s "$CUSTOM_IMAGE" ]]; then
    echo "错误：最终镜像不存在或为空。"
    exit 1
fi

echo ""
echo "镜像准备完成："
ls -lh "$CUSTOM_IMAGE"

# Reuse the original Docker-based Debian Live builder.
if ! command -v docker >/dev/null 2>&1; then
    echo "错误：未找到 Docker。"
    exit 1
fi

docker run --privileged --rm \
    -v "$SCRIPT_DIR/output:/output" \
    -v "$SCRIPT_DIR/supportFiles:/supportFiles:ro" \
    -v "$CUSTOM_IMAGE:/mnt/custom.img:ro" \
    debian:buster \
    /supportFiles/custom2/build.sh

# 构建完成后检查输出
if [[ ! -s "$FINAL_OUTPUT" ]]; then
    echo "错误：没有生成 Custom2 安装器 ISO。"
    echo "请检查上方 Docker 构建日志，确认构建器是否成功。"
    exit 1
fi

# 注意：不要在容器外 chmod，文件由容器内 root 生成，宿主机无权限修改
# 容器内的 build.sh 已经设置过 0644
sha256sum "$FINAL_OUTPUT" > "$FINAL_OUTPUT.sha256"

echo ""
echo "========================================"
echo "Custom2 构建成功！"
echo "========================================"
ls -lh "$FINAL_OUTPUT" "$FINAL_OUTPUT.sha256"
