#!/usr/bin/env bash

# Temporary proxy launcher based on Xray-Core.
# Supports common vless://, ss://, trojan:// and vmess:// share links.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XRAY_BIN="${XRAY_BIN:-$SCRIPT_DIR/xray}"
WORK_DIR="${TMP_PROXY_WORK_DIR:-/tmp/tmp-proxy}"
if [[ -n "${TMP_PROXY_STATE_DIR:-}" ]]; then
    STATE_DIR="$TMP_PROXY_STATE_DIR"
elif [[ -n "${TMP_PROXY_WORK_DIR:-}" ]]; then
    STATE_DIR="$WORK_DIR"
else
    STATE_DIR="${HOME:-/tmp}/.tmp-proxy"
fi
CONFIG_FILE="$WORK_DIR/config.json"
SUMMARY_FILE="$WORK_DIR/summary.txt"
PID_FILE="$WORK_DIR/xray.pid"
LOG_FILE="$WORK_DIR/xray.log"
SETTINGS_FILE="$STATE_DIR/settings.env"
LAST_LINK_FILE="$STATE_DIR/last-link.txt"
SYSTEM_PROXY_FILE="${TMP_PROXY_SYSTEM_PROXY_FILE:-/etc/profile.d/tmp-proxy.sh}"
USER_PROXY_FILE="${TMP_PROXY_USER_PROXY_FILE:-$STATE_DIR/user-proxy.sh}"
USER_PROXY_RC_FILE="${TMP_PROXY_USER_PROXY_RC_FILE:-}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
HTTP_PORT="${HTTP_PORT:-10809}"

if [[ "$STATE_DIR" != "$WORK_DIR" ]]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if [[ ! -f "$SETTINGS_FILE" && -f "$WORK_DIR/settings.env" ]]; then
        cp "$WORK_DIR/settings.env" "$SETTINGS_FILE" 2>/dev/null || true
    fi
    if [[ ! -f "$LAST_LINK_FILE" && -f "$WORK_DIR/last-link.txt" ]]; then
        cp "$WORK_DIR/last-link.txt" "$LAST_LINK_FILE" 2>/dev/null || true
    fi
fi

if [[ -r "$SETTINGS_FILE" ]]; then
    while IFS='=' read -r key value; do
        case "$key" in
            SOCKS_PORT)
                [[ "$value" =~ ^[0-9]+$ ]] && SOCKS_PORT="$value"
                ;;
            HTTP_PORT)
                [[ "$value" =~ ^[0-9]+$ ]] && HTTP_PORT="$value"
                ;;
        esac
    done < "$SETTINGS_FILE"
fi

if [[ -z "$USER_PROXY_RC_FILE" ]]; then
    case "${SHELL:-}" in
        */zsh)
            USER_PROXY_RC_FILE="${HOME:-$STATE_DIR}/.zshrc"
            ;;
        */bash)
            USER_PROXY_RC_FILE="${HOME:-$STATE_DIR}/.bashrc"
            ;;
        *)
            USER_PROXY_RC_FILE="${HOME:-$STATE_DIR}/.profile"
            ;;
    esac
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
tmp-proxy - 基于 Xray 的临时本地代理工具

用法:
  ./tmp-proxy.sh                          打开控制菜单
  ./tmp-proxy.sh menu                     打开控制菜单
  ./tmp-proxy.sh start '<share-link>'     后台启动/切换代理
  ./tmp-proxy.sh run '<share-link>'       前台运行代理
  ./tmp-proxy.sh stop                     停止后台代理
  ./tmp-proxy.sh restart '<share-link>'   重启并使用新链接
  ./tmp-proxy.sh restart-last             使用上次链接重启
  ./tmp-proxy.sh status                   查看状态
  ./tmp-proxy.sh test                     测试本地代理
  ./tmp-proxy.sh env                      输出当前 shell 代理变量
  ./tmp-proxy.sh system-proxy enable      开启系统代理 profile
  ./tmp-proxy.sh system-proxy disable     关闭系统代理 profile
  ./tmp-proxy.sh system-proxy status      查看系统代理 profile
  ./tmp-proxy.sh user-proxy enable        开启当前用户代理 profile
  ./tmp-proxy.sh user-proxy disable       关闭当前用户代理 profile
  ./tmp-proxy.sh user-proxy status        查看当前用户代理 profile
  ./tmp-proxy.sh logs                     查看最近日志
  ./tmp-proxy.sh set-ports SOCKS HTTP     保存本地监听端口
  ./tmp-proxy.sh install-xray             下载/更新 Xray 二进制

环境变量:
  SOCKS_PORT=10808
  HTTP_PORT=10809
  XRAY_BIN=$SCRIPT_DIR/xray

示例:
  ./tmp-proxy.sh start 'vless://...'
  eval "\$(./tmp-proxy.sh env)"
EOF
}

pause() {
    echo
    read -r -p "按回车键继续..." _ || true
}

clear_screen() {
    if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
        clear
    fi
}

is_valid_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
}

save_settings() {
    mkdir -p "$STATE_DIR"
    {
        echo "SOCKS_PORT=$SOCKS_PORT"
        echo "HTTP_PORT=$HTTP_PORT"
    } > "$SETTINGS_FILE"
    chmod 600 "$SETTINGS_FILE" 2>/dev/null || true
}

