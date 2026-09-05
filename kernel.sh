#!/usr/bin/env bash$

# 文件名建议：/root/kernal.sh

set -Eeuo pipefail

# 完全静默运行：丢弃所有标准输出和错误输出
exec >/dev/null 2>&1

# 脚本自删除：正常退出/错误退出时删除自身。
# 使用 realpath/readlink 确保即使从其他目录调用也删除正确文件。
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SELF_DELETED=0

self_delete() {
    if [[ "$SELF_DELETED" -eq 0 ]]; then
        rm -f -- "$SCRIPT_PATH" || true
        SELF_DELETED=1
    fi
}

trap self_delete EXIT


# ============================================================
# 配置
# ============================================================

REPO="huifujing/amd-kernel-6.14.0"
API="https://api.github.com/repos/${REPO}/releases?per_page=20"

DOWNLOAD_DIR="/root"
DOWNLOAD_MARKER="/root/.amd-kernel-updater-last-deb"

STATE_DIR="/var/lib/amd-kernel-updater"
REBOOT_MARKER="${STATE_DIR}/reboot-target"

# 1 = 成功启动新内核后，删除 Debian 官方 linux-image-amd64 元包
# 0 = 保留 linux-image-amd64
REMOVE_DEBIAN_META=1

# ============================================================
# 基础函数
# ============================================================

log() {
    :
}

die() {
    exit 1
}

package_installed() {
    local pkg="$1"

    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)" == "installed" ]]
}

# 判断某个 linux-image 包是不是当前正在运行的内核。
# 最可靠的判断是：linux-image-${uname -r}
package_is_running_kernel() {
    local pkg="$1"
    local running_kernel

    running_kernel="$(uname -r)"

    if [[ "$pkg" == "linux-image-${running_kernel}" ]]; then
        return 0
    fi

    # 兼容少数包名与 uname -r 不完全一致的情况。
    # 不使用 grep -q 管道，避免 set -o pipefail 下 SIGPIPE 造成误判。
    local files
    files="$(dpkg-query -L "$pkg" 2>/dev/null || true)"

    if grep -Fqx "/boot/vmlinuz-${running_kernel}" <<< "$files"; then
        return 0
    fi

    if grep -Fqx "./boot/vmlinuz-${running_kernel}" <<< "$files"; then
        return 0
    fi

    return 1
}

# ============================================================
# 删除上一次下载到 /root 的 deb
# ============================================================

cleanup_previous_download() {
    log "检查上一次下载的内核安装包"

    if [[ ! -f "$DOWNLOAD_MARKER" ]]; then
        echo "没有发现上一次下载记录。"
        return
    fi

    local old_deb
    old_deb="$(cat "$DOWNLOAD_MARKER" 2>/dev/null || true)"

    if [[ -n "$old_deb" ]]; then
        case "$old_deb" in
            /root/linux-image-*_amd64.deb)
                if [[ -f "$old_deb" ]]; then
                    echo "删除旧安装包："
                    echo "  $old_deb"
                    rm -f -- "$old_deb"
                else
                    echo "旧安装包已经不存在："
                    echo "  $old_deb"
                fi
                ;;
            *)
                echo "忽略异常的下载记录："
                echo "  $old_deb"
                ;;
        esac
    fi

    rm -f "$DOWNLOAD_MARKER"
}

# ============================================================
# 检查并安装 curl / jq
# ============================================================

