#!/usr/bin/env bash

# Temporary proxy launcher based on Xray-Core.
# Supports common vless://, ss://, trojan:// and vmess:// share links.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XRAY_BIN="${XRAY_BIN:-$SCRIPT_DIR/xray}"
WORK_DIR="${TMP_PROXY_WORK_DIR:-/tmp/tmp-proxy}"
CONFIG_FILE="$WORK_DIR/config.json"
SUMMARY_FILE="$WORK_DIR/summary.txt"
PID_FILE="$WORK_DIR/xray.pid"
LOG_FILE="$WORK_DIR/xray.log"
SOCKS_PORT="${SOCKS_PORT:-10808}"
HTTP_PORT="${HTTP_PORT:-10809}"

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
tmp-proxy - temporary local proxy powered by Xray

Usage:
  ./tmp-proxy.sh start '<share-link>'     Start in background
  ./tmp-proxy.sh run '<share-link>'       Run in foreground
  ./tmp-proxy.sh stop                     Stop background proxy
  ./tmp-proxy.sh restart '<share-link>'   Restart in background
  ./tmp-proxy.sh status                   Show status
  ./tmp-proxy.sh test                     Test local SOCKS proxy
  ./tmp-proxy.sh env                      Print proxy env exports
  ./tmp-proxy.sh install-xray             Download/update Xray binary

Environment:
  SOCKS_PORT=10808
  HTTP_PORT=10809
  XRAY_BIN=$SCRIPT_DIR/xray

Example:
  ./tmp-proxy.sh start 'vless://...'
  export ALL_PROXY=socks5h://127.0.0.1:10808
  export HTTPS_PROXY=socks5h://127.0.0.1:10808
  export HTTP_PROXY=socks5h://127.0.0.1:10808
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

ensure_dependencies() {
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
    ensure_dependencies

    local tag asset url tmp
    tag="$(latest_xray_tag)"
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

ensure_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        return 0
    fi
    log_warn "Xray binary not found at $XRAY_BIN"
    install_xray
}

is_running() {
    [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1
}

stop_proxy() {
    if is_running; then
        local pid
        pid="$(cat "$PID_FILE")"
        log_info "Stopping Xray process: $pid"
        kill "$pid" >/dev/null 2>&1 || true
        sleep 1
        if kill -0 "$pid" >/dev/null 2>&1; then
            kill -9 "$pid" >/dev/null 2>&1 || true
        fi
        rm -f "$PID_FILE"
        log_success "Stopped."
    else
        rm -f "$PID_FILE"
        log_warn "No running tmp-proxy process found."
    fi
}

print_env() {
    cat <<EOF
export ALL_PROXY=socks5h://127.0.0.1:${SOCKS_PORT}
export HTTPS_PROXY=socks5h://127.0.0.1:${SOCKS_PORT}
export HTTP_PROXY=socks5h://127.0.0.1:${SOCKS_PORT}
EOF
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
    log_success "Temporary proxy is ready."
    [[ -f "$SUMMARY_FILE" ]] && echo "节点: $(cat "$SUMMARY_FILE")"
    echo "SOCKS: 127.0.0.1:${SOCKS_PORT}"
    echo "HTTP : 127.0.0.1:${HTTP_PORT}"
    echo
    echo "Use these variables in the current shell:"
    print_env
}

start_background() {
    local link="$1"
    ensure_dependencies
    ensure_xray
    stop_proxy >/dev/null 2>&1 || true
    generate_config "$link"

    "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null
    nohup "$XRAY_BIN" run -config "$CONFIG_FILE" >"$LOG_FILE" 2>&1 &
    echo "$!" > "$PID_FILE"
    sleep 1

    if ! is_running; then
        log_error "Xray failed to start. Log:"
        tail -n 80 "$LOG_FILE" 2>/dev/null || true
        return 1
    fi

    show_started_message
}

run_foreground() {
    local link="$1"
    ensure_dependencies
    ensure_xray
    generate_config "$link"
    "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null
    show_started_message
    echo "Running in foreground. Press Ctrl+C to stop."
    exec "$XRAY_BIN" run -config "$CONFIG_FILE"
}

status_proxy() {
    if is_running; then
        log_success "Running, pid=$(cat "$PID_FILE")"
        [[ -f "$SUMMARY_FILE" ]] && echo "节点: $(cat "$SUMMARY_FILE")"
        echo "SOCKS: 127.0.0.1:${SOCKS_PORT}"
        echo "HTTP : 127.0.0.1:${HTTP_PORT}"
    else
        log_warn "Not running."
    fi

    if [[ -f "$LOG_FILE" ]]; then
        echo
        echo "Recent log:"
        tail -n 20 "$LOG_FILE" || true
    fi
}

test_proxy() {
    if ! is_running; then
        log_error "Proxy is not running."
        return 1
    fi
    ensure_command curl curl ca-certificates

    echo "Testing SOCKS proxy..."
    curl --socks5-hostname "127.0.0.1:${SOCKS_PORT}" -fsSIL --connect-timeout 10 --max-time 25 \
        https://www.gstatic.com/generate_204 | sed -n '1,8p'
    echo
    echo "Proxy exit IP:"
    curl --socks5-hostname "127.0.0.1:${SOCKS_PORT}" -fsSL --connect-timeout 10 --max-time 25 \
        https://ifconfig.me/ip || true
    echo
}

require_link() {
    if [[ $# -lt 1 || -z "${1:-}" ]]; then
        log_error "Missing share link."
        usage
        exit 1
    fi
}

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
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
        stop)
            stop_proxy
            ;;
        status)
            status_proxy
            ;;
        test)
            test_proxy
            ;;
        env)
            print_env
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