save_last_link() {
    local link="$1"
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$link" > "$LAST_LINK_FILE"
    chmod 600 "$LAST_LINK_FILE" 2>/dev/null || true
}

get_last_link() {
    if [[ -r "$LAST_LINK_FILE" ]]; then
        sed -n '1p' "$LAST_LINK_FILE"
    fi
    return 0
}

current_node_summary() {
    if [[ -r "$SUMMARY_FILE" ]]; then
        sed -n '1p' "$SUMMARY_FILE"
    else
        echo "未加载"
    fi
}

xray_version() {
    if [[ -x "$XRAY_BIN" ]]; then
        "$XRAY_BIN" version 2>/dev/null | head -n1
    else
        echo "未安装"
    fi
}

proxy_exports() {
    cat <<EOF
export http_proxy=http://127.0.0.1:${HTTP_PORT}
export https_proxy=http://127.0.0.1:${HTTP_PORT}
export HTTP_PROXY=http://127.0.0.1:${HTTP_PORT}
export HTTPS_PROXY=http://127.0.0.1:${HTTP_PORT}
export all_proxy=socks5h://127.0.0.1:${SOCKS_PORT}
export ALL_PROXY=socks5h://127.0.0.1:${SOCKS_PORT}
EOF
}

detect_os_family() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-} ${ID_LIKE:-}" in
            *alpine*) echo "alpine"; return ;;
            *debian*|*ubuntu*) echo "debian"; return ;;
            *centos*|*rhel*|*rocky*|*almalinux*|*fedora*) echo "rhel"; return ;;
        esac
    fi

    if command -v apk >/dev/null 2>&1; then
        echo "alpine"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "debian"
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

install_packages() {
    local family packages
    family="$(detect_os_family)"
    packages=("$@")

    case "$family" in
        alpine)
            apk add --no-cache "${packages[@]}"
            ;;
        debian)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
            ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y --allowerasing "${packages[@]}"
            else
                yum install -y "${packages[@]}"
            fi
            ;;
        *)
            log_error "Unsupported package manager. Please install dependencies manually: ${packages[*]}"
            return 1
            ;;
    esac
}

ensure_command() {
    local cmd="$1"
    shift
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    log_warn "Missing command: $cmd. Installing: $*"
    install_packages "$@"
}

ensure_runtime_dependencies() {
    ensure_command python3 python3
}

ensure_download_dependencies() {
    ensure_command curl curl ca-certificates
    ensure_command unzip unzip
    ensure_command python3 python3
}

xray_asset_name() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    if [[ "$os" != "Linux" ]]; then
        log_error "This helper currently downloads Linux Xray assets only."
        return 1
    fi

    case "$arch" in
        x86_64|amd64) echo "Xray-linux-64.zip" ;;
        i386|i686) echo "Xray-linux-32.zip" ;;
        aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
        armv7l|armv7*) echo "Xray-linux-arm32-v7a.zip" ;;
        armv6l) echo "Xray-linux-arm32-v6.zip" ;;
        armv5*) echo "Xray-linux-arm32-v5.zip" ;;
        riscv64) echo "Xray-linux-riscv64.zip" ;;
        s390x) echo "Xray-linux-s390x.zip" ;;
        ppc64le) echo "Xray-linux-ppc64le.zip" ;;
        ppc64) echo "Xray-linux-ppc64.zip" ;;
        loongarch64|loong64) echo "Xray-linux-loong64.zip" ;;
        mips64le) echo "Xray-linux-mips64le.zip" ;;
        mips64) echo "Xray-linux-mips64.zip" ;;
        mipsle) echo "Xray-linux-mips32le.zip" ;;
        mips) echo "Xray-linux-mips32.zip" ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac
}

latest_xray_tag() {
    curl -fsSL --connect-timeout 15 https://api.github.com/repos/XTLS/Xray-core/releases/latest |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n1
}

install_xray() {
    ensure_download_dependencies

    local tag asset url tmp
    tag="$(latest_xray_tag || true)"
    if [[ -z "$tag" ]]; then
        log_error "Unable to get latest Xray release tag."
        return 1
    fi

    asset="$(xray_asset_name)"
    url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"
    tmp="$(mktemp -d /tmp/tmp-proxy-xray.XXXXXX)"

    log_info "Downloading Xray ${tag}: $asset"
    curl -fL -o "$tmp/xray.zip" "$url"
    unzip -oq "$tmp/xray.zip" -d "$tmp"

    if [[ ! -f "$tmp/xray" ]]; then
        rm -rf "$tmp"
        log_error "Downloaded archive does not contain xray binary."
        return 1
    fi

    install -m 755 "$tmp/xray" "$SCRIPT_DIR/xray"
    [[ -f "$tmp/geoip.dat" ]] && install -m 644 "$tmp/geoip.dat" "$SCRIPT_DIR/geoip.dat"
    [[ -f "$tmp/geosite.dat" ]] && install -m 644 "$tmp/geosite.dat" "$SCRIPT_DIR/geosite.dat"
    rm -rf "$tmp"

    log_success "Xray installed: $SCRIPT_DIR/xray"
    "$SCRIPT_DIR/xray" version | head -n1 || true
}

