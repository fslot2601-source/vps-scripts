#!/usr/bin/env bash
# Snell 5.0.1 installer — Debian 11+ / Ubuntu 22.04+, systemd, public IPv4.
set -Eeuo pipefail
umask 077
export LC_ALL=C
readonly SNELL_VERSION=5.0.1
readonly BIN=/usr/local/bin/snell-server
readonly CONF_DIR=/etc/snell
readonly UNIT=/etc/systemd/system/snell.service
WORK=''
CREATED=0
CONF_CREATED=0
OWNED_FILES=()
DONE=0

info() { printf '\n%s\n' "$*"; }
fail() { printf '\n错误：%s\n' "$*" >&2; exit 1; }
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ $CREATED == 1 && $DONE == 0 ]]; then
        local file
        for file in "${OWNED_FILES[@]}"; do
            if [[ $file == "$UNIT" ]]; then
                systemctl disable --now snell.service >/dev/null 2>&1 || true
            fi
        done
        for file in "${OWNED_FILES[@]}"; do rm -f -- "$file"; done
        if [[ $CONF_CREATED == 1 ]]; then rmdir -- "$CONF_DIR" 2>/dev/null || true; fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        userdel snell-auto >/dev/null 2>&1 || true
        printf '\n安装未完成，已撤回本次创建的 Snell 服务及文件。\n' >&2
    fi
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    exit "$rc"
}
trap cleanup EXIT
trap 'printf "\n命令执行失败（第 %s 行）。\n" "$LINENO" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

# Open with O_EXCL (noclobber), so even a last-moment existing file is preserved.
create_file() {
    local source=$1 destination=$2 mode=$3
    set -C
    if exec 8>"$destination"; then
        set +C
        OWNED_FILES+=("$destination")
        cat "$source" >&8
        exec 8>&-
        chmod "$mode" "$destination"
    else
        set +C
        fail "不能创建文件（可能已存在）：$destination"
    fi
}

