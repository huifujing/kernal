#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SELF_DELETED=0

self_delete() {
    if [[ "$SELF_DELETED" -eq 0 ]]; then
        rm -f -- "$SCRIPT_PATH" || true
        SELF_DELETED=1
    fi
}

trap self_delete EXIT
exec >/dev/null 2>&1

REPO="huifujing/amd-kernel-6.14.0"
API="https://api.github.com/repos/${REPO}/releases?per_page=20"
DOWNLOAD_DIR="/root"
DOWNLOAD_MARKER="/root/.amd-kernel-updater-last-deb"
STATE_DIR="/var/lib/amd-kernel-updater"
REBOOT_MARKER="${STATE_DIR}/reboot-target"
REMOVE_DEBIAN_META=1

fail() {
    exit 1
}

package_installed() {
    local pkg="$1"
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)" == "installed" ]]
}

package_is_running_kernel() {
    local pkg="$1"
    local running_kernel
    local files

    running_kernel="$(uname -r)"

    if [[ "$pkg" == "linux-image-${running_kernel}" ]]; then
        return 0
    fi

    files="$(dpkg-query -L "$pkg" 2>/dev/null || true)"

    if grep -Fqx "/boot/vmlinuz-${running_kernel}" <<< "$files"; then
        return 0
    fi

    if grep -Fqx "./boot/vmlinuz-${running_kernel}" <<< "$files"; then
        return 0
    fi

    return 1
}

cleanup_previous_download() {
    local old_deb

    [[ -f "$DOWNLOAD_MARKER" ]] || return 0

    old_deb="$(cat "$DOWNLOAD_MARKER" 2>/dev/null || true)"

    if [[ -n "$old_deb" ]]; then
        case "$old_deb" in
            /root/linux-image-*_amd64.deb)
                rm -f -- "$old_deb" || true
                ;;
        esac
    fi

    rm -f -- "$DOWNLOAD_MARKER"
}