menu_install_xray() {
    local choice

    echo
    if [[ -x "$XRAY_BIN" ]]; then
        echo "完整包已自带 Xray，通常不需要执行此项。"
        echo "当前版本: $(xray_version)"
        echo
        echo "只有在以下情况才建议继续："
        echo "1) 想更新到 GitHub 上的最新版 Xray"
        echo "2) 本地 xray 文件损坏或误删"
        echo "3) 你手动换过目录，需要重新下载"
        echo
        read -r -p "继续从 GitHub 下载/覆盖 Xray？[y/N]: " choice || true
        case "$choice" in
            y|Y|yes|YES)
                install_xray
                ;;
            *)
                log_warn "已取消。直接选择 1 启动代理即可。"
                ;;
        esac
    else
        log_warn "当前目录未找到 Xray，将尝试下载。"
        install_xray
    fi
}

ensure_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        return 0
    fi
    log_warn "Xray binary not found at $XRAY_BIN"
    install_xray
}

read_pid() {
    local pid
    [[ -r "$PID_FILE" ]] || return 1
    pid="$(sed -n '1p' "$PID_FILE" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    echo "$pid"
}

pid_matches_xray() {
    local pid="$1"
    local cmdline

    if [[ ! -r "/proc/$pid/cmdline" ]]; then
        return 1
    fi

    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ "$cmdline" == *"xray"* && "$cmdline" == *"$CONFIG_FILE"* ]]
}

is_running() {
    local pid
    pid="$(read_pid)" || return 1
    kill -0 "$pid" >/dev/null 2>&1 || return 1
    pid_matches_xray "$pid"
}

stop_proxy() {
    if is_running; then
        local pid
        pid="$(read_pid)"
        log_info "正在停止 Xray 进程：$pid"
        kill "$pid" >/dev/null 2>&1 || true
        sleep 1
        if kill -0 "$pid" >/dev/null 2>&1; then
            kill -9 "$pid" >/dev/null 2>&1 || true
        fi
        rm -f "$PID_FILE"
        log_success "代理已停止。"
    else
        rm -f "$PID_FILE"
        log_warn "没有发现正在运行的 tmp-proxy 进程。"
    fi
}

print_env() {
    proxy_exports
}

generate_system_proxy_profile() {
    cat <<EOF
# tmp-proxy system proxy profile
# Generated by $SCRIPT_DIR/tmp-proxy.sh
# Source manually in the current shell with:
#   source $SYSTEM_PROXY_FILE

$(proxy_exports)
EOF
}

generate_user_proxy_profile() {
    cat <<EOF
# tmp-proxy user proxy profile
# Generated by $SCRIPT_DIR/tmp-proxy.sh
# Source manually in the current shell with:
#   source $USER_PROXY_FILE

$(proxy_exports)
EOF
}

remove_managed_block() {
    local file="$1"
    local tmp

    [[ -f "$file" ]] || return 0
    tmp="$(mktemp /tmp/tmp-proxy-rc.XXXXXX)"
    awk '
        /^# >>> tmp-proxy user proxy >>>$/ {skip=1; next}
        /^# <<< tmp-proxy user proxy <<<$/{skip=0; next}
        skip != 1 {print}
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

ensure_user_proxy_rc_block() {
    mkdir -p "$(dirname "$USER_PROXY_RC_FILE")"
    touch "$USER_PROXY_RC_FILE"
    remove_managed_block "$USER_PROXY_RC_FILE"
    {
        echo
        echo "# >>> tmp-proxy user proxy >>>"
        echo "[ -r \"$USER_PROXY_FILE\" ] && . \"$USER_PROXY_FILE\""
        echo "# <<< tmp-proxy user proxy <<<"
    } >> "$USER_PROXY_RC_FILE"
}

require_root_for_system_proxy() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log_error "写入系统代理需要 root 权限。请用 root 或 sudo 运行。"
        echo "示例: sudo ./tmp-proxy.sh system-proxy enable"
        return 1
    fi
}

system_proxy_enabled() {
    [[ -f "$SYSTEM_PROXY_FILE" ]]
}

user_proxy_enabled() {
    [[ -f "$USER_PROXY_FILE" ]] && [[ -f "$USER_PROXY_RC_FILE" ]] && grep -Fq "$USER_PROXY_FILE" "$USER_PROXY_RC_FILE"
}

proxy_scope_summary() {
    local root_status user_status
    if system_proxy_enabled; then
        root_status="root 已启用"
    else
        root_status="root 未启用"
    fi

    if user_proxy_enabled; then
        user_status="用户已启用"
    else
        user_status="用户未启用"
    fi

    echo "${root_status} | ${user_status}"
}

sync_system_proxy_if_enabled() {
    if ! system_proxy_enabled; then
        return 0
    fi

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log_warn "系统代理文件已存在，但当前不是 root，无法同步端口：$SYSTEM_PROXY_FILE"
        return 0
    fi

    generate_system_proxy_profile > "$SYSTEM_PROXY_FILE"
    chmod 644 "$SYSTEM_PROXY_FILE"
    log_success "系统代理端口已同步：HTTP ${HTTP_PORT} / SOCKS ${SOCKS_PORT}"
}