existing_install() {
    [[ -e $BIN || -L $BIN || -e $CONF_DIR || -L $CONF_DIR || -e $UNIT || -L $UNIT ]] && return 0
    command -v snell-server >/dev/null 2>&1 && return 0
    [[ $(systemctl show snell.service -p LoadState --value) != not-found ]] && return 0
    systemctl list-unit-files --no-legend --no-pager | grep -qi snell && return 0
    pgrep -x snell-server >/dev/null 2>&1 && return 0
    return 1
}
valid_ipv4() {
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    (( 10#$a > 0 && 10#$a < 224 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 )) || return 1
    # Reject common private / loopback / link-local / CGNAT responses.
    (( 10#$a != 10 && 10#$a != 127 )) || return 1
    [[ $a.$b != 192.168 && $a.$b != 169.254 ]] || return 1
    ! (( 10#$a == 172 && 10#$b >= 16 && 10#$b <= 31 || 10#$a == 100 && 10#$b >= 64 && 10#$b <= 127 ))
}

main() {
    [[ $(uname -s) == Linux ]] || fail '请在 Linux VPS 上运行，不要在 Mac 上运行。'
    [[ $EUID == 0 ]] || fail '请使用 sudo bash install-snell.sh 运行。'
    [[ -r /etc/os-release ]] || fail '无法识别系统。'
    # shellcheck disable=SC1091
    . /etc/os-release
    case ${ID:-}:${VERSION_ID:-} in
        debian:*) (( ${VERSION_ID%%.*} >= 11 )) || fail '需要 Debian 11 或更新版本。' ;;
        ubuntu:*) (( ${VERSION_ID%%.*} >= 22 )) || fail '需要 Ubuntu 22.04 或更新版本。' ;;
        *) fail '第一版仅支持 Debian 11+ / Ubuntu 22.04+。' ;;
    esac
    [[ -d /run/systemd/system ]] || fail '需要使用 systemd 的 VPS，不支持普通 Docker 容器。'
    command -v flock >/dev/null || fail '缺少 flock（util-linux）。'
    exec 9>/run/lock/snell-auto-install.lock
    flock -n 9 || fail '已有一个安装程序正在运行。'
    existing_install && fail '发现已有 Snell 文件、服务或进程；为避免覆盖，本次不做修改。'

    local arch
    case $(uname -m) in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) fail '第一版支持 x86_64 和 ARM64 VPS。' ;;
    esac
    info "将安装 Snell ${SNELL_VERSION}：自动端口、随机密钥、开机启动。"
    printf '是否继续？[yes/no，默认 no]：'
    local answer
    if ! read -r answer; then fail '没有读到确认。请先保存脚本，再用 bash 运行。'; fi
    case $answer in
        yes|YES|Yes|y|Y|on|ON) ;;
        *) info '已取消，没有安装。'; return ;;
    esac

    info '1/5 安装必要工具……'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl unzip openssl iproute2 procps

    local public_ip='' endpoint candidate
    for endpoint in https://api.ipify.org https://ipv4.icanhazip.com; do
        candidate=$(curl -4 -fsS --connect-timeout 5 --max-time 12 "$endpoint" 2>/dev/null) || continue
        if valid_ipv4 "$candidate"; then public_ip=$candidate; break; fi
    done
    [[ -n $public_ip ]] || fail '未能检测公网 IPv4；本版暂不支持纯 IPv6 VPS。'
    # Recheck after package installation, which can take several minutes.
    existing_install && fail '发现 Snell 已被其他程序安装；停止以避免覆盖。'

    local port='' n used
    used=$(ss -H -lntu)
    for ((n=0; n<100; n++)); do
        candidate=$((20000 + $(openssl rand -hex 2 | awk '{print "0x" $0}') % 30000))
        if ! awk -v p="$candidate" '$5 ~ (":" p "$") {found=1} END {exit !found}' <<< "$used"; then
            port=$candidate
            break
        fi
    done
    [[ -n $port ]] || fail '未能找到空闲端口。'
    local psk
    psk=$(openssl rand -hex 16)

    info '2/5 从 Surge 官方下载 Snell 5.0.1……'
    WORK=$(mktemp -d)
    curl --proto '=https' --tlsv1.2 -fSL --retry 2 --connect-timeout 10 --max-time 180 \
        "https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${arch}.zip" -o "$WORK/snell.zip"
    unzip -p "$WORK/snell.zip" snell-server > "$WORK/snell-server"
    [[ -s $WORK/snell-server ]] || fail '下载的安装包中没有有效的 snell-server。'
    chmod 755 "$WORK/snell-server"

    info '3/5 创建配置与后台服务……'
    existing_install && fail '下载期间发现其他 Snell 安装；停止以避免覆盖。'
    # Refuse to reuse an existing service identity with unknown permissions.
    if getent passwd snell-auto >/dev/null || getent group snell-auto >/dev/null; then
        fail 'snell-auto 用户或组已存在，请检查后再安装。'
    fi
    useradd --system --user-group --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin snell-auto
    # Only this newly created identity is eligible for rollback.
    CREATED=1
    create_file "$WORK/snell-server" "$BIN" 755
    mkdir -m 750 -- "$CONF_DIR"
    CONF_CREATED=1
    chown root:snell-auto "$CONF_DIR"
    printf '[snell-server]\nlisten = 0.0.0.0:%s\npsk = %s\n' "$port" "$psk" > "$WORK/snell-server.conf"
    create_file "$WORK/snell-server.conf" "$CONF_DIR/snell-server.conf" 640
    chown root:snell-auto "$CONF_DIR/snell-server.conf"
    cat > "$WORK/snell.service" <<'SERVICE'
[Unit]
Description=Snell 5.0.1 Proxy Server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=snell-auto
Group=snell-auto
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=on-failure
RestartSec=3
LimitNOFILE=32768
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
UMask=0077

[Install]
WantedBy=multi-user.target
SERVICE
    create_file "$WORK/snell.service" "$UNIT" 644
    systemctl daemon-reload
    systemctl enable --now snell.service

    local ready=0
    for ((n=0; n<15; n++)); do
        if systemctl is-active --quiet snell.service && \
            ss -H -ltnp "sport = :$port" | grep -q snell-server; then
            ready=1
            break
        fi
        sleep 1
    done
    if [[ $ready != 1 ]]; then
        journalctl -u snell.service -n 25 --no-pager >&2 || true
        fail '服务未能正常监听；请查看上面的错误信息。'
    fi
    printf '我的VPS = snell, %s, %s, psk=%s, version=5\n' "$public_ip" "$port" "$psk" > "$WORK/surge-proxy.txt"
    create_file "$WORK/surge-proxy.txt" "$CONF_DIR/surge-proxy.txt" 600
    # Service is now valid. Firewall failures must not destroy a working installation.
    DONE=1

    info '4/5 处理防火墙……'
    local firewall_found=0
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
        firewall_found=1
        if ! ufw allow "$port/tcp" || ! ufw allow "$port/udp"; then
            info "警告：UFW 放行未全部成功，请手动放行 ${port}/TCP 和 UDP。"
        fi
    fi
    if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        firewall_found=1
        # Apply to every active zone, or the default zone when none is active.
        local zones zone
        if ! zones=$(firewall-cmd --get-active-zones | awk '/^[^[:space:]]/ {print $1}'); then
            zones=''
            info '警告：无法查询 firewalld 活动区域，将尝试默认区域。'
        fi
        if [[ -z $zones ]]; then
            if ! zones=$(firewall-cmd --get-default-zone); then
                zones=''
                info "警告：无法查询 firewalld 默认区域，请手动放行 ${port}/TCP 和 UDP。"
            fi
        fi
        for zone in $zones; do
            if ! firewall-cmd --zone="$zone" --add-port="$port/tcp" --add-port="$port/udp" || \
                ! firewall-cmd --permanent --zone="$zone" --add-port="$port/tcp" --add-port="$port/udp"; then
                info "警告：firewalld 区域 ${zone} 放行未全部成功，请手动检查。"
            fi
        done
    fi
    if [[ $firewall_found == 0 ]]; then
        info '没有检测到启用的 UFW/firewalld；不改动自定义 nftables/iptables 规则。'
    fi

    info '5/5 本机服务已启动，开机启动已设置。'
    printf '\n将下面一行加入 Surge 配置的 [Proxy] 段：\n\n'
    printf '我的VPS = snell, %s, %s, psk=%s, version=5\n' "$public_ip" "$port" "$psk"
    printf '\n配置已保存：%s/surge-proxy.txt（含密钥，请勿公开）\n' "$CONF_DIR"
    printf '\n还需确认云厂商安全组允许入站 %s/TCP 和 %s/UDP。\n' "$port" "$port"
    info '本机启动检查不等于公网可连接；请在 Surge 中测试节点。NAT VPS 还需要端口映射。'
}

main "$@"