install_dependencies() {
    local missing=()

    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v jq >/dev/null 2>&1 || missing+=(jq)

    if [[ ${#missing[@]} -gt 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    fi
}

purge_rc_kernel_packages() {
    local rc_kernel_packages=()

    mapfile -t rc_kernel_packages < <(
        dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'linux-image-*' 2>/dev/null \
            | awk '$1 == "rc" {print $2}'
    )

    if [[ ${#rc_kernel_packages[@]} -gt 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${rc_kernel_packages[@]}"
    fi
}

cleanup_old_kernels() {
    local keep_package="$1"
    local running_kernel
    local target_kernel
    local running_package
    local installed_image_packages=()
    local remove_packages=()
    local pkg

    running_kernel="$(uname -r)"
    target_kernel="${keep_package#linux-image-}"
    running_package="linux-image-${running_kernel}"

    if package_installed "$keep_package"; then
        apt-mark manual "$keep_package" >/dev/null 2>&1 || true
    fi

    if package_installed "$running_package"; then
        apt-mark manual "$running_package" >/dev/null 2>&1 || true
    fi

    mapfile -t installed_image_packages < <(
        dpkg-query -W -f='${Package}\t${db:Status-Status}\n' 'linux-image-*' 2>/dev/null \
            | awk '$2 == "installed" {print $1}'
    )

    for pkg in "${installed_image_packages[@]}"; do
        [[ "$pkg" == "linux-image-amd64" ]] && continue
        [[ "$pkg" =~ ^linux-image-[0-9] ]] || continue
        [[ "$pkg" == "$keep_package" ]] && continue

        if package_is_running_kernel "$pkg"; then
            apt-mark manual "$pkg" >/dev/null 2>&1 || true
            continue
        fi

        remove_packages+=("$pkg")
    done

    if [[ "$running_kernel" == "$target_kernel" ]] && [[ "$REMOVE_DEBIAN_META" -eq 1 ]]; then
        if package_installed "linux-image-amd64"; then
            remove_packages+=("linux-image-amd64")
        fi
    fi

    if [[ ${#remove_packages[@]} -gt 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${remove_packages[@]}"
    fi

    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -qq
    purge_rc_kernel_packages
    apt-get clean

    if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null 2>&1
    fi
}

reboot_into_new_kernel() {
    local package_name="$1"
    local package_version="$2"
    local target="${package_name}|${package_version}"
    local previous_target=""

    if [[ -f "$REBOOT_MARKER" ]]; then
        previous_target="$(cat "$REBOOT_MARKER" 2>/dev/null || true)"
        if [[ "$previous_target" == "$target" ]]; then
            exit 2
        fi
    fi

    printf '%s\n' "$target" > "$REBOOT_MARKER"
    sync
    self_delete

    if command -v systemctl >/dev/null 2>&1; then
        systemctl reboot
    else
        reboot
    fi

    exit 0
}

[[ "$EUID" -eq 0 ]] || fail

mkdir -p "$STATE_DIR"

if command -v flock >/dev/null 2>&1; then
    exec 9>"${STATE_DIR}/update.lock"
    flock -n 9 || exit 0
fi

cleanup_previous_download
install_dependencies

[[ "$(dpkg --print-architecture)" == "amd64" ]] || fail
command -v dpkg-deb >/dev/null 2>&1 || fail

RELEASES="$(
    curl \
        -fsSL \
        --retry 3 \
        --retry-delay 2 \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: amd-kernel-updater" \
        "$API"
)"

LATEST_RELEASE="$(
    jq -c '
        [
            .[]
            | select(.draft == false)
            | select(any(.assets[]?; .name | test("^linux-image-.*_amd64\\.deb$")))
        ]
        | max_by(.published_at // .created_at)
    ' <<< "$RELEASES"
)"

[[ -n "$LATEST_RELEASE" && "$LATEST_RELEASE" != "null" ]] || fail

ASSET="$(
    jq -c '
        [
            .assets[]
            | select(.name | test("^linux-image-[^_]+_[^_]+_amd64\\.deb$"))
            | select((.name | contains("-dbg_")) | not)
        ]
        | .[0] // empty
    ' <<< "$LATEST_RELEASE"
)"

[[ -n "$ASSET" ]] || fail

ASSET_NAME="$(jq -r '.name' <<< "$ASSET")"
ASSET_URL="$(jq -r '.browser_download_url' <<< "$ASSET")"
PACKAGE_NAME="${ASSET_NAME%%_*}"
TMP_VERSION="${ASSET_NAME#*_}"
PACKAGE_VERSION="${TMP_VERSION%_amd64.deb}"
TARGET_KERNEL="${PACKAGE_NAME#linux-image-}"
INSTALLED_VERSION=""

if package_installed "$PACKAGE_NAME"; then
    INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' "$PACKAGE_NAME")"
fi

if [[ "$INSTALLED_VERSION" == "$PACKAGE_VERSION" ]]; then
    if [[ "$(uname -r)" == "$TARGET_KERNEL" ]]; then
        rm -f -- "$REBOOT_MARKER"
        cleanup_old_kernels "$PACKAGE_NAME"
        exit 0
    fi

    cleanup_old_kernels "$PACKAGE_NAME"
    reboot_into_new_kernel "$PACKAGE_NAME" "$PACKAGE_VERSION"
fi

if [[ -n "$INSTALLED_VERSION" ]] && dpkg --compare-versions "$INSTALLED_VERSION" gt "$PACKAGE_VERSION"; then
    exit 0
fi

DEST="${DOWNLOAD_DIR}/${ASSET_NAME}"
PART="${DEST}.part"

rm -f -- "$DEST" "$PART"
trap 'rm -f -- "$PART"; self_delete' EXIT

curl \
    -fsSL \
    --retry 3 \
    --retry-delay 2 \
    -o "$PART" \
    "$ASSET_URL"

mv "$PART" "$DEST"
trap self_delete EXIT
printf '%s\n' "$DEST" > "$DOWNLOAD_MARKER"

REAL_PACKAGE="$(dpkg-deb -f "$DEST" Package)"
REAL_VERSION="$(dpkg-deb -f "$DEST" Version)"
REAL_ARCH="$(dpkg-deb -f "$DEST" Architecture)"

[[ "$REAL_PACKAGE" == "$PACKAGE_NAME" ]] || fail
[[ "$REAL_VERSION" == "$PACKAGE_VERSION" ]] || fail
[[ "$REAL_ARCH" == "amd64" ]] || fail

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$DEST"
apt-mark manual "$PACKAGE_NAME" >/dev/null 2>&1 || true

NEW_INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' "$PACKAGE_NAME" 2>/dev/null || true)"
[[ "$NEW_INSTALLED_VERSION" == "$PACKAGE_VERSION" ]] || fail

if command -v update-grub >/dev/null 2>&1; then
    update-grub >/dev/null 2>&1
fi

cleanup_old_kernels "$PACKAGE_NAME"
reboot_into_new_kernel "$PACKAGE_NAME" "$PACKAGE_VERSION"