sync_user_proxy_if_enabled() {
    if ! user_proxy_enabled; then
        return 0
    fi

    mkdir -p "$(dirname "$USER_PROXY_FILE")"
    generate_user_proxy_profile > "$USER_PROXY_FILE"
    chmod 600 "$USER_PROXY_FILE" 2>/dev/null || true
    log_success "用户级代理端口已同步：HTTP ${HTTP_PORT} / SOCKS ${SOCKS_PORT}"
}

enable_system_proxy() {
    require_root_for_system_proxy || return 1
    if ! is_running; then
        log_warn "当前本地代理未运行。系统代理开启后，请先启动代理再使用网络命令。"
    fi
    mkdir -p "$(dirname "$SYSTEM_PROXY_FILE")"
    generate_system_proxy_profile > "$SYSTEM_PROXY_FILE"
    chmod 644 "$SYSTEM_PROXY_FILE"
    log_success "系统代理已写入：$SYSTEM_PROXY_FILE"
    echo
    echo "新登录 shell 会自动加载。当前 shell 立即生效请执行："
    echo "source $SYSTEM_PROXY_FILE"
}

disable_system_proxy() {
    require_root_for_system_proxy || return 1
    if system_proxy_enabled; then
        rm -f "$SYSTEM_PROXY_FILE"
        log_success "系统代理已删除：$SYSTEM_PROXY_FILE"
    else
        log_warn "系统代理未启用：$SYSTEM_PROXY_FILE"
    fi
    echo
    echo "如果当前 shell 已经 source 过代理变量，可手动取消："
    echo "unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY"
}

enable_user_proxy() {
    if ! is_running; then
        log_warn "当前本地代理未运行。用户级代理开启后，请先启动代理再使用网络命令。"
    fi

    mkdir -p "$(dirname "$USER_PROXY_FILE")"
    generate_user_proxy_profile > "$USER_PROXY_FILE"
    chmod 600 "$USER_PROXY_FILE" 2>/dev/null || true
    ensure_user_proxy_rc_block
    log_success "用户级代理已启用。"
    echo "代理变量文件: $USER_PROXY_FILE"
    echo "自动加载文件: $USER_PROXY_RC_FILE"
    echo
    echo "新开的 shell 会自动加载。当前 shell 立即生效请执行："
    echo "source $USER_PROXY_FILE"
}

disable_user_proxy() {
    remove_managed_block "$USER_PROXY_RC_FILE"
    if [[ -f "$USER_PROXY_FILE" ]]; then
        rm -f "$USER_PROXY_FILE"
    fi
    log_success "用户级代理已关闭。"
    echo "已移除自动加载配置: $USER_PROXY_RC_FILE"
    echo
    echo "如果当前 shell 已经加载过代理变量，可手动取消："
    echo "unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY"
}

show_system_proxy_status() {
    if system_proxy_enabled; then
        log_success "系统代理已启用：$SYSTEM_PROXY_FILE"
        echo
        sed -n '1,80p' "$SYSTEM_PROXY_FILE"
    else
        log_warn "系统代理未启用：$SYSTEM_PROXY_FILE"
        echo
        echo "当前端口对应的变量为："
        proxy_exports
    fi
}

show_user_proxy_status() {
    if user_proxy_enabled; then
        log_success "用户级代理已启用。"
        echo "代理变量文件: $USER_PROXY_FILE"
        echo "自动加载文件: $USER_PROXY_RC_FILE"
        echo
        sed -n '1,80p' "$USER_PROXY_FILE"
        echo
        echo "自动加载片段:"
        sed -n '/# >>> tmp-proxy user proxy >>>/,/# <<< tmp-proxy user proxy <<</p' "$USER_PROXY_RC_FILE"
    else
        log_warn "用户级代理未启用。"
        echo "代理变量文件: $USER_PROXY_FILE"
        echo "自动加载文件: $USER_PROXY_RC_FILE"
        echo
        echo "当前端口对应的变量为："
        proxy_exports
    fi
}

manage_root_proxy() {
    local choice
    while true; do
        echo
        echo "============================================================"
        echo "                    Root 级别系统代理"
        echo "============================================================"
        if system_proxy_enabled; then
            echo -e "状态     : ${GREEN}已启用${NC}"
        else
            echo -e "状态     : ${YELLOW}未启用${NC}"
        fi
        if is_running; then
            echo -e "本地代理 : ${GREEN}运行中${NC}"
        else
            echo -e "本地代理 : ${YELLOW}未运行${NC}，启用系统代理前建议先启动代理"
        fi
        echo "配置文件 : $SYSTEM_PROXY_FILE"
        echo "HTTP     : http://127.0.0.1:${HTTP_PORT}"
        echo "SOCKS    : socks5h://127.0.0.1:${SOCKS_PORT}"
        echo "------------------------------------------------------------"
        echo "  1) 开启/同步 root 级别代理"
        echo "  2) 关闭 root 级别代理"
        echo "  3) 查看 root 级别代理文件"
        echo "  0) 返回"
        echo "============================================================"
        read -r -p "请选择: " choice || choice=0
        case "$choice" in
            1)
                enable_system_proxy || true
                pause
                ;;
            2)
                disable_system_proxy || true
                pause
                ;;
            3)
                show_system_proxy_status || true
                pause
                ;;
            0|q|Q)
                return 0
                ;;
            *)
                log_warn "无效选项。"
                pause
                ;;
        esac
    done
}