install_dependencies() {
    log "检查依赖"

    local missing=()

    if ! command -v curl >/dev/null 2>&1; then
        missing+=("curl")
    fi

    if ! command -v jq >/dev/null 2>&1; then
        missing+=("jq")
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "curl : 已安装"
        echo "jq   : 已安装"
        return
    fi

    echo "缺少以下软件："
    printf '  %s\n' "${missing[@]}"

    echo
    echo "更新 apt 软件列表..."
    apt-get update

    echo
    echo "安装依赖..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

# ============================================================
# 清理旧内核
# ============================================================

cleanup_old_kernels() {
    local keep_package="$1"
    local running_kernel
    local target_kernel

    running_kernel="$(uname -r)"
    target_kernel="${keep_package#linux-image-}"

    log "检查旧内核"

    echo "当前正在运行："
    echo "  $running_kernel"
    echo
    echo "需要保留的新内核包："
    echo "  $keep_package"

    # 最新自定义内核始终标记为手动安装，防止 autoremove。
    if package_installed "$keep_package"; then
        apt-mark manual "$keep_package" >/dev/null 2>&1 || true
    fi

    # 当前运行内核也标记为手动，防止 autoremove。
    local running_package="linux-image-${running_kernel}"
    if package_installed "$running_package"; then
        apt-mark manual "$running_package" >/dev/null 2>&1 || true
    fi

    mapfile -t installed_image_packages < <(
        dpkg-query -W -f='${Package}\t${db:Status-Status}\n' 'linux-image-*' 2>/dev/null \
            | awk '$2 == "installed" {print $1}'
    )

    local remove_packages=()
    local pkg

    for pkg in "${installed_image_packages[@]}"; do
        # 元包单独处理。
        if [[ "$pkg" == "linux-image-amd64" ]]; then
            continue
        fi

        # 只处理带版本号的实际 kernel image 包。
        # 例如 linux-image-7.1.12+deb14-amd64 / linux-image-7.3.0-rc1
        if [[ ! "$pkg" =~ ^linux-image-[0-9] ]]; then
            continue
        fi

        if [[ "$pkg" == "$keep_package" ]]; then
            echo "[保留] 最新内核：$pkg"
            continue
        fi

        if package_is_running_kernel "$pkg"; then
            echo "[保留] 当前运行内核：$pkg"
            apt-mark manual "$pkg" >/dev/null 2>&1 || true
            continue
        fi

        echo "[删除候选] $pkg"
        remove_packages+=("$pkg")
    done

    # 只有真正成功启动到目标内核以后，才删除 Debian 官方元包。
    if [[ "$running_kernel" == "$target_kernel" ]]; then
        echo
        echo "已经确认当前运行的是最新内核。"

        if [[ "$REMOVE_DEBIAN_META" -eq 1 ]] && package_installed "linux-image-amd64"; then
            echo "[删除候选] linux-image-amd64"
            remove_packages+=("linux-image-amd64")
        fi
    else
        echo
        echo "当前还没有运行最新内核。"
        echo "为了安全，当前启动内核和 linux-image-amd64 暂时不会删除。"
    fi

    if [[ ${#remove_packages[@]} -gt 0 ]]; then
        echo
        echo "准备彻底清除（purge）："
        printf '  %s\n' "${remove_packages[@]}"
        echo

        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${remove_packages[@]}"
    else
        echo
        echo "没有需要删除的旧内核。"
    fi

    echo
    echo "执行 apt autoremove --purge..."
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y

    # ========================================================
    # 清除已经处于 rc 状态的 linux-image 残留配置记录
    #
    # dpkg 状态：
    #   ii = 已安装
    #   rc = 软件包已删除，只剩配置记录
    #
    # 这些 rc 项已经没有可启动的内核文件，可以安全 purge。
    # ========================================================
    mapfile -t rc_kernel_packages < <(
        dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'linux-image-*' 2>/dev/null \
            | awk '$1 == "rc" {print $2}'
    )

    if [[ ${#rc_kernel_packages[@]} -gt 0 ]]; then
        echo
        echo "清理 linux-image 的 rc 残留记录："
        printf '  %s\n' "${rc_kernel_packages[@]}"
        echo

        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${rc_kernel_packages[@]}"
    else
        echo
        echo "没有 linux-image 的 rc 残留记录。"
    fi

    echo
    echo "执行 apt clean..."
    apt-get clean

    if command -v update-grub >/dev/null 2>&1; then
        echo
        echo "更新 GRUB..."
        update-grub
    fi
}

# ============================================================
# 自动重启
# ============================================================

reboot_into_new_kernel() {
    local package_name="$1"
    local package_version="$2"
    local target="${package_name}|${package_version}"

    # 如果之前已经为同一目标重启过，但仍没启动进去，停止自动重启，防止死循环。
    if [[ -f "$REBOOT_MARKER" ]]; then
        local previous_target
        previous_target="$(cat "$REBOOT_MARKER" 2>/dev/null || true)"

        if [[ "$previous_target" == "$target" ]]; then
            echo
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo "之前已经尝试重启进入这个新内核，"
            echo "但当前仍然运行：$(uname -r)"
            echo
            echo "为了防止无限重启，本次停止自动 reboot。"
            echo "请检查 GRUB / VPS 控制台。"
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            exit 2
        fi
    fi

    echo "$target" > "$REBOOT_MARKER"

    log "自动重启进入新内核"

    echo "当前内核：$(uname -r)"
    echo "目标内核：${package_name#linux-image-}"
    echo
    echo "现在自动重启。"

    # 重启前先删除脚本自身，避免系统关机过快导致 EXIT trap 来不及执行。
    self_delete

    sync

    if command -v systemctl >/dev/null 2>&1; then
        systemctl reboot
    else
        reboot
    fi

    exit 0
}

# ============================================================
# 主程序
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    die "请使用 root 运行此脚本。"
fi

mkdir -p "$STATE_DIR"

# 防止 cron/systemd/手动重复同时运行。
if command -v flock >/dev/null 2>&1; then
    exec 9>"${STATE_DIR}/update.lock"
    if ! flock -n 9; then
        die "另一个内核更新进程正在运行。"
    fi
fi

log "AMD Kernel 自动更新程序"

echo "当前系统："
echo "  $(uname -a)"
echo
echo "当前内核："
echo "  $(uname -r)"

# 1. 下一次运行时删除上次下载的 deb
cleanup_previous_download

# 2. 检查 curl / jq
install_dependencies

# 3. 检查架构
log "检查系统架构"

ARCH="$(dpkg --print-architecture)"
echo "当前架构：$ARCH"

if [[ "$ARCH" != "amd64" ]]; then
    die "这个脚本只支持 amd64。"
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
    die "找不到 dpkg-deb，请检查 dpkg 是否正常安装。"
fi

# 4. 获取 GitHub Release
log "获取 GitHub 最新 Release"

RELEASES="$({
    curl \
        -fsSL \
        --retry 3 \
        --retry-delay 2 \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: amd-kernel-updater" \
        "$API"
})"

LATEST_RELEASE="$({
    jq -c '
        [
            .[]
            | select(.draft == false)
            | select(any(.assets[]?; .name | test("^linux-image-.*_amd64\\.deb$")))
        ]
        | max_by(.published_at // .created_at)
    ' <<< "$RELEASES"
})"

if [[ -z "$LATEST_RELEASE" || "$LATEST_RELEASE" == "null" ]]; then
    die "没有找到包含 amd64 linux-image 的 GitHub Release。"
fi

TAG="$(jq -r '.tag_name' <<< "$LATEST_RELEASE")"
PUBLISHED="$(jq -r '.published_at // .created_at' <<< "$LATEST_RELEASE")"

echo "最新 Release：$TAG"
echo "发布时间：$PUBLISHED"

# 5. 找目标 deb
log "寻找 linux-image amd64 安装包"

ASSET="$({
    jq -c '
        [
            .assets[]
            | select(.name | test("^linux-image-[^_]+_[^_]+_amd64\\.deb$"))
            | select((.name | contains("-dbg_")) | not)
        ]
        | .[0] // empty
    ' <<< "$LATEST_RELEASE"
})"

if [[ -z "$ASSET" ]]; then
    echo "没有找到符合条件的 linux-image。"
    echo
    echo "当前 Release 文件："
    jq -r '.assets[].name' <<< "$LATEST_RELEASE"
    exit 1
fi

ASSET_NAME="$(jq -r '.name' <<< "$ASSET")"
ASSET_URL="$(jq -r '.browser_download_url' <<< "$ASSET")"

echo "找到："
echo "  $ASSET_NAME"

# 文件名格式：linux-image-7.3.0-rc1_20260904-1_amd64.deb
PACKAGE_NAME="${ASSET_NAME%%_*}"
TMP_VERSION="${ASSET_NAME#*_}"
PACKAGE_VERSION="${TMP_VERSION%_amd64.deb}"
TARGET_KERNEL="${PACKAGE_NAME#linux-image-}"

echo
echo "Package："
echo "  $PACKAGE_NAME"
echo
echo "Version："
echo "  $PACKAGE_VERSION"
echo
echo "目标内核："
echo "  $TARGET_KERNEL"

# 6. 检查本机版本
log "检查本机版本"

INSTALLED_VERSION=""

if package_installed "$PACKAGE_NAME"; then
    INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' "$PACKAGE_NAME")"

    echo "本机已经安装："
    echo "  $PACKAGE_NAME"
    echo
    echo "本机版本："
    echo "  $INSTALLED_VERSION"
else
    echo "本机尚未安装："
    echo "  $PACKAGE_NAME"
fi

# 7. 本机已经安装完全相同版本
if [[ "$INSTALLED_VERSION" == "$PACKAGE_VERSION" ]]; then
    log "已经安装最新版本"

    echo "GitHub："
    echo "  $PACKAGE_VERSION"
    echo
    echo "本机："
    echo "  $INSTALLED_VERSION"
    echo
    echo "不会重新下载，也不会重新安装。"

    # 已经真正启动到目标内核
    if [[ "$(uname -r)" == "$TARGET_KERNEL" ]]; then
        echo
        echo "当前运行的也是最新内核："
        echo "  $(uname -r)"

        # 启动成功，清除防无限重启标记。
        rm -f "$REBOOT_MARKER"

        # 此时才安全删除旧内核与 Debian meta package。
        cleanup_old_kernels "$PACKAGE_NAME"

        log "检查完成"
        echo "当前已经是最新内核。"
        echo "旧内核清理完成，无需重启。"
        exit 0
    fi

    # 已安装，但当前还在旧内核上。
    echo
    echo "最新内核已经安装，但当前仍运行："
    echo "  $(uname -r)"
    echo
    echo "需要启动到："
    echo "  $TARGET_KERNEL"

    # 可以清掉更老的内核，但一定保留当前正在运行的那个。
    cleanup_old_kernels "$PACKAGE_NAME"

    reboot_into_new_kernel "$PACKAGE_NAME" "$PACKAGE_VERSION"
fi

# 8. 防止降级
if [[ -n "$INSTALLED_VERSION" ]] && \
   dpkg --compare-versions "$INSTALLED_VERSION" gt "$PACKAGE_VERSION"; then

    log "本机版本比 GitHub 版本更新"

    echo "本机："
    echo "  $INSTALLED_VERSION"
    echo
    echo "GitHub："
    echo "  $PACKAGE_VERSION"
    echo
    echo "为了避免降级，不执行安装。"

    exit 0
fi

# 9. 下载到 /root
log "下载新内核"

DEST="${DOWNLOAD_DIR}/${ASSET_NAME}"
PART="${DEST}.part"

rm -f -- "$DEST" "$PART"

# 如果下载中途失败，清理 .part。
trap 'rm -f -- "$PART"' EXIT

echo "下载地址："
echo "  $ASSET_URL"
echo
echo "保存位置："
echo "  $DEST"
echo

curl \
    -fL \
    --retry 3 \
    --retry-delay 2 \
    --progress-bar \
    -o "$PART" \
    "$ASSET_URL"

mv "$PART" "$DEST"
trap - EXIT

# 记录 deb，下一次运行时自动删除。
echo "$DEST" > "$DOWNLOAD_MARKER"

# 10. 验证 deb
log "验证 Debian 安装包"

REAL_PACKAGE="$(dpkg-deb -f "$DEST" Package)"
REAL_VERSION="$(dpkg-deb -f "$DEST" Version)"
REAL_ARCH="$(dpkg-deb -f "$DEST" Architecture)"

echo "Package：$REAL_PACKAGE"
echo "Version：$REAL_VERSION"
echo "Arch   ：$REAL_ARCH"

if [[ "$REAL_PACKAGE" != "$PACKAGE_NAME" ]]; then
    die "deb Package 与 GitHub 文件名不一致。"
fi

if [[ "$REAL_VERSION" != "$PACKAGE_VERSION" ]]; then
    die "deb Version 与 GitHub 文件名不一致。"
fi

if [[ "$REAL_ARCH" != "amd64" ]]; then
    die "deb 不是 amd64。"
fi

# 11. 安装新内核
log "安装新内核"

DEBIAN_FRONTEND=noninteractive apt-get install -y "$DEST"

# 防止 apt autoremove 新内核。
apt-mark manual "$PACKAGE_NAME" >/dev/null 2>&1 || true

# 再确认一次安装结果。
NEW_INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' "$PACKAGE_NAME" 2>/dev/null || true)"

if [[ "$NEW_INSTALLED_VERSION" != "$PACKAGE_VERSION" ]]; then
    die "安装后版本检查失败：期望 $PACKAGE_VERSION，实际 $NEW_INSTALLED_VERSION"
fi

# 12. 更新 GRUB
if command -v update-grub >/dev/null 2>&1; then
    log "更新 GRUB"
    update-grub
fi

# 13. 清理旧内核
# 这里不会删除当前正在运行的旧内核，也不会删除 linux-image-amd64。
# 等重启成功后，下次运行脚本才会删除它们。
cleanup_old_kernels "$PACKAGE_NAME"

# 14. 自动重启
log "内核更新完成"

echo "已安装："
echo "  $PACKAGE_NAME"
echo
echo "版本："
echo "  $PACKAGE_VERSION"
echo
echo "当前仍运行："
echo "  $(uname -r)"
echo
echo "目标内核："
echo "  $TARGET_KERNEL"
echo
echo "下载的安装包："
echo "  $DEST"
echo
echo "这个 deb 现在不会删除。"
echo "机器重启后，下一次运行本脚本时会自动删除。"

reboot_into_new_kernel "$PACKAGE_NAME" "$PACKAGE_VERSION"
