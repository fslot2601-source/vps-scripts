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
USER_CREATED=0
CONF_CREATED=0
OWNED_FILES=()
OWNED_IDS=()
ENABLE_CHANGED=0
BOOT_STATUS='已设置开机启动'
DONE=0
REINSTALL=0
BACKUP=''
OLD_ACTIVE=0
OLD_ENABLED='disabled'
REUSE_CONFIG=0
REUSE_UNIT=0
OLD_PORT=''
OLD_PSK=''
NODE_EXTRA=''

info() { printf '\n%s\n' "$*"; }
fail() { printf '\n错误：%s\n' "$*" >&2; exit 1; }
cleanup() {
    local rc=$?
    trap - EXIT ERR
    set +e
    if [[ $CREATED == 1 && $DONE == 0 ]]; then
        local file i restore_failed=0
        systemctl stop snell.service >/dev/null 2>&1
        if (( ${#OWNED_FILES[@]} > 0 )); then
            for ((i=0; i<${#OWNED_FILES[@]}; i++)); do
                file=${OWNED_FILES[$i]}
                if [[ -e $file || -L $file ]]; then
                    if [[ -L $file || $(file_identity "$file") != "${OWNED_IDS[$i]}" ]]; then
                        printf '警告：文件被其他程序替换，未删除：%s\n' "$file" >&2
                        restore_failed=1
                        continue
                    fi
                    rm -f -- "$file" || restore_failed=1
                fi
                if [[ -n $BACKUP && -f $BACKUP/${file##*/} ]]; then
                    cp -a -- "$BACKUP/${file##*/}" "$file" || restore_failed=1
                fi
            done
        fi
        if [[ $CONF_CREATED == 1 ]]; then rmdir -- "$CONF_DIR" 2>/dev/null; fi
        systemctl daemon-reload >/dev/null 2>&1 || restore_failed=1
        # Reused units keep their exact enable/runtime/link state throughout.
        if [[ $ENABLE_CHANGED == 1 ]]; then
            systemctl disable snell.service >/dev/null 2>&1
        fi
        if [[ $OLD_ACTIVE == 1 ]]; then
            systemctl start snell.service >/dev/null 2>&1 || restore_failed=1
            systemctl is-active --quiet snell.service || restore_failed=1
        fi
        if [[ $USER_CREATED == 1 ]]; then userdel snell-auto >/dev/null 2>&1; fi
        if [[ $restore_failed == 0 ]]; then
            printf '\n安装未完成，已撤回本次改动；原来运行中的服务已尝试恢复。\n' >&2
        else
            printf '\n警告：自动恢复未全部成功，请检查 snell 服务；备份：%s\n' "$BACKUP" >&2
        fi
    fi
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    exit "$rc"
}
trap cleanup EXIT
trap 'printf "\n命令执行失败（第 %s 行）。\n" "$LINENO" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

file_identity() { stat -c '%d:%i' -- "$1"; }

# Open with O_EXCL and track file identity for conflict-safe rollback.
create_file() {
    local source=$1 destination=$2 mode=$3 slot=-1
    if [[ -e $destination || -L $destination ]]; then
        [[ $REINSTALL == 1 && -n $BACKUP && -f $BACKUP/${destination##*/} && ! -L $destination ]] || \
            fail "文件未备份，拒绝覆盖：$destination"
        cmp -s -- "$BACKUP/${destination##*/}" "$destination" || fail "备份后文件被其他程序修改：$destination"
        slot=${#OWNED_FILES[@]}
        OWNED_FILES+=("$destination")
        OWNED_IDS+=('missing')
        rm -- "$destination"
    fi
    set -C
    if exec 8>"$destination"; then
        set +C
        if (( slot < 0 )); then
            slot=${#OWNED_FILES[@]}
            OWNED_FILES+=("$destination")
            OWNED_IDS+=('missing')
        fi
        OWNED_IDS[$slot]=$(file_identity "$destination")
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

config_value() {
    awk -v key="$1" '
        { sub(/\r$/, "") }
        /^[[:space:]]*\[/ { section = ($0 ~ /^[[:space:]]*\[snell-server\][[:space:]]*$/); next }
        section && /^[[:space:]]*[^#;][^=]*=/ {
            name=$0; sub(/=.*/, "", name); gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            if (name == key) { value=$0; sub(/^[^=]*=/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit }
        }' "$CONF_DIR/snell-server.conf"
}

prepare_reinstall() {
    local file listen obfs exec_start
    REUSE_CONFIG=0
    REUSE_UNIT=0
    OLD_PORT=''
    OLD_PSK=''
    NODE_EXTRA=''
    [[ ! -L $CONF_DIR ]] || fail '配置目录是符号链接；请先确认实际安装路径。'
    [[ ! -e $CONF_DIR || -d $CONF_DIR ]] || fail '配置目录位置被普通文件占用。'
    for file in "$BIN" "$UNIT" "$CONF_DIR/snell-server.conf" "$CONF_DIR/surge-proxy.txt"; do
        [[ ! -L $file && ( ! -e $file || -f $file ) ]] || fail "不能自动覆盖符号链接或特殊文件：$file"
    done
    if [[ -f $CONF_DIR/snell-server.conf ]]; then
        listen=$(config_value listen)
        OLD_PSK=$(config_value psk)
        [[ $listen =~ ^(0\.0\.0\.0|\[::\]):([0-9]{1,5})$ ]] || \
            fail '原配置不是单端口公网监听格式；未修改，请先检查 listen。'
        OLD_PORT=$((10#${BASH_REMATCH[2]}))
        (( OLD_PORT >= 1 && OLD_PORT <= 65535 )) || fail '原配置端口无效。'
        [[ -n $OLD_PSK && ! $OLD_PSK =~ [[:space:],\;\#] ]] || fail '原密钥格式无法直接输出到 Surge；未修改。'
        obfs=$(config_value obfs)
        case $obfs in
            ''|off|false) ;;
            http) NODE_EXTRA=', obfs=http' ;;
            *) fail "原配置的混淆方式不适用于 Snell v5：$obfs" ;;
        esac
        REUSE_CONFIG=1
        info "将保留原端口 ${OLD_PORT}、密钥及服务端配置。"
    fi
    if [[ $(systemctl show snell.service -p LoadState --value) != not-found ]]; then
        exec_start=$(systemctl show snell.service -p ExecStart --value)
        [[ $exec_start == *"path=$BIN ;"* && $exec_start == *" -c $CONF_DIR/snell-server.conf "* && $REUSE_CONFIG == 1 ]] || \
            fail '已有服务不使用标准程序/配置路径，不能直接覆盖；未修改原服务。'
        REUSE_UNIT=1
    fi
    [[ $REUSE_CONFIG == 0 || $REUSE_UNIT == 1 ]] || fail '原配置存在但原服务缺失，请先恢复服务文件后重装。'
}

backup_install() {
    local file
    install -d -m 700 /var/backups/snell
    BACKUP=$(mktemp -d /var/backups/snell/backup-XXXXXXXX)
    for file in "$BIN" "$UNIT" "$CONF_DIR/snell-server.conf" "$CONF_DIR/surge-proxy.txt"; do
        if [[ -f $file ]]; then cp -a -- "$file" "$BACKUP/${file##*/}"; fi
    done
    if systemctl is-active --quiet snell.service; then OLD_ACTIVE=1; fi
    OLD_ENABLED=$(systemctl is-enabled snell.service 2>/dev/null) || true
    if [[ $REUSE_UNIT == 1 ]]; then
        case $OLD_ENABLED in
            enabled) BOOT_STATUS='已开启开机启动' ;;
            enabled-runtime) BOOT_STATUS='仅运行时启用（沿用原设置）' ;;
            *) BOOT_STATUS="开机策略沿用原设置（${OLD_ENABLED:-未知}）" ;;
        esac
    fi
    systemctl cat snell.service > "$BACKUP/effective-service.txt" 2>/dev/null || true
    printf 'active=%s\nenabled=%s\n' "$OLD_ACTIVE" "$OLD_ENABLED" > "$BACKUP/service-state.txt"
    info "原安装已备份：$BACKUP（含密钥，仅 root 可访问）"
}

show_result() {
    local public_ip=$1 port=$2 psk=$3
    local green='' cyan='' yellow='' bold='' reset=''
    # Keep redirected output clean; respect terminals that disable color.
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
        green=$'\033[1;32m'
        cyan=$'\033[1;36m'
        yellow=$'\033[1;33m'
        bold=$'\033[1m'
        reset=$'\033[0m'
    fi
    printf '\n%s╔══════════════════════════════════════════════╗\n' "$green"
    printf '║              Snell 安装完成                  ║\n'
    printf '╚══════════════════════════════════════════════╝%s\n\n' "$reset"
    printf '  服务器 IP   %s%s%s\n' "$cyan" "$public_ip" "$reset"
    printf '  连接端口    %s%s%s\n' "$cyan" "$port" "$reset"
    printf '  连接密钥    %s%s%s\n' "$bold" "$psk" "$reset"
    printf '  协议版本    Snell v5（服务端 %s）\n' "$SNELL_VERSION"
    printf '  服务状态    %s● 本机已启动 · %s%s\n' "$green" "$BOOT_STATUS" "$reset"
    printf '\n%s━━━━━━━━━━ 复制下面这行到 Surge ━━━━━━━━━━%s\n\n' "$cyan" "$reset"
    # A single, undecorated node line: safe to select and paste into [Proxy].
    printf '%s我的VPS = snell, %s, %s, psk=%s, version=5%s%s\n' "$bold" "$public_ip" "$port" "$psk" "$NODE_EXTRA" "$reset"
    printf '\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n' "$cyan" "$reset"
    printf '  添加位置：Surge 配置 → [Proxy]\n'
    printf '  %s安全组需放行：%s / TCP + UDP%s\n' "$yellow" "$port" "$reset"
    printf '  配置已保存：%s/surge-proxy.txt\n' "$CONF_DIR"
    if [[ -n $BACKUP ]]; then printf '  原安装备份：%s\n' "$BACKUP"; fi
    printf '  %s节点含密钥，请勿公开分享或截图。%s\n' "$yellow" "$reset"
    printf '\n  本机启动不代表公网可连接，请在 Surge 中测试节点。\n'
    printf '  NAT VPS 还需配置端口映射。\n\n'
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
    if existing_install; then REINSTALL=1; fi

    local arch
    case $(uname -m) in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) fail '第一版支持 x86_64 和 ARM64 VPS。' ;;
    esac
    if [[ $REINSTALL == 1 ]]; then
        info "发现已有 Snell，将备份后覆盖重装为 ${SNELL_VERSION}。"
        info '标准安装会保留端口、密钥及配置；重装时连接会短暂中断。'
    else
        info "将安装 Snell ${SNELL_VERSION}：自动端口、随机密钥、开机启动。"
    fi
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
    if [[ $REINSTALL == 1 ]]; then
        prepare_reinstall
    elif existing_install; then
        fail '确认后有其他程序安装了 Snell，请重新运行以确认覆盖。'
    fi

    local port=$OLD_PORT n used
    used=$(ss -H -lntu)
    for ((n=0; n<100 && ${#port}==0; n++)); do
        candidate=$((20000 + $(openssl rand -hex 2 | awk '{print "0x" $0}') % 30000))
        if ! awk -v p="$candidate" '$5 ~ (":" p "$") {found=1} END {exit !found}' <<< "$used"; then
            port=$candidate
            break
        fi
    done
    [[ -n $port ]] || fail '未能找到空闲端口。'
    local psk=$OLD_PSK
    if [[ -z $psk ]]; then psk=$(openssl rand -hex 16); fi

    info '2/5 从 Surge 官方下载 Snell 5.0.1……'
    WORK=$(mktemp -d)
    curl --proto '=https' --tlsv1.2 -fSL --retry 2 --connect-timeout 10 --max-time 180 \
        "https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${arch}.zip" -o "$WORK/snell.zip"
    unzip -p "$WORK/snell.zip" snell-server > "$WORK/snell-server"
    [[ -s $WORK/snell-server ]] || fail '下载的安装包中没有有效的 snell-server。'
    chmod 755 "$WORK/snell-server"

    info '3/5 创建配置与后台服务……'
    if [[ $REINSTALL == 1 ]]; then
        # Revalidate and snapshot only after download, before stopping the old service.
        prepare_reinstall
        [[ $port == "$OLD_PORT" && $psk == "$OLD_PSK" || $REUSE_CONFIG == 0 ]] || fail '下载期间原配置发生变化，请重新运行。'
        backup_install
    elif existing_install; then
        fail '下载期间发现其他 Snell 安装，请重新运行以确认覆盖。'
    fi
    if [[ $REUSE_UNIT == 0 ]]; then
        if getent passwd snell-auto >/dev/null || getent group snell-auto >/dev/null; then
            fail 'snell-auto 账户已存在但没有可复用的标准服务，请先检查账户用途。'
        fi
    fi
    CREATED=1
    if [[ $REINSTALL == 1 ]]; then
        if [[ $REUSE_UNIT == 1 ]]; then systemctl stop snell.service; fi
        if pgrep -x snell-server >/dev/null; then fail '仍有其他 Snell 实例运行，未强制结束；请先检查。'; fi
    fi
    if [[ $REUSE_UNIT == 0 ]]; then
        useradd --system --user-group --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin snell-auto
        USER_CREATED=1
    fi
    create_file "$WORK/snell-server" "$BIN" 755
    if [[ $REUSE_CONFIG == 0 ]]; then
        if [[ ! -d $CONF_DIR ]]; then
            mkdir -m 750 -- "$CONF_DIR"
            CONF_CREATED=1
            chown root:snell-auto "$CONF_DIR"
        fi
        printf '[snell-server]\nlisten = 0.0.0.0:%s\npsk = %s\n' "$port" "$psk" > "$WORK/snell-server.conf"
        create_file "$WORK/snell-server.conf" "$CONF_DIR/snell-server.conf" 640
        chown root:snell-auto "$CONF_DIR/snell-server.conf"
    fi
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
    if [[ $REUSE_UNIT == 0 ]]; then create_file "$WORK/snell.service" "$UNIT" 644; fi
    systemctl daemon-reload
    systemctl start snell.service

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
    printf '我的VPS = snell, %s, %s, psk=%s, version=5%s\n' "$public_ip" "$port" "$psk" "$NODE_EXTRA" > "$WORK/surge-proxy.txt"
    create_file "$WORK/surge-proxy.txt" "$CONF_DIR/surge-proxy.txt" 600
    if [[ $REUSE_UNIT == 0 ]]; then
        ENABLE_CHANGED=1
        systemctl enable snell.service
    fi
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

    info '5/5 安装流程完成。'
    show_result "$public_ip" "$port" "$psk"
}

main "$@"