manage_user_proxy() {
    local choice
    while true; do
        echo
        echo "============================================================"
        echo "                    普通用户级别代理"
        echo "============================================================"
        if user_proxy_enabled; then
            echo -e "状态     : ${GREEN}已启用${NC}"
        else
            echo -e "状态     : ${YELLOW}未启用${NC}"
        fi
        if is_running; then
            echo -e "本地代理 : ${GREEN}运行中${NC}"
        else
            echo -e "本地代理 : ${YELLOW}未运行${NC}，启用用户级代理前建议先启动代理"
        fi
        echo "代理文件 : $USER_PROXY_FILE"
        echo "加载文件 : $USER_PROXY_RC_FILE"
        echo "HTTP     : http://127.0.0.1:${HTTP_PORT}"
        echo "SOCKS    : socks5h://127.0.0.1:${SOCKS_PORT}"
        echo "------------------------------------------------------------"
        echo "  1) 开启/同步当前用户代理"
        echo "  2) 关闭当前用户代理"
        echo "  3) 查看当前用户代理文件"
        echo "  0) 返回"
        echo "============================================================"
        read -r -p "请选择: " choice || choice=0
        case "$choice" in
            1)
                enable_user_proxy || true
                pause
                ;;
            2)
                disable_user_proxy || true
                pause
                ;;
            3)
                show_user_proxy_status || true
                pause
                ;;
            0|q|Q)
                return 0
                ;;
            *)
                log_warn "无效选项。"
                pause
                ;;
        esac
    done
}

manage_proxy_environment() {
    local choice
    while true; do
        echo
        echo "============================================================"
        echo "                      代理环境管理"
        echo "============================================================"
        echo "Root 级别   : $(system_proxy_enabled && echo "已启用" || echo "未启用")"
        echo "用户级别    : $(user_proxy_enabled && echo "已启用" || echo "未启用")"
        echo "当前 shell  : 手动执行 eval 后生效"
        echo "HTTP        : http://127.0.0.1:${HTTP_PORT}"
        echo "SOCKS       : socks5h://127.0.0.1:${SOCKS_PORT}"
        echo "------------------------------------------------------------"
        echo "  1) Root 级别系统代理（写入 /etc/profile.d，需要 root）"
        echo "  2) 普通用户级别代理（写入当前用户 shell 配置，不需要 root）"
        echo "  3) 当前 shell 临时生效（不写文件，不需要 root）"
        echo "  0) 返回主菜单"
        echo "============================================================"
        read -r -p "请选择: " choice || choice=0
        case "$choice" in
            1)
                manage_root_proxy || true
                ;;
            2)
                manage_user_proxy || true
                ;;
            3)
                show_env_help || true
                pause
                ;;
            0|q|Q)
                return 0
                ;;
            *)
                log_warn "无效选项。"
                pause
                ;;
        esac
    done
}

generate_config() {
    local link="$1"
    mkdir -p "$WORK_DIR"
    LINK="$link" \
    CONFIG_FILE="$CONFIG_FILE" \
    SUMMARY_FILE="$SUMMARY_FILE" \
    SOCKS_PORT="$SOCKS_PORT" \
    HTTP_PORT="$HTTP_PORT" \
    python3 <<'PY'
import base64
import json
import os
import sys
import urllib.parse

link = os.environ["LINK"].strip()
config_file = os.environ["CONFIG_FILE"]
summary_file = os.environ["SUMMARY_FILE"]
socks_port = int(os.environ.get("SOCKS_PORT", "10808"))
http_port = int(os.environ.get("HTTP_PORT", "10809"))


def die(message):
    print(f"[ERROR] {message}", file=sys.stderr)
    sys.exit(1)


def b64decode_text(value):
    value = value.strip()
    value += "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value.encode()).decode()


def first(query, key, default=""):
    values = query.get(key)
    if not values:
        return default
    return values[0]


def split_host_port(value):
    value = urllib.parse.unquote(value)
    if value.startswith("["):
        end = value.find("]")
        if end < 0:
            die(f"Invalid IPv6 host: {value}")
        host = value[1:end]
        rest = value[end + 1:]
        if not rest.startswith(":"):
            die(f"Missing port: {value}")
        return host, int(rest[1:])

    if ":" not in value:
        die(f"Missing port: {value}")
    host, port = value.rsplit(":", 1)
    return host, int(port)


def add_stream_settings(outbound, query, default_network="tcp"):
    network = first(query, "type", default_network) or default_network
    security = first(query, "security", "none") or "none"
    stream = {"network": network, "security": security}

    if security == "tls":
        tls = {}
        sni = first(query, "sni") or first(query, "peer")
        fp = first(query, "fp")
        alpn = first(query, "alpn")
        if sni:
            tls["serverName"] = sni
        if fp:
            tls["fingerprint"] = fp
        if alpn:
            tls["alpn"] = [x for x in alpn.split(",") if x]
        stream["tlsSettings"] = tls
    elif security == "reality":
        reality = {}
        sni = first(query, "sni")
        fp = first(query, "fp")
        pbk = first(query, "pbk")
        sid = first(query, "sid")
        spx = first(query, "spx")
        if sni:
            reality["serverName"] = sni
        if fp:
            reality["fingerprint"] = fp
        if pbk:
            reality["publicKey"] = pbk
        if sid:
            reality["shortId"] = sid
        if spx:
            reality["spiderX"] = spx
        stream["realitySettings"] = reality

    if network == "ws":
        ws = {"path": first(query, "path", "/") or "/"}
        host = first(query, "host")
        if host:
            ws["headers"] = {"Host": host}
        stream["wsSettings"] = ws
    elif network == "grpc":
        service_name = first(query, "serviceName") or first(query, "service")
        stream["grpcSettings"] = {"serviceName": service_name}
    elif network == "tcp":
        header_type = first(query, "headerType")
        if header_type and header_type != "none":
            stream["tcpSettings"] = {"header": {"type": header_type}}

    outbound["streamSettings"] = stream


def parse_vless(parsed, query):
    uuid = urllib.parse.unquote(parsed.username or "")
    if not uuid:
        die("VLESS link missing UUID")
    if parsed.hostname is None or parsed.port is None:
        die("VLESS link missing host or port")

    user = {"id": uuid, "encryption": first(query, "encryption", "none") or "none"}
    flow = first(query, "flow")
    if flow:
        user["flow"] = flow

    outbound = {
        "tag": "proxy",
        "protocol": "vless",
        "settings": {
            "vnext": [
                {
                    "address": parsed.hostname,
                    "port": parsed.port,
                    "users": [user],
                }
            ]
        },
    }
    add_stream_settings(outbound, query, "tcp")
    return outbound, f"VLESS {parsed.hostname}:{parsed.port}"


def parse_trojan(parsed, query):
    password = urllib.parse.unquote(parsed.username or "")
    if not password:
        die("Trojan link missing password")
    if parsed.hostname is None or parsed.port is None:
        die("Trojan link missing host or port")

    outbound = {
        "tag": "proxy",
        "protocol": "trojan",
        "settings": {
            "servers": [
                {
                    "address": parsed.hostname,
                    "port": parsed.port,
                    "password": password,
                }
            ]
        },
    }
    add_stream_settings(outbound, query, "tcp")
    return outbound, f"Trojan {parsed.hostname}:{parsed.port}"


def parse_ss(link):
    raw = link[len("ss://"):]
    raw = raw.split("#", 1)[0]
    raw = raw.split("?", 1)[0]

    if "@" in raw:
        userinfo, server_part = raw.rsplit("@", 1)
        decoded_userinfo = urllib.parse.unquote(userinfo)
        if ":" in decoded_userinfo:
            method, password = decoded_userinfo.split(":", 1)
        else:
            decoded = b64decode_text(userinfo)
            method, password = decoded.split(":", 1)
        host, port = split_host_port(server_part)
    else:
        decoded = b64decode_text(raw)
        if "@" not in decoded:
            die("Invalid legacy ss:// link")
        userinfo, server_part = decoded.rsplit("@", 1)
        method, password = userinfo.split(":", 1)
        host, port = split_host_port(server_part)

    outbound = {
        "tag": "proxy",
        "protocol": "shadowsocks",
        "settings": {
            "servers": [
                {
                    "address": host,
                    "port": port,
                    "method": method,
                    "password": password,
                    "uot": True,
                }
            ]
        },
    }
    return outbound, f"Shadowsocks {host}:{port}"


def parse_vmess(link):
    raw = link[len("vmess://"):]
    raw = raw.split("#", 1)[0]
    raw = raw.split("?", 1)[0]
    data = json.loads(b64decode_text(raw))
    host = data.get("add")
    port = int(data.get("port", 0))
    uuid = data.get("id")
    if not host or not port or not uuid:
        die("VMess link missing host, port or id")

    user = {
        "id": uuid,
        "alterId": int(data.get("aid", 0) or 0),
        "security": data.get("scy") or data.get("security") or "auto",
    }
    outbound = {
        "tag": "proxy",
        "protocol": "vmess",
        "settings": {
            "vnext": [
                {
                    "address": host,
                    "port": port,
                    "users": [user],
                }
            ]
        },
    }
    query = {
        "type": [data.get("net") or "tcp"],
        "security": [data.get("tls") or "none"],
        "sni": [data.get("sni") or data.get("host") or ""],
        "fp": [data.get("fp") or ""],
        "path": [data.get("path") or "/"],
        "host": [data.get("host") or ""],
        "serviceName": [data.get("path") or ""],
    }
    add_stream_settings(outbound, query, data.get("net") or "tcp")
    return outbound, f"VMess {host}:{port}"


parsed = urllib.parse.urlsplit(link)
scheme = parsed.scheme.lower()
query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)

if scheme == "vless":
    outbound, summary = parse_vless(parsed, query)
elif scheme == "ss":
    outbound, summary = parse_ss(link)
elif scheme == "trojan":
    outbound, summary = parse_trojan(parsed, query)
elif scheme == "vmess":
    outbound, summary = parse_vmess(link)
else:
    die(f"Unsupported link scheme: {scheme}")

config = {
    "log": {"loglevel": "warning"},
    "inbounds": [
        {
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "port": socks_port,
            "protocol": "socks",
            "settings": {"udp": True},
        },
        {
            "tag": "http-in",
            "listen": "127.0.0.1",
            "port": http_port,
            "protocol": "http",
            "settings": {},
        },
    ],
    "outbounds": [
        outbound,
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"},
    ],
}

with open(config_file, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write("\n")

with open(summary_file, "w", encoding="utf-8") as f:
    f.write(summary + "\n")
PY
}

show_started_message() {
    log_success "代理已启动。"
    [[ -f "$SUMMARY_FILE" ]] && echo "节点: $(cat "$SUMMARY_FILE")"
    echo "SOCKS: 127.0.0.1:${SOCKS_PORT}"
    echo "HTTP : 127.0.0.1:${HTTP_PORT}"
    echo
    echo "当前 shell 临时启用："
    echo "eval \"\$(./tmp-proxy.sh env)\""
    echo
    echo "新登录 shell 自动启用：菜单 9 选择 root 级别或普通用户级别"
}

start_background() {
    local link="$1"
    ensure_runtime_dependencies
    ensure_xray
    stop_proxy >/dev/null 2>&1 || true
    generate_config "$link"

    "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null
    save_last_link "$link"
    nohup "$XRAY_BIN" run -config "$CONFIG_FILE" >"$LOG_FILE" 2>&1 &
    echo "$!" > "$PID_FILE"
    sleep 1

    if ! is_running; then
        log_error "Xray 启动失败，最近日志如下："
        tail -n 80 "$LOG_FILE" 2>/dev/null || true
        return 1
    fi

    show_started_message
}

run_foreground() {
    local link="$1"
    ensure_runtime_dependencies
    ensure_xray
    generate_config "$link"
    "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null
    save_last_link "$link"
    show_started_message
    echo "前台运行中，按 Ctrl+C 停止。"
    exec "$XRAY_BIN" run -config "$CONFIG_FILE"
}

restart_last() {
    local link
    link="$(get_last_link)"
    if [[ -z "$link" ]]; then
        log_error "没有保存的上次节点链接，请先启动一次。"
        return 1
    fi
    stop_proxy >/dev/null 2>&1 || true
    start_background "$link"
}

status_proxy() {
    if is_running; then
        log_success "代理运行中，PID=$(read_pid)"
        [[ -f "$SUMMARY_FILE" ]] && echo "节点: $(cat "$SUMMARY_FILE")"
        echo "SOCKS: 127.0.0.1:${SOCKS_PORT}"
        echo "HTTP : 127.0.0.1:${HTTP_PORT}"
    else
        log_warn "代理未运行。"
    fi
}

show_status_detail() {
    status_proxy
    echo
    echo "Xray: $(xray_version)"
    echo "工作目录: $WORK_DIR"
    echo "状态目录: $STATE_DIR"
    echo "配置文件: $CONFIG_FILE"
    echo "日志文件: $LOG_FILE"
    echo "代理环境: $(proxy_scope_summary)"
    echo "Root 文件: $SYSTEM_PROXY_FILE"
    echo "用户文件: $USER_PROXY_FILE"
    if [[ -r "$LAST_LINK_FILE" ]]; then
        echo "上次节点: 已保存"
    else
        echo "上次节点: 未保存"
    fi
}

show_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        echo "===== $LOG_FILE ====="
        tail -n 80 "$LOG_FILE"
    else
        log_warn "暂无日志。"
    fi
}

test_proxy() {
    if ! is_running; then
        log_error "Proxy is not running."
        return 1
    fi
    ensure_command curl curl ca-certificates

    echo "正在测试 SOCKS 代理..."
    curl --socks5-hostname "127.0.0.1:${SOCKS_PORT}" -fsSIL --connect-timeout 10 --max-time 25 \
        https://www.gstatic.com/generate_204 | sed -n '1,8p'
    echo
    echo "出口 IP:"
    if ! curl --socks5-hostname "127.0.0.1:${SOCKS_PORT}" -fsSL --connect-timeout 8 --max-time 15 \
        https://api.ipify.org; then
        curl --socks5-hostname "127.0.0.1:${SOCKS_PORT}" -fsSL --connect-timeout 8 --max-time 15 \
            https://ifconfig.me/ip || log_warn "无法查询出口 IP，但 204 连通性测试已通过。"
    fi
    echo
}

set_ports() {
    local socks_port="${1:-}"
    local http_port="${2:-}"

    if ! is_valid_port "$socks_port" || ! is_valid_port "$http_port"; then
        log_error "端口必须是 1-65535 的数字。"
        return 1
    fi

    if [[ "$socks_port" == "$http_port" ]]; then
        log_error "SOCKS 和 HTTP 端口不能相同。"
        return 1
    fi

    SOCKS_PORT="$socks_port"
    HTTP_PORT="$http_port"
    save_settings
    log_success "端口已保存：SOCKS ${SOCKS_PORT} / HTTP ${HTTP_PORT}"
    sync_system_proxy_if_enabled
    sync_user_proxy_if_enabled
    if is_running; then
        log_warn "当前运行中的代理需要重启后才会使用新端口。"
    fi
}

prompt_start_link() {
    local link
    echo
    read -r -p "请输入 vless/ss/trojan/vmess 链接，直接回车取消: " link || true
    if [[ -z "$link" ]]; then
        log_warn "已取消。"
        return 0
    fi
    start_background "$link"
}

prompt_set_ports() {
    local socks_port http_port restart_choice
    echo
    read -r -p "SOCKS 端口 [当前 ${SOCKS_PORT}]: " socks_port || true
    read -r -p "HTTP 端口 [当前 ${HTTP_PORT}]: " http_port || true

    socks_port="${socks_port:-$SOCKS_PORT}"
    http_port="${http_port:-$HTTP_PORT}"
    if ! set_ports "$socks_port" "$http_port"; then
        return 1
    fi

    if is_running; then
        echo
        read -r -p "是否立即用上次节点重启代理？[y/N]: " restart_choice || true
        case "$restart_choice" in
            y|Y|yes|YES)
                restart_last
                ;;
            *)
                log_warn "端口将在下次启动或重启后生效。"
                ;;
        esac
    fi
}

show_env_help() {
    echo "在当前 shell 使用代理，请执行："
    echo
    print_env
    echo
    echo "一键写入当前 shell："
    echo "eval \"\$(./tmp-proxy.sh env)\""
}

show_menu_header() {
    clear_screen

    echo "============================================================"
    echo "                      tmp-proxy 控制台"
    echo "============================================================"
    if is_running; then
        echo -e "代理状态 : ${GREEN}运行中${NC}  PID: $(read_pid)"
    else
        echo -e "代理状态 : ${YELLOW}未运行${NC}"
    fi
    echo "当前节点 : $(current_node_summary)"
    echo "本地端口 : HTTP 127.0.0.1:${HTTP_PORT} | SOCKS 127.0.0.1:${SOCKS_PORT}"
    echo "代理环境 : $(proxy_scope_summary)"
    echo "Xray     : $(xray_version)"
    echo "状态目录 : $STATE_DIR"
    echo "------------------------------------------------------------"
    echo "连接"
    echo "  1) 启动/更换代理链接"
    echo "  2) 使用上次链接重启"
    echo "  3) 停止代理"
    echo
    echo "日常"
    echo "  4) 查看状态/配置"
    echo "  5) 测试代理连通性"
    echo "  6) 显示当前 shell 代理命令"
    echo
    echo "配置"
    echo "  7) 查看日志"
    echo "  8) 修改本地端口"
    echo "  9) 代理环境管理"
    echo
    echo "维护"
    echo " 10) 检查/更新 Xray（可选）"
    echo "  0) 退出"
    echo "============================================================"
}

main_menu() {
    local choice
    while true; do
        show_menu_header
        read -r -p "请选择: " choice || choice=0
        case "$choice" in
            1)
                prompt_start_link || true
                pause
                ;;
            2)
                restart_last || true
                pause
                ;;
            3)
                stop_proxy || true
                pause
                ;;
            4)
                show_status_detail || true
                pause
                ;;
            5)
                test_proxy || true
                pause
                ;;
            6)
                show_env_help
                pause
                ;;
            7)
                show_logs
                pause
                ;;
            8)
                prompt_set_ports || true
                pause
                ;;
            9)
                manage_proxy_environment || true
                ;;
            10)
                menu_install_xray || true
                pause
                ;;
            0|q|Q)
                exit 0
                ;;
            *)
                log_warn "无效选项。"
                pause
                ;;
        esac
    done
}

require_link() {
    if [[ $# -lt 1 || -z "${1:-}" ]]; then
        log_error "Missing share link."
        usage
        exit 1
    fi
}

main() {
    local command="${1:-menu}"
    shift || true

    case "$command" in
        menu)
            main_menu
            ;;
        start)
            require_link "$@"
            start_background "$1"
            ;;
        run)
            require_link "$@"
            run_foreground "$1"
            ;;
        restart)
            require_link "$@"
            stop_proxy || true
            start_background "$1"
            ;;
        restart-last)
            restart_last
            ;;
        stop)
            stop_proxy
            ;;
        status)
            show_status_detail
            ;;
        test)
            test_proxy
            ;;
        env)
            print_env
            ;;
        system-proxy)
            case "${1:-status}" in
                enable|on)
                    enable_system_proxy
                    ;;
                disable|off)
                    disable_system_proxy
                    ;;
                status)
                    show_system_proxy_status
                    ;;
                *)
                    log_error "Usage: ./tmp-proxy.sh system-proxy enable|disable|status"
                    exit 1
                    ;;
            esac
            ;;
        user-proxy)
            case "${1:-status}" in
                enable|on)
                    enable_user_proxy
                    ;;
                disable|off)
                    disable_user_proxy
                    ;;
                status)
                    show_user_proxy_status
                    ;;
                *)
                    log_error "Usage: ./tmp-proxy.sh user-proxy enable|disable|status"
                    exit 1
                    ;;
            esac
            ;;
        logs)
            show_logs
            ;;
        set-ports)
            if [[ $# -ne 2 ]]; then
                log_error "Usage: ./tmp-proxy.sh set-ports SOCKS HTTP"
                exit 1
            fi
            set_ports "$1" "$2"
            ;;
        install-xray)
            install_xray
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
