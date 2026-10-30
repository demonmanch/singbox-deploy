#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# 彩色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"

# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        err "请切换到 root 用户(sudo -i)后再运行: curl -fsSL <脚本地址> -o /tmp/install-singbox.sh && bash /tmp/install-singbox.sh"
        exit 1
    fi
}

check_root

# -----------------------
# 一键恢复(新机器/重装后): bash install-singbox-yyds.sh restore [备份文件]
# 用脚本里的线路机脚本模板执行恢复：缺 sing-box/服务就安装，恢复配置、校验、启动，最后装好 sb 面板并显示链接
if [ "${1:-}" = "restore" ]; then
    shift
    R_SRC="$0"; R_DL=""; R_TMP=$(mktemp /tmp/sb-restore-tpl.XXXXXX); R_RC=0
    if ! { [ -f "$R_SRC" ] && grep -q '^RELAY_EOF$' "$R_SRC" 2>/dev/null; }; then
        R_DL=$(mktemp /tmp/sb-restore-main.XXXXXX)
        curl -fsSL "https://raw.githubusercontent.com/demonmanch/singbox-deploy/main/install-singbox-yyds.sh" -o "$R_DL" || { err "下载一键脚本失败"; rm -f "$R_DL" "$R_TMP"; exit 1; }
        R_SRC="$R_DL"
    fi
    awk '/<<.RELAY_EOF.$/{f=1;next} /^RELAY_EOF$/{f=0} f' "$R_SRC" > "$R_TMP"
    if grep -q 'sb_restore()' "$R_TMP" && bash -n "$R_TMP"; then
        SB_INSTALLER_SRC="$R_SRC" bash "$R_TMP" restore "$@" || R_RC=$?
    else
        err "一键脚本里没有找到恢复功能"; R_RC=1
    fi
    rm -f "$R_TMP" ${R_DL:+"$R_DL"}
    exit "$R_RC"
fi

# -----------------------
# 检测虚拟化类型和内核版本
# 新版 sing-box 由 Go 1.24+ 编译，而 Go 1.24 起要求 Linux 内核 >= 3.2（见 Go 1.24 发行说明）
detect_virt() {
    VIRT="unknown"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT=$(systemd-detect-virt 2>/dev/null || true)
        [ -z "$VIRT" ] && VIRT="none"
    fi
    if [ "$VIRT" = "unknown" ] || [ "$VIRT" = "none" ]; then
        if [ -f /proc/user_beancounters ] || [ -d /proc/vz ] && [ ! -d /proc/bc ]; then
            VIRT="openvz"
        elif grep -qa 'container=lxc' /proc/1/environ 2>/dev/null || grep -qE '/lxc/|lxc\.payload' /proc/1/cgroup 2>/dev/null; then
            VIRT="lxc"
        elif [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
            VIRT="docker"
        fi
    fi
    case "$VIRT" in
        openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn|container-other|wsl) IS_CONTAINER=true ;;
        *) IS_CONTAINER=false ;;
    esac
}

check_kernel() {
    local kver major minor
    kver=$(uname -r 2>/dev/null || echo "0.0")
    major=$(printf '%s' "$kver" | cut -d. -f1 | tr -cd '0-9')
    minor=$(printf '%s' "$kver" | cut -d. -f2 | tr -cd '0-9')
    major=${major:-0}; minor=${minor:-0}
    info "虚拟化类型: ${VIRT}，内核版本: ${kver}"
    if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 2 ]; }; then
        err "内核版本 ${kver} 太旧（低于 3.2），新版 sing-box（Go 1.24+ 编译）无法在此内核上运行。"
        err "这通常是老旧的 OpenVZ 6 小鸡（内核 2.6.x）。请更换为 KVM 或新版 LXC/OpenVZ 7 机器，或联系商家升级内核。"
        exit 1
    fi
    if [ "$IS_CONTAINER" = "true" ]; then
        info "检测到容器环境(${VIRT})：容器内无法修改内核参数(如 BBR/sysctl/TUN)，本脚本不会改动这些，可正常安装。"
    fi
}

detect_virt
check_kernel

# -----------------------
# 低内存检测：读取 cgroup 内存上限(容器/小鸡)和 /proc/meminfo，取较小值(MiB)
detect_mem() {
    local mem_kb lim lim_mib=""
    mem_kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || true)
    [ -n "$mem_kb" ] && lim_mib=$((mem_kb / 1024))
    for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        lim=$(cat "$f" 2>/dev/null || true)
        if [[ "$lim" =~ ^[0-9]+$ ]] && [ "$lim" -gt 0 ] && [ "$lim" -lt 1099511627776 ]; then
            lim=$((lim / 1024 / 1024))
            if [ -z "$lim_mib" ] || [ "$lim" -lt "$lim_mib" ]; then lim_mib="$lim"; fi
        fi
    done
    MEM_MIB="${lim_mib:-0}"
    LOW_MEM=false
    GO_MEMLIMIT=""
    if [ "$MEM_MIB" -gt 0 ] && [ "$MEM_MIB" -le 256 ]; then
        LOW_MEM=true
        # 本机还有线路机节点(sing-box-relay)时两个 sing-box 进程各用约 45%，否则 75%
        local pct=75
        [ -f /etc/sing-box-relay/relay.env ] && pct=45
        GO_MEMLIMIT="$((MEM_MIB * pct / 100))MiB"
        warn "检测到本机可用内存只有约 ${MEM_MIB} MiB（≤256 MiB），已启用低内存模式："
        warn "   sing-box 服务将设置 GOMEMLIMIT=${GO_MEMLIMIT} GOGC=70，减少被系统 OOM 杀掉的概率"
        warn "   建议下面只选 1~2 个协议（例如只选 VLESS Reality，或 Reality + SS）"
    elif [ "$MEM_MIB" -gt 0 ]; then
        info "内存: 约 ${MEM_MIB} MiB"
    fi
}

detect_mem

# ===== 磁盘 / 安装缓存 =====
check_disk() {
    local avail
    avail=$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}' || true)
    [[ "$avail" =~ ^[0-9]+$ ]] || return 0
    avail=$((avail / 1024))
    if [ "$avail" -lt 150 ]; then
        warn "磁盘剩余空间只有约 ${avail} MB（低于 150MB）：安装 sing-box 需要约 50~80MB，空间不足可能失败。"
        warn "   可先清理: rm -rf /var/cache/apk/* ; apt-get clean ; 删除不用的日志/文件"
    else
        info "磁盘剩余空间: 约 ${avail} MB"
    fi
}
clean_pkg_cache() {
    if command -v apk >/dev/null 2>&1; then
        rm -rf /var/cache/apk/* 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get clean >/dev/null 2>&1 || true
    fi
}

check_disk

# -----------------------
# 安装依赖（只装缺少的；openssl 等到选了需要它的协议再装）
# 必需: curl(下载) ca-certificates(HTTPS) jq(sb 面板读配置) bash；Alpine 另需 openrc(服务)
missing_pkgs() {
    local m=""
    command -v curl >/dev/null 2>&1 || m="$m curl"
    command -v jq >/dev/null 2>&1 || m="$m jq"
    command -v bash >/dev/null 2>&1 || m="$m bash"
    [ -s /etc/ssl/certs/ca-certificates.crt ] || [ -s /etc/pki/tls/certs/ca-bundle.crt ] || m="$m ca-certificates"
    if [ "$OS" = "alpine" ]; then command -v rc-service >/dev/null 2>&1 || m="$m openrc"; fi
    printf '%s' "${m# }"
}

install_deps() {
    local pk
    pk=$(missing_pkgs)
    if [ -z "$pk" ]; then
        info "系统依赖已齐全(curl jq bash ca-certificates)，跳过安装"
        return 0
    fi
    info "安装系统依赖: $pk"
    
    case "$OS" in
        alpine)
            # shellcheck disable=SC2086
            apk add --no-cache $pk || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            # shellcheck disable=SC2086
            apt-get install -y --no-install-recommends $pk || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            # shellcheck disable=SC2086
            yum install -y $pk || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        *)
            warn "未识别的系统类型,尝试继续..."
            ;;
    esac
    
    info "依赖安装完成"
}

install_deps

# -----------------------
# 旧版线路机（线路机节点放在 /etc/sing-box，和落地机共用 sing-box 服务）：
# 先把线路机节点迁移到独立目录 /etc/sing-box-relay + 独立服务 sing-box-relay（端口/UUID/密钥/链接不变），
# 再安装落地机节点，二者互不覆盖。迁移失败则中止安装，绝不覆盖线路机节点。
MAIN_URL="https://raw.githubusercontent.com/demonmanch/singbox-deploy/main/install-singbox-yyds.sh"
migrate_old_relay_if_needed() {
    [ -f /etc/sing-box/relay.env ] && [ ! -f /etc/sing-box-relay/relay.env ] || return 0
    warn "检测到本机是旧版线路机（线路机节点在 /etc/sing-box），安装落地机节点前先把它迁移到独立服务 sing-box-relay"
    local src="" tmp rc=0
    tmp=$(mktemp /tmp/relay-install.XXXXXX)
    if [ -f "$0" ] && grep -q '^RELAY_EOF$' "$0" 2>/dev/null; then
        src="$0"
    elif curl -fsSL "$MAIN_URL" -o "${tmp}.main"; then
        src="${tmp}.main"
    fi
    if [ -n "$src" ]; then
        awk '/<<.RELAY_EOF.$/{f=1;next} /^RELAY_EOF$/{f=0} f' "$src" > "$tmp"
    fi
    if [ -s "$tmp" ] && grep -q 'SVC_NAME="sing-box-relay"' "$tmp" && bash -n "$tmp"; then
        bash "$tmp" upgrade < /dev/null || rc=$?
    else
        err "无法获取新版线路机脚本（下载失败: $MAIN_URL）"
        rc=1
    fi
    rm -f "$tmp" "${tmp}.main"
    if [ "$rc" -ne 0 ] || [ ! -f /etc/sing-box-relay/relay.env ]; then
        if [ ! -f /etc/sing-box/relay.env ]; then
            return 0   # 只是过期的线路机记录，已挪到备份目录
        fi
        err "线路机节点迁移失败，为避免覆盖线路机节点，已中止安装（本机没有任何改动）"
        exit 1
    fi
    info "✅ 线路机节点已迁移到 sing-box-relay，继续安装落地机节点"
}
migrate_old_relay_if_needed

# -----------------------
# ---- 公网 IP / NAT / WARP 检测（安装脚本与 sb 面板共用同一套逻辑）----
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "$1" =~ ^[0-9A-Fa-f:.]+$ ]] && [[ "$1" == *:*:* ]]; }

# 内网/运营商级 NAT 地址: 10/8 172.16/12 192.168/16 100.64/10
is_private_ipv4() {
    local a b
    is_ipv4 "$1" || return 1
    a=$(printf '%s' "$1" | cut -d. -f1); b=$(printf '%s' "$1" | cut -d. -f2)
    [ "$a" -eq 10 ] && return 0
    [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
    [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
    [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0
    return 1
}

# 查询公网出口 IP：$1=4 或 6；依次尝试多个接口（每个 5 秒超时），只接受合法 IP
fetch_public_ip() {
    local fam="$1" url ip urls
    if [ "$fam" = "6" ]; then
        urls="https://api64.ipify.org https://ipv6.icanhazip.com https://ifconfig.co/ip"
    else
        urls="https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://ipinfo.io/ip"
    fi
    for url in $urls; do
        ip=$(curl -"$fam" -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ "$fam" = "6" ]; then is_ipv6 "$ip" && { printf '%s' "$ip"; return 0; }
        else is_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }; fi
    done
    return 1
}

# 默认路由网卡上的本机 IPv4 地址（ip route show default → ip addr；失败再用 ip route get）
local_route_ip4() {
    local dev addr=""
    command -v ip >/dev/null 2>&1 || return 0
    dev=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
    if [ -n "$dev" ]; then
        addr=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}' || true)
    fi
    if [ -z "$addr" ]; then
        addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
    fi
    printf '%s' "$addr"
}

# 检测连接 IP。结果:
#   DETECTED_IP / DETECTED_FAMILY(4|6) / DETECTED_ORG(运营商/ASN，可能为空)
#   NAT_REASON：非空表示看起来是 NAT 或 WARP，检测到的 IP 不能直接用作节点连接地址
detect_public_ip() {
    DETECTED_IP=""; DETECTED_FAMILY=""; DETECTED_ORG=""; NAT_REASON=""
    local ip4="" ip6="" trace local4
    ip4=$(fetch_public_ip 4 || true)
    if [ -n "$ip4" ]; then
        DETECTED_IP="$ip4"; DETECTED_FAMILY=4
    else
        ip6=$(fetch_public_ip 6 || true)
        [ -n "$ip6" ] || return 1
        DETECTED_IP="$ip6"; DETECTED_FAMILY=6
    fi
    trace=$(curl -"$DETECTED_FAMILY" -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    DETECTED_ORG=$(curl -s --max-time 5 "https://ipinfo.io/${DETECTED_IP}/org" 2>/dev/null | head -n1 | tr -d '\r' || true)
    case "$DETECTED_ORG" in *"{"*|*"<"*) DETECTED_ORG="" ;; esac
    if printf '%s\n' "$trace" | grep -qE '^warp=(on|plus)$'; then
        NAT_REASON="出口走的是 Cloudflare WARP（cdn-cgi/trace 显示 $(printf '%s\n' "$trace" | grep -E '^warp=' | head -n1)），检测到的 ${DETECTED_IP} 是 Cloudflare 的 IP，客户端连不上"
    elif printf '%s' "$DETECTED_ORG" | grep -qiE 'cloudflare|AS13335'; then
        NAT_REASON="检测到的出口 IP ${DETECTED_IP} 属于 Cloudflare（${DETECTED_ORG}），通常是开了 WARP，客户端连不上"
    elif [ "$DETECTED_FAMILY" = "4" ]; then
        local4=$(local_route_ip4)
        if [ -n "$local4" ] && is_private_ipv4 "$local4" && [ "$local4" != "$ip4" ]; then
            NAT_REASON="本机网卡地址是内网 IP（${local4}），和检测到的公网出口 IP（${ip4}）不一样，说明本机在 NAT 后面（NAT 小鸡/转发机，或云厂商的 1:1 NAT）"
        fi
    fi
    return 0
}

# 打印 NAT/WARP 说明
explain_nat() {
    warn "=================== ⚠️ 注意：不能自动使用检测到的 IP ==================="
    warn "$NAT_REASON"
    echo "   节点链接里必须填【入口地址】：也就是你平时 SSH 登录这台机器用的 IP，"
    echo "   或商家面板里给的 NAT 入口 IP / 域名（例如 'nat.xxx.com' 或 '45.x.x.x'）。"
    echo "   如果你确认 ${DETECTED_IP:-检测到的IP} 就是 SSH 登录用的 IP（例如 Oracle/AWS/GCP 这类云厂商，网卡是内网 IP 属正常），"
    echo "   直接把它输入进去即可。"
    warn "========================================================================"
}

# 生成链接用的主机：去掉空白/方括号，IPv6 加方括号
uri_host() {
    local h
    h=$(printf '%s' "$1" | tr -d '[:space:]')
    h="${h#[}"; h="${h%]}"
    if [[ "$h" == *:* ]]; then printf '[%s]' "$h"; else printf '%s' "$h"; fi
}

# 规范化主机：去空白、去掉 IPv6 方括号
normalize_host() {
    local h
    h=$(printf '%s' "$1" | tr -d '[:space:]')
    h="${h#[}"
    h="${h%]}"
    printf '%s' "$h"
}

# 校验主机：IPv4 / IPv6 / 含字母和点的域名
validate_host() {
    local h="$1" o
    [ -z "$h" ] && return 1
    if [[ "$h" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for o in "${BASH_REMATCH[@]:1}"; do
            [ "$((10#$o))" -le 255 ] || return 1
        done
        return 0
    fi
    is_ipv6 "$h" && return 0
    [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] && [[ "$h" =~ [A-Za-z] ]]
}

# -----------------------
LANDING_CONFIG="/etc/sing-box/config.json"
RELAY_CONFIG_FILE="/etc/sing-box-relay/config.json"
# ===== NAT 模式（LXC/NAT 小鸡：商家只映射少数几个端口，入口IP ≠ 出口IP）=====
# 落地机和线路机共用 /etc/sb-nat.conf：
#   NAT_MODE=1/0  NAT_PORTS=商家映射端口  NAT_UDP_PORTS=其中也映射了 UDP 的端口  NAT_SSH_PORT=SSH 用的映射端口  ENTRY_IP=入口IP
NAT_CONF="/etc/sb-nat.conf"
NAT_MODE=0; NAT_PORTS=""; NAT_UDP_PORTS=""; NAT_SSH_PORT=""; ENTRY_IP=""
NAT_USED=" "
declare -A NAT_LABEL=()

nat_load() {
    NAT_MODE=0; NAT_PORTS=""; NAT_UDP_PORTS=""; NAT_SSH_PORT=""; ENTRY_IP=""
    if [ -f "$NAT_CONF" ]; then
        # shellcheck disable=SC1090
        . "$NAT_CONF" 2>/dev/null || true
    fi
    return 0
}

nat_save() {
    {
        printf '# sb NAT 模式设置（落地机/线路机共用；sb 菜单「NAT 映射端口」「入口/出口 IP」里修改）\n'
        printf 'NAT_MODE=%q\n' "$NAT_MODE"
        printf 'NAT_PORTS=%q\n' "$NAT_PORTS"
        printf 'NAT_UDP_PORTS=%q\n' "$NAT_UDP_PORTS"
        printf 'NAT_SSH_PORT=%q\n' "$NAT_SSH_PORT"
        printf 'ENTRY_IP=%q\n' "$ENTRY_IP"
    } > "$NAT_CONF"
    chmod 600 "$NAT_CONF" 2>/dev/null || true
}

nat_on() { [ "${NAT_MODE:-0}" = "1" ] && [ -n "${NAT_PORTS:-}" ]; }
in_words() { [[ " $2 " == *" $1 "* ]]; }

# 解析端口列表：逗号/空格分隔，支持范围 a-b（最多 256 个端口）；结果放 NAT_PARSED（升序去重）
nat_parse_list() {
    local item lo hi p out=""
    for item in $(printf '%s' "$1" | tr ',，;' '   '); do
        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo=$((10#${BASH_REMATCH[1]})); hi=$((10#${BASH_REMATCH[2]}))
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            lo=$((10#$item)); hi=$lo
        else
            return 1
        fi
        [ "$lo" -ge 1 ] && [ "$hi" -le 65535 ] && [ "$lo" -le "$hi" ] || return 1
        [ $((hi - lo)) -le 256 ] || return 1
        for ((p = lo; p <= hi; p++)); do out="$out $p"; done
    done
    NAT_PARSED=$(printf '%s\n' $out | sort -n -u | tr '\n' ' ' | sed 's/ *$//')
    [ -n "$NAT_PARSED" ] && [ "$(printf '%s\n' $NAT_PARSED | wc -l)" -le 256 ]
}

# 某配置里各入站占用的 端口 网络 名称（SS=TCP+UDP，HY2/TUIC=UDP，其余=TCP）
cfg_port_nets() {
    [ -f "$1" ] && command -v jq >/dev/null 2>&1 || return 0
    jq -r --arg who "$2" '(.inbounds // [])[] | select(.listen_port != null) | .listen_port as $p | (.tag // .type) as $t
        | (if .type == "shadowsocks" then ["tcp","udp"] elif (.type == "hysteria2" or .type == "tuic") then ["udp"] else ["tcp"] end)[]
        | "\($p) \(.) \($who):\($t)"' "$1" 2>/dev/null || true
}

# 收集已占用的 端口/网络：$@ = 配置文件（落地机/线路机）
nat_collect_used() {
    local f p n l who
    NAT_USED=" "
    NAT_LABEL=()
    for f in "$@"; do
        [ -f "$f" ] || continue
        if [ "$f" = "$LANDING_CONFIG" ]; then who="落地机"; else who="线路机"; fi
        while read -r p n l; do
            [ -n "$p" ] || continue
            NAT_USED="$NAT_USED$p/$n "
            if [ "$n" = "udp" ] && [[ "${NAT_LABEL[$p]:-}" == *"$l(TCP)" ]]; then
                NAT_LABEL[$p]="${NAT_LABEL[$p]%(TCP)}(TCP+UDP)"
            else
                NAT_LABEL[$p]="${NAT_LABEL[$p]:+${NAT_LABEL[$p]}, }$l($(printf '%s' "$n" | tr 'a-z' 'A-Z'))"
            fi
        done < <(cfg_port_nets "$f" "$who")
    done
}
nat_mark() { NAT_USED="$NAT_USED$1/$2 "; }
nat_used() { [[ "$NAT_USED" == *" $1/$2 "* ]]; }

# 从映射端口里挑一个：$1 = tcp(VLESS/AnyTLS) | udp(HY2/TUIC，只用映射了 UDP 的端口) | ss(TCP+UDP)
# 优先完全空闲的端口；TCP 协议优先不占用映射了 UDP 的端口（留给 HY2/TUIC）；不用 SSH 端口
nat_pick() {
    local need="$1" p score best="" bs=99
    for p in $NAT_PORTS; do
        [ "$p" = "${NAT_SSH_PORT:-}" ] && continue
        score=0
        case "$need" in
            tcp)
                nat_used "$p" tcp && continue
                nat_used "$p" udp && score=$((score + 2))
                in_words "$p" "$NAT_UDP_PORTS" && score=$((score + 1))
                ;;
            udp)
                in_words "$p" "$NAT_UDP_PORTS" || continue
                nat_used "$p" udp && continue
                nat_used "$p" tcp && score=$((score + 2))
                ;;
            ss)
                nat_used "$p" tcp && continue
                nat_used "$p" udp && continue
                in_words "$p" "$NAT_UDP_PORTS" && score=$((score + 1))
                ;;
        esac
        if [ "$score" -lt "$bs" ]; then bs=$score; best=$p; fi
    done
    [ -n "$best" ] || return 1
    printf '%s' "$best"
}

# 打印 映射端口 → 用途 表
nat_table() {
    local p maps use free=""
    echo "   映射端口   商家映射      用途"
    for p in $NAT_PORTS; do
        maps="TCP"; in_words "$p" "$NAT_UDP_PORTS" && maps="TCP+UDP"
        if [ "$p" = "${NAT_SSH_PORT:-}" ]; then
            use="SSH(不能用)"
        else
            use="${NAT_LABEL[$p]:-}"
            [ -z "$use" ] && { use="空闲"; free="$free $p"; }
        fi
        printf '   %-10s %-12s %s\n' "$p" "$maps" "$use"
    done
    echo "   剩余空闲映射端口:${free:- 无}"
}

# 本机 sshd 端口（检测不到为 22）
detect_sshd_port() {
    local p=""
    p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
    [ -n "$p" ] || p=$(grep -Ei '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2; exit}' || true)
    printf '%s' "${p:-22}"
}

# 交互输入 映射端口列表 / SSH 端口 / UDP 端口；$1=tcponly 时 UDP 回车默认沿用（线路机节点只用 TCP）
# 环境变量: SINGBOX_NAT_PORTS SINGBOX_NAT_SSH_PORT SINGBOX_NAT_UDP(all|none|端口列表)
nat_ask_ports() {
    local in def sshd udp_in
    echo ""
    info "=== NAT 模式：填写商家映射给你的端口 ==="
    echo "   NAT 小鸡只有商家映射的几个端口能从外网连进来（例如 56566,56567,56568 或 56566-56570）。"
    echo "   脚本只会使用这些端口，自动给每个协议分配，不会碰 SSH 端口。"
    def="${NAT_PORTS:-}"
    in="${SINGBOX_NAT_PORTS:-}"
    while true; do
        if [ -z "$in" ]; then
            read -r -p "商家映射端口列表${def:+(回车沿用 $def)}: " in || { err "没有读到输入，退出"; exit 1; }
            in="${in:-$def}"
        fi
        if [ -n "$in" ] && nat_parse_list "$in"; then break; fi
        err "端口列表格式不对: '${in}'（例: 56566,56567,56568 或 56566-56570，最多 256 个）"
        in=""
    done
    NAT_PORTS="$NAT_PARSED"
    sshd=$(detect_sshd_port)
    def="${NAT_SSH_PORT:-}"
    in_words "$def" "$NAT_PORTS" || def=""
    if [ -z "$def" ] && in_words "$sshd" "$NAT_PORTS"; then def="$sshd"; fi
    in="${SINGBOX_NAT_SSH_PORT-__ask__}"
    while true; do
        if [ "$in" = "__ask__" ]; then
            echo "   本机 sshd 监听端口: $sshd。如果列表里有一个端口是商家给 SSH 用的(映射到本机 $sshd)，请填它；没有就输入 0。"
            read -r -p "列表中的 SSH 端口${def:+(回车默认 $def)}: " in || { err "没有读到输入，退出"; exit 1; }
            in="${in:-${def:-0}}"
        fi
        in=$(printf '%s' "$in" | tr -d '[:space:]')
        if [ -z "$in" ] || [ "$in" = "0" ]; then NAT_SSH_PORT=""; break; fi
        if in_words "$in" "$NAT_PORTS"; then NAT_SSH_PORT="$in"; break; fi
        err "SSH 端口 $in 不在映射端口列表里"
        in="__ask__"
    done
    def="${NAT_UDP_PORTS:-}"
    udp_in="${SINGBOX_NAT_UDP:-}"
    while true; do
        if [ -z "$udp_in" ]; then
            echo "   哪些端口商家也映射了 UDP？HY2/TUIC 只会放在映射了 UDP 的端口上（不确定就问商家，或填 none）。"
            if [ -n "$def" ]; then
                read -r -p "UDP 端口: all=全部 / none=没有 / 端口列表 (回车沿用 $def): " udp_in || { err "没有读到输入，退出"; exit 1; }
                udp_in="${udp_in:-$def}"
            else
                read -r -p "UDP 端口: all=全部 / none=没有 / 端口列表 (回车默认 all): " udp_in || { err "没有读到输入，退出"; exit 1; }
                udp_in="${udp_in:-all}"
            fi
        fi
        case "$udp_in" in
            all|ALL|All) NAT_UDP_PORTS="$NAT_PORTS"; break ;;
            none|NONE|None|0) NAT_UDP_PORTS=""; break ;;
        esac
        if nat_parse_list "$udp_in"; then
            local p ok=1 out=""
            for p in $NAT_PARSED; do
                if in_words "$p" "$NAT_PORTS"; then out="$out $p"; else err "UDP 端口 $p 不在映射端口列表里"; ok=0; fi
            done
            if [ "$ok" = 1 ]; then NAT_UDP_PORTS="${out# }"; break; fi
        else
            err "格式不对: '$udp_in'"
        fi
        udp_in=""
    done
    # SSH 端口不算可用的 UDP 端口
    if [ -n "$NAT_SSH_PORT" ]; then
        NAT_UDP_PORTS=$(printf '%s\n' $NAT_UDP_PORTS | grep -vx "$NAT_SSH_PORT" | tr '\n' ' ' | sed 's/ *$//' || true)
    fi
    info "映射端口: $NAT_PORTS | SSH: ${NAT_SSH_PORT:-无} | 映射了 UDP: ${NAT_UDP_PORTS:-无}"
}


# -----------------------
# 工具函数
# 生成随机端口
rand_port() {
    local port
    port=$(shuf -i 10000-60000 -n 1 2>/dev/null) || port=$((RANDOM % 50001 + 10000))
    echo "$port"
}

# 生成随机密码
rand_pass() {
    local pass
    pass=$(openssl rand -base64 16 2>/dev/null | tr -d '\n\r') || pass=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r')
    echo "$pass"
}

# 生成UUID
rand_uuid() {
    local uuid
    if [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        uuid=$(openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
    fi
    echo "$uuid"
}

# -----------------------
# 配置节点名称后缀
echo "请输入节点名称(留空则默认议名):"
read -r user_name
if [[ -n "$user_name" ]]; then
    suffix="-${user_name}"
    echo "$suffix" > /root/node_names.txt
else
    suffix=""
fi

# -----------------------
# 选择要部署的协议
select_protocols() {
    info "=== 选择要部署的协议 ==="
    echo "1) Shadowsocks (SS)"
    echo "2) Hysteria2 (HY2)"
    echo "3) TUIC"
    echo "4) VLESS Reality"
    echo "5) AnyTLS Reality"
    echo ""
    echo "请输入要部署的协议编号(多个用空格分隔,如: 1 2 4):"
    read -r protocol_input
    
    # 使用全局变量
    ENABLE_SS=false
    ENABLE_HY2=false
    ENABLE_TUIC=false
    ENABLE_REALITY=false
    ENABLE_ANYTLS=false
    
    for num in $protocol_input; do
        case "$num" in
            1) ENABLE_SS=true ;;
            2) ENABLE_HY2=true ;;
            3) ENABLE_TUIC=true ;;
            4) ENABLE_REALITY=true ;;
            5) ENABLE_ANYTLS=true ;;
            *) warn "无效选项: $num" ;;
        esac
    done
    
    if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        err "未选择任何协议,退出安装"
        exit 1
    fi
    
    # 保存协议选择到文件（确保持久化）
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/.protocols <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
EOF
    
    info "已选择协议:"
    $ENABLE_SS && echo "  - Shadowsocks"
    $ENABLE_HY2 && echo "  - Hysteria2"
    $ENABLE_TUIC && echo "  - TUIC"
    $ENABLE_REALITY && echo "  - VLESS Reality"
    $ENABLE_ANYTLS && echo "  - AnyTLS Reality"
    
    # 导出为全局变量（确保后续脚本可以访问）
    export ENABLE_SS
    export ENABLE_HY2
    export ENABLE_TUIC
    export ENABLE_REALITY
    export ENABLE_ANYTLS
}

# 创建配置目录
mkdir -p /etc/sing-box
select_protocols

# -----------------------
# 选择SS加密方式（新增）
select_ss_method() {
    if ! $ENABLE_SS; then
        SS_METHOD="2022-blake3-aes-128-gcm"
        return 0
    fi
    
    info "=== 选择 Shadowsocks 加密方式 ==="
    echo "1) 2022-blake3-aes-128-gcm (推荐)"
    echo "2) aes-128-gcm"
    echo ""
    echo "请输入选择(默认为 1):"
    read -r ss_method_choice
    
    case "${ss_method_choice:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="aes-128-gcm" ;;
        *) 
            warn "无效选择，使用默认方式: 2022-blake3-aes-128-gcm"
            SS_METHOD="2022-blake3-aes-128-gcm"
            ;;
    esac
    
    info "已选择加密方式: $SS_METHOD"
    export SS_METHOD
}

select_ss_method

# openssl 只在需要时安装：HY2/TUIC 自签证书、Reality/AnyTLS 目标网站握手检查
ensure_openssl() {
    command -v openssl >/dev/null 2>&1 && return 0
    info "安装 openssl（生成证书/检查 Reality 目标网站需要）..."
    case "$OS" in
        alpine) apk add --no-cache openssl >/dev/null 2>&1 || true ;;
        debian) { DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssl >/dev/null 2>&1 \
                  || { apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssl >/dev/null 2>&1; }; } || true ;;
        redhat) yum install -y openssl >/dev/null 2>&1 || true ;;
    esac
    command -v openssl >/dev/null 2>&1 || warn "openssl 安装失败"
}
if $ENABLE_HY2 || $ENABLE_TUIC || $ENABLE_REALITY || $ENABLE_ANYTLS; then
    ensure_openssl
fi

# -----------------------
# NAT 模式：容器 / 网卡是内网 IP 时建议开启（只用商家映射端口、自动分配、单独记录入口IP）
# 环境变量 SINGBOX_NAT_MODE=1 强制开启，=0 强制关闭（不询问）；普通 VPS 不询问，与以前完全一样
NAT_ON=false
NAT_ASKED=false
nat_decide() {
    nat_load
    local ans="${SINGBOX_NAT_MODE:-}" why="" l4
    if [ -z "$ans" ]; then
        l4=$(local_route_ip4)
        [ "${IS_CONTAINER:-false}" = "true" ] && why="容器环境(${VIRT})"
        if [ -n "$l4" ] && is_private_ipv4 "$l4"; then why="${why:+$why，}网卡是内网IP $l4"; fi
        [ "${NAT_MODE:-0}" = "1" ] && why="${why:+$why，}上次安装开启过 NAT 模式"
        [ -n "$why" ] || return 0
        echo ""
        warn "检测到: ${why}"
        echo "   LXC/NAT 小鸡通常只有商家映射的几个端口(如 56566~56570)能从外网连进来，入口IP(商家面板里的公网IP)也和出口IP不同。"
        echo "   开启 NAT 模式后：只用你填写的映射端口，自动给每个协议分配(HY2/TUIC 只放在映射了 UDP 的端口)，不碰 SSH 端口，"
        echo "   并单独记录入口IP，所有链接都用它。Oracle/AWS 这类所有端口都能用的云服务器(1:1 NAT)选 n。"
        read -r -p "是否开启 NAT 模式?(Y/n): " ans || ans=""
        case "$ans" in [Nn]*) ans=0 ;; *) ans=1 ;; esac
        NAT_ASKED=true
    fi
    if [ "$ans" = "1" ]; then
        NAT_ON=true
        info "已开启 NAT 模式"
    fi
}
nat_decide

# NAT 模式下的入口IP：显示出口IP和运营商，入口IP 必须由用户确认（存到 /etc/sb-nat.conf 和 CUSTOM_IP）
nat_entry_ip() {
    local def in
    def=$(normalize_host "${ENTRY_IP:-$OLD_CUSTOM_IP}")
    info "正在检测出口IP..."
    detect_public_ip || true
    echo ""
    info "=== 入口IP 和 出口IP ==="
    echo "   入口IP: 客户端/线路机连接本机用的地址 = 商家面板里的公网IP/域名（一般就是 SSH 登录用的 IP）"
    echo "   出口IP: ${DETECTED_IP:-检测失败}${DETECTED_ORG:+  (${DETECTED_ORG})}  ← 本机访问外网时显示的 IP"
    echo "   NAT 小鸡上两者不同是正常的：出口可能是商家提供的解锁出口(例如家宽 IP)，或 WARP。节点链接里只用入口IP。"
    in="${SINGBOX_ENTRY_IP:-}"
    while true; do
        if [ -z "$in" ]; then
            read -r -p "请输入入口IP/域名${def:+(回车使用 $def)}: " in || { err "没有读到输入，退出"; exit 1; }
            in="${in:-$def}"
        fi
        in=$(normalize_host "$in")
        if [ -n "$in" ] && validate_host "$in"; then break; fi
        [ -n "$in" ] && err "地址无效: '${in}'（需为 IPv4、IPv6 或域名）"
        [ -z "$in" ] && err "NAT 模式必须填写入口IP（商家面板里的公网IP/域名）"
        in=""
    done
    ENTRY_IP="$in"
    CUSTOM_IP="$in"
    [ -n "$DETECTED_IP" ] && [ "$DETECTED_IP" != "$in" ] && info "入口IP $in ≠ 出口IP $DETECTED_IP（NAT 上正常）"
    return 0
}

# -----------------------
# 在获取公网 IP 之前，询问连接ip和sni配置
# 节点连接地址：留空时自动检测；检测到 NAT/WARP 时不自动填，必须由用户输入入口地址
# 重装时沿用上次保存的 CUSTOM_IP（回车即可）
OLD_CUSTOM_IP=""
if [ -f /etc/sing-box/.config_cache ]; then
    # shellcheck disable=SC1091
    OLD_CUSTOM_IP=$( (. /etc/sing-box/.config_cache >/dev/null 2>&1; printf '%s' "${CUSTOM_IP:-}") || true)
fi
DETECTED_IP=""; DETECTED_FAMILY=""; DETECTED_ORG=""; NAT_REASON=""
if $NAT_ON; then
    nat_entry_ip
else
echo ""
if [ -n "$OLD_CUSTOM_IP" ]; then
    echo "请输入节点连接 IP 或 DDNS域名(回车使用上次保存的 ${OLD_CUSTOM_IP}):"
else
    echo "请输入节点连接 IP 或 DDNS域名(留空自动检测出口IP；NAT 机器请填商家给的入口IP/域名):"
fi
read -r CUSTOM_IP || CUSTOM_IP=""
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"
[ -z "$CUSTOM_IP" ] && CUSTOM_IP="$OLD_CUSTOM_IP"
while true; do
    if [ -n "$CUSTOM_IP" ]; then
        if validate_host "$(normalize_host "$CUSTOM_IP")"; then
            break
        fi
        err "地址无效: '${CUSTOM_IP}'（需为 IPv4、IPv6 或域名）"
    else
        info "正在检测公网 IP（IPv4 优先，其次 IPv6）..."
        if ! detect_public_ip; then
            warn "无法自动检测到公网 IP（网络不通或检测接口被墙），请手动输入入口地址"
        elif [ -n "$NAT_REASON" ]; then
            explain_nat
        else
            info "检测到公网 IP: ${DETECTED_IP}${DETECTED_ORG:+ (${DETECTED_ORG})}"
            break
        fi
    fi
    echo "请输入节点连接 IP 或域名(商家面板里的入口地址):"
    read -r CUSTOM_IP || { err "没有读到输入，退出"; exit 1; }
    CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"
done
fi

# -----------------------
# Reality 目标网站(SNI)检查：只警告，不阻止
# 从本机对 SNI:443 做 TLS1.3 + h2 握手（Reality 要求目标支持 TLS1.3，h2 更像正常浏览器流量）
reality_target_check() {
    local sni="$1" out
    if ! command -v openssl >/dev/null 2>&1; then
        warn "未找到 openssl，跳过 Reality 目标网站握手检查"
        return 0
    fi
    if command -v timeout >/dev/null 2>&1; then
        out=$(timeout 10 openssl s_client -connect "${sni}:443" -servername "$sni" -tls1_3 -alpn h2 </dev/null 2>&1 || true)
    else
        out=$(openssl s_client -connect "${sni}:443" -servername "$sni" -tls1_3 -alpn h2 </dev/null 2>&1 || true)
    fi
    if printf '%s\n' "$out" | grep -q 'TLSv1\.3' && printf '%s\n' "$out" | grep -q 'ALPN protocol: h2'; then
        info "✅ Reality 目标 ${sni}:443 握手正常（TLS1.3 + h2）"
        return 0
    fi
    warn "⚠️ 从本机对 ${sni}:443 的 TLS1.3 + h2 握手失败：该网站可能不支持 TLS1.3/h2，或本机连不上它。"
    warn "   Reality 节点可能无法使用，建议换一个 SNI。"
    return 1
}

# SNI 风险提示 + 握手检查 + 目标与本机所在地/运营商对比（尽力而为，查询失败不影响安装）
review_reality_sni() {
    local sni lsni bad=0 tip loc_cc loc_org tgt_ip tgt_cc tgt_org
    sni="$1"
    lsni=$(printf '%s' "$sni" | tr '[:upper:]' '[:lower:]')
    case "$lsni" in
        *apple*|*icloud*|*microsoft*|*.cn|*.ru|*.ir)
            warn "⚠️ SNI「${sni}」不推荐：apple/icloud/microsoft 相关域名或 .cn/.ru/.ir 结尾的网站作为 Reality 目标，"
            warn "   更容易导致服务器 IP 被墙（Xray-core 新版本如 v26.9.30 对这类目标也会输出同样的警告）。"
            bad=1
            ;;
    esac
    reality_target_check "$sni" || bad=1
    tgt_ip=$(curl -s -o /dev/null --max-time 6 -w '%{remote_ip}' "https://${sni}" 2>/dev/null || true)
    if [ -n "$tgt_ip" ]; then
        tgt_cc=$(curl -s --max-time 5 "https://ipinfo.io/${tgt_ip}/country" 2>/dev/null | tr -d '[:space:]' || true)
        tgt_org=$(curl -s --max-time 5 "https://ipinfo.io/${tgt_ip}/org" 2>/dev/null | head -n1 | tr -d '\r' || true)
        loc_cc=$(curl -s --max-time 5 "https://ipinfo.io/country" 2>/dev/null | tr -d '[:space:]' || true)
        loc_org=$(curl -s --max-time 5 "https://ipinfo.io/org" 2>/dev/null | head -n1 | tr -d '\r' || true)
        [[ "$tgt_cc" =~ ^[A-Z]{2}$ ]] || tgt_cc=""
        [[ "$loc_cc" =~ ^[A-Z]{2}$ ]] || loc_cc=""
        case "$tgt_org" in *"{"*|*"<"*) tgt_org="" ;; esac
        case "$loc_org" in *"{"*|*"<"*) loc_org="" ;; esac
        info "Reality 目标 ${sni} → ${tgt_ip} ${tgt_cc:+[$tgt_cc]} ${tgt_org}"
        [ -n "$loc_cc$loc_org" ] && info "本机出口 → ${loc_cc:+[$loc_cc]} ${loc_org}"
        if [ -n "$tgt_org" ] && [ -n "$loc_org" ] && [ "${tgt_org%% *}" = "${loc_org%% *}" ]; then
            info "目标网站和本机在同一个运营商(ASN)，很理想"
        elif [ -n "$tgt_cc" ] && [ -n "$loc_cc" ] && [ "$tgt_cc" != "$loc_cc" ]; then
            warn "目标网站服务器在 ${tgt_cc}，本机在 ${loc_cc}，相距可能较远（延迟高时更容易被识别）"
            bad=1
        fi
    fi
    tip="建议：Reality 的 SNI 最好选离本机近（同机房/同国家）、支持 TLS1.3 + h2 的网站；"
    tip="${tip}可在自己电脑上用 RealiTLScanner 扫描本机 IP 附近的网站（用法见 README）。"
    info "$tip"
    return "$bad"
}

# 如果用户选择了 Reality 协议，询问 server_name(SNI)
REALITY_SNI=""
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    while true; do
        echo ""
        echo "请输入 Reality 的 SNI(留空默认 addons.mozilla.org):"
        read -r REALITY_SNI || REALITY_SNI=""
        REALITY_SNI="$(echo "${REALITY_SNI:-addons.mozilla.org}" | tr -d '[:space:]')"
        info "正在检查 Reality 目标网站 ${REALITY_SNI} ..."
        if review_reality_sni "$REALITY_SNI"; then
            break
        fi
        read -r -p "是否重新输入 SNI?(y/N，回车继续使用 ${REALITY_SNI}): " RESNI || RESNI=""
        [[ "$RESNI" =~ ^[Yy]$ ]] || break
    done
else
    # 也设默认，方便后续统一处理（若未选 reality，也写入缓存以便 sb 读取）
    REALITY_SNI="addons.mozilla.org"
fi

# 将用户选择写入缓存
mkdir -p /etc/sing-box
# preserve existing cache if any (append/overwrite relevant keys)
# 最简单直接：在后面 create_config 也会写入 .config_cache，先写初始值以便中间步骤可读取
echo "CUSTOM_IP=$CUSTOM_IP" > /etc/sing-box/.config_cache.tmp || true
echo "REALITY_SNI=$REALITY_SNI" >> /etc/sing-box/.config_cache.tmp || true
# 保留其他可能已有的缓存条目（若存在老的 .config_cache），把新临时与旧文件合并（保新值覆盖旧值）
if [ -f /etc/sing-box/.config_cache ]; then
    # 将旧文件中不在新文件内的行追加
    awk 'FNR==NR{a[$1]=1;next} {split($0,k,"="); if(!(k[1] in a)) print $0}' /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache >> /etc/sing-box/.config_cache.tmp2 || true
    mv /etc/sing-box/.config_cache.tmp2 /etc/sing-box/.config_cache.tmp || true
fi
mv /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache || true

# -----------------------
# 生成随机端口
rand_port() {
    shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000))
}

# 生成随机密码
rand_pass() {
    openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'
}

# 生成UUID
rand_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# -----------------------
# 端口工具
# 端口校验 1-65535
validate_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]
}

# 端口是否已被系统占用：$1=端口 $2=tcp|udp（ss 优先，Alpine/busybox 回退 netstat；都没有时视为未占用）
port_in_use() {
    local port="$1" flag="-lnt" out=""
    [ "${2:-tcp}" = "udp" ] && flag="-lnu"
    if command -v ss >/dev/null 2>&1; then
        out=$(ss "$flag" 2>/dev/null | awk 'NR>1{print $4}' || true)
    elif command -v netstat >/dev/null 2>&1; then
        out=$(netstat "$flag" 2>/dev/null | awk '{print $4}' || true)
    fi
    printf '%s\n' "$out" | grep -qE "[:.]${port}\$"
}

# 本次安装已分配的端口（分 TCP/UDP 记录，值为协议名）
# SS 同时用 TCP+UDP；HY2/TUIC 只用 UDP；Reality/AnyTLS 只用 TCP
# 所以 Reality/AnyTLS 可以和 HY2/TUIC 使用同一个端口号
declare -A USED_TCP=() USED_UDP=()
NAT_RANGES=()

# 本机线路机节点(sing-box-relay)已占用的端口：落地机节点不能再用
if [ -f /etc/sing-box-relay/config.json ] && command -v jq >/dev/null 2>&1; then
    for _rp in $(jq -r '(.inbounds // [])[].listen_port // empty' /etc/sing-box-relay/config.json 2>/dev/null || true); do
        if validate_port "$_rp"; then
            USED_TCP[$_rp]="本机线路机节点(sing-box-relay)"
            USED_UDP[$_rp]="本机线路机节点(sing-box-relay)"
        fi
    done
    unset _rp
fi
NAT_PORT_RANGE=""

# 解析商家端口范围，例如 "56566-56586" 或 "20001,20002 20005" 或混合；结果放 NAT_RANGES("低 高")
parse_port_ranges() {
    local item lo hi
    NAT_RANGES=()
    for item in $(printf '%s' "$1" | tr ',，;' '   '); do
        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            lo="$item"; hi="$item"
        else
            return 1
        fi
        validate_port "$lo" && validate_port "$hi" || return 1
        lo=$((10#$lo)); hi=$((10#$hi))
        [ "$lo" -le "$hi" ] || return 1
        NAT_RANGES+=("$lo $hi")
    done
    [ "${#NAT_RANGES[@]}" -gt 0 ]
}

port_in_ranges() {
    local r lo hi
    for r in "${NAT_RANGES[@]}"; do
        lo=${r% *}; hi=${r#* }
        [ "$1" -ge "$lo" ] && [ "$1" -le "$hi" ] && return 0
    done
    return 1
}

# 本次已分配端口中与 $1 冲突的协议名（$2=需要的网络 "tcp" "udp" 或 "tcp udp"）
port_conflict() {
    local n
    for n in $2; do
        if [ "$n" = "tcp" ] && [ -n "${USED_TCP[$1]:-}" ]; then printf '%s(TCP)' "${USED_TCP[$1]}"; return 0; fi
        if [ "$n" = "udp" ] && [ -n "${USED_UDP[$1]:-}" ]; then printf '%s(UDP)' "${USED_UDP[$1]}"; return 0; fi
    done
    return 1
}

port_busy_os() {
    local n
    for n in $2; do port_in_use "$1" "$n" && return 0; done
    return 1
}

# 随机挑一个可用端口：有商家端口范围时只在范围内挑
pick_random_port() {
    local nets="$1" p r lo hi mode=tcp
    if $NAT_ON; then
        [ "$nets" = "udp" ] && mode=udp
        [ "$nets" = "tcp udp" ] && mode=ss
        nat_pick "$mode"
        return $?
    fi
    for _ in $(seq 1 300); do
        if [ "${#NAT_RANGES[@]}" -gt 0 ]; then
            r="${NAT_RANGES[$((RANDOM % ${#NAT_RANGES[@]}))]}"
            lo=${r% *}; hi=${r#* }
            p=$(shuf -i "${lo}-${hi}" -n 1 2>/dev/null || echo $((lo + RANDOM % (hi - lo + 1))))
        else
            p=$(rand_port)
        fi
        port_conflict "$p" "$nets" >/dev/null && continue
        port_busy_os "$p" "$nets" && continue
        printf '%s' "$p"
        return 0
    done
    return 1
}

# 询问某协议端口：$1=协议名 $2=环境变量给定的端口(可空) $3=网络("tcp"/"udp"/"tcp udp")；结果 CHOSEN_PORT
ask_proto_port() {
    local label="$1" envval="$2" nets="$3" p ans hint conflict n
    if $NAT_ON; then
        hint="留空则从映射端口中自动选；SSH 端口 ${NAT_SSH_PORT:-无} 不能用"
    elif [ "${#NAT_RANGES[@]}" -gt 0 ]; then
        hint="留空则从商家端口范围 ${NAT_PORT_RANGE} 中随机"
    else
        hint="留空则随机 10000-60000"
    fi
    while true; do
        if [ -n "$envval" ]; then
            p="$envval"; envval=""
        else
            read -r -p "请输入 ${label} 端口(${hint}): " p || p=""
            p=$(printf '%s' "$p" | tr -d '[:space:]')
        fi
        if [ -z "$p" ]; then
            if ! p=$(pick_random_port "$nets"); then
                err "没有找到可用的随机端口（商家端口范围可能已用完），请手动输入"
                continue
            fi
        else
            if ! validate_port "$p"; then
                err "端口无效: '$p'（需为 1-65535 的数字）"
                continue
            fi
            p=$((10#$p))
            if conflict=$(port_conflict "$p" "$nets"); then
                err "端口 $p 已被 ${conflict} 使用，请换一个"
                continue
            fi
            if $NAT_ON && [ "$p" = "${NAT_SSH_PORT:-}" ]; then
                err "端口 $p 是 SSH 用的映射端口，不能用"
                continue
            fi
            if $NAT_ON && [ "$nets" = "udp" ] && in_words "$p" "$NAT_PORTS" && ! in_words "$p" "$NAT_UDP_PORTS"; then
                warn "端口 $p 没有映射 UDP（你填写的 UDP 端口: ${NAT_UDP_PORTS:-无}），${label} 用 UDP，外网连不上"
                read -r -p "仍然使用 $p ?(y/N): " ans || ans=""
                [[ "$ans" =~ ^[Yy]$ ]] || continue
            fi
            if [ "${#NAT_RANGES[@]}" -gt 0 ] && ! port_in_ranges "$p"; then
                warn "端口 $p 不在你填写的商家端口范围(${NAT_PORT_RANGE})内，NAT 机器上外网很可能连不上"
                read -r -p "仍然使用 $p ?(y/N): " ans || ans=""
                [[ "$ans" =~ ^[Yy]$ ]] || continue
            fi
            if port_busy_os "$p" "$nets" && ! { $NAT_ON && old_landing_port "$p"; }; then
                warn "端口 $p 已被本机程序占用（如果是旧的 sing-box 占用，重装后会自动释放，可以继续）"
                read -r -p "仍然使用 $p ?(y/N): " ans || ans=""
                [[ "$ans" =~ ^[Yy]$ ]] || continue
            fi
        fi
        break
    done
    for n in $nets; do
        if [ "$n" = "tcp" ]; then USED_TCP[$p]="$label"; else USED_UDP[$p]="$label"; fi
        nat_mark "$p" "$n"
    done
    CHOSEN_PORT="$p"
}

# 端口是否写在本机旧的落地机配置里（重装时这些端口会被释放，不算占用）
old_landing_port() {
    [ -f "$LANDING_CONFIG" ] && command -v jq >/dev/null 2>&1 \
        && jq -e --argjson p "$1" 'any((.inbounds // [])[]; .listen_port == $p)' "$LANDING_CONFIG" >/dev/null 2>&1
}

# NAT 模式：按协议自动分配映射端口。结果 NAT_A_<协议>（nat_auto 间接读取），放不下的协议在 NAT_UNPLACED
# shellcheck disable=SC2034
nat_assign() {
    local p
    nat_collect_used "$RELAY_CONFIG_FILE"
    NAT_UNPLACED=""
    NAT_A_SS=""; NAT_A_HY2=""; NAT_A_TUIC=""; NAT_A_REALITY=""; NAT_A_ANYTLS=""
    # 先放只能用 UDP 的 HY2/TUIC，再放 SS(TCP+UDP)，最后 Reality/AnyTLS(TCP)
    if $ENABLE_HY2; then
        if p=$(nat_pick udp); then NAT_A_HY2=$p; nat_mark "$p" udp; NAT_LABEL[$p]="${NAT_LABEL[$p]:+${NAT_LABEL[$p]}, }HY2(UDP)"; else NAT_UNPLACED="$NAT_UNPLACED HY2"; fi
    fi
    if $ENABLE_TUIC; then
        if p=$(nat_pick udp); then NAT_A_TUIC=$p; nat_mark "$p" udp; NAT_LABEL[$p]="${NAT_LABEL[$p]:+${NAT_LABEL[$p]}, }TUIC(UDP)"; else NAT_UNPLACED="$NAT_UNPLACED TUIC"; fi
    fi
    if $ENABLE_SS; then
        if p=$(nat_pick ss); then
            NAT_A_SS=$p; nat_mark "$p" tcp; nat_mark "$p" udp
            if in_words "$p" "$NAT_UDP_PORTS"; then NAT_LABEL[$p]="SS(TCP+UDP)"; else NAT_LABEL[$p]="SS(TCP，UDP 未映射)"; fi
        else NAT_UNPLACED="$NAT_UNPLACED SS"; fi
    fi
    if $ENABLE_REALITY; then
        if p=$(nat_pick tcp); then NAT_A_REALITY=$p; nat_mark "$p" tcp; NAT_LABEL[$p]="${NAT_LABEL[$p]:+${NAT_LABEL[$p]}, }VLESS Reality(TCP)"; else NAT_UNPLACED="$NAT_UNPLACED Reality"; fi
    fi
    if $ENABLE_ANYTLS; then
        if p=$(nat_pick tcp); then NAT_A_ANYTLS=$p; nat_mark "$p" tcp; NAT_LABEL[$p]="${NAT_LABEL[$p]:+${NAT_LABEL[$p]}, }AnyTLS(TCP)"; else NAT_UNPLACED="$NAT_UNPLACED AnyTLS"; fi
    fi
    NAT_UNPLACED="${NAT_UNPLACED# }"
}

# 去掉放不下的协议
nat_drop_protocols() {
    local x
    for x in $1; do
        case "$x" in
            SS) ENABLE_SS=false ;; HY2) ENABLE_HY2=false ;; TUIC) ENABLE_TUIC=false ;;
            Reality) ENABLE_REALITY=false ;; AnyTLS) ENABLE_ANYTLS=false ;;
        esac
    done
    cat > /etc/sing-box/.protocols <<PROTO
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
PROTO
    info "已去掉: $1"
}

# NAT 模式：填写映射端口 → 自动分配 → 显示 端口→协议 表 → 确认
NAT_MANUAL=false
nat_ports_flow() {
    local ans
    nat_ask_ports
    while true; do
        NAT_PORT_RANGE=$(printf '%s' "$NAT_PORTS" | tr ' ' ',')
        parse_port_ranges "$NAT_PORT_RANGE" || true
        nat_assign
        if [ -n "$NAT_UNPLACED" ]; then
            echo ""
            warn "映射端口不够用：${NAT_UNPLACED} 没有可用的端口（HY2/TUIC 只能放在映射了 UDP 的端口；SSH 端口不会用）"
            if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
                err "没有选择任何协议"; exit 1
            fi
            read -r -p "回车 = 去掉 ${NAT_UNPLACED} 继续安装 / r = 重新填写映射端口 / n = 退出: " ans || ans=n
            case "$ans" in
                [Rr]*) unset SINGBOX_NAT_PORTS SINGBOX_NAT_UDP SINGBOX_NAT_SSH_PORT; nat_ask_ports; continue ;;
                [Nn]*) info "已退出，没有改动"; exit 1 ;;
                *)
                    nat_drop_protocols "$NAT_UNPLACED"
                    if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
                        err "去掉之后没有可安装的协议了，请补充映射端口后重新运行"; exit 1
                    fi
                    continue
                    ;;
            esac
        fi
        echo ""
        info "=== NAT 模式端口分配（只用映射端口）==="
        nat_table
        read -r -p "确认按此分配?(回车/Y = 确认 / m = 手动指定每个协议的端口 / r = 重新填写映射端口 / n = 取消安装): " ans || ans=""
        case "$ans" in
            [Mm]*) NAT_MANUAL=true; nat_collect_used "$RELAY_CONFIG_FILE"; break ;;
            [Rr]*) unset SINGBOX_NAT_PORTS SINGBOX_NAT_UDP SINGBOX_NAT_SSH_PORT; nat_ask_ports ;;
            [Nn]*) info "已取消安装，没有改动"; exit 1 ;;
            *) break ;;
        esac
    done
}

udp_reminder() {
    if $NAT_ON && in_words "$2" "$NAT_UDP_PORTS"; then
        info "$1 使用映射了 UDP 的端口 $2（你已确认商家映射了 UDP）"
        return 0
    fi
    warn "$1 使用 UDP 端口 $2：NAT 机器必须确认商家把这个端口的【UDP】也映射了（很多 NAT 只映射 TCP），"
    warn "   云厂商安全组/防火墙也要放行 UDP $2，否则 $1 连不上。"
}

# NAT 模式自动分配的端口（手动模式或非 NAT 模式为空，此时会询问）
nat_auto() {
    $NAT_ON && ! $NAT_MANUAL || return 0
    local v="NAT_A_$1"
    printf '%s' "${!v:-}"
}

# -----------------------
# 配置端口和密码
get_config() {
    info "开始配置端口和密码..."

    if $NAT_ON; then
        nat_ports_flow
    fi
    # 端口范围模式(旧)：商家只给了一段端口时，随机端口只在这段范围里挑（NAT 模式下已用上面的映射端口列表）
    $NAT_ON || NAT_PORT_RANGE="${SINGBOX_NAT_PORTS:-}"
    if ! $NAT_ON && [ -z "$NAT_PORT_RANGE" ]; then
        echo ""
        echo "如果这是 NAT 机器(商家只给了部分端口，例如 56566-56586)，请输入商家给的端口范围，脚本只在其中随机选端口。"
        echo "多个范围/端口用逗号分隔，例如: 56566-56586 或 20001,20002,20003 。普通 VPS 直接回车跳过。"
        read -r -p "商家端口范围(回车跳过): " NAT_PORT_RANGE || NAT_PORT_RANGE=""
    fi
    while ! $NAT_ON && [ -n "$NAT_PORT_RANGE" ] && ! parse_port_ranges "$NAT_PORT_RANGE"; do
        err "端口范围格式不对: '$NAT_PORT_RANGE'（例: 56566-56586 或 20001,20002）"
        read -r -p "商家端口范围(回车跳过): " NAT_PORT_RANGE || NAT_PORT_RANGE=""
    done
    if ! $NAT_ON && [ -n "$NAT_PORT_RANGE" ]; then
        info "端口范围模式：随机端口只从 ${NAT_PORT_RANGE} 中选择"
        info "提示：Reality/AnyTLS(TCP) 和 HY2/TUIC(UDP) 可以使用同一个端口号；SS 同时占用该端口的 TCP 和 UDP"
    fi

    if $ENABLE_SS; then
        info "=== 配置 Shadowsocks (SS) ==="
        ask_proto_port "SS" "${SINGBOX_PORT_SS:-$(nat_auto SS)}" "tcp udp"
        PORT_SS="$CHOSEN_PORT"
        PSK_SS=$(rand_pass)
        info "SS 端口: $PORT_SS (TCP+UDP)"
        info "SS 加密方式: $SS_METHOD"
        info "SS 密码已自动生成"
    fi

    if $ENABLE_HY2; then
        info "=== 配置 Hysteria2 (HY2) ==="
        ask_proto_port "HY2" "${SINGBOX_PORT_HY2:-$(nat_auto HY2)}" "udp"
        PORT_HY2="$CHOSEN_PORT"
        PSK_HY2=$(rand_pass)
        info "HY2 端口: $PORT_HY2 (UDP)"
        info "HY2 密码已自动生成"
        udp_reminder "HY2" "$PORT_HY2"
    fi

    if $ENABLE_TUIC; then
        info "=== 配置 TUIC ==="
        ask_proto_port "TUIC" "${SINGBOX_PORT_TUIC:-$(nat_auto TUIC)}" "udp"
        PORT_TUIC="$CHOSEN_PORT"
        PSK_TUIC=$(rand_pass)
        UUID_TUIC=$(rand_uuid)
        info "TUIC 端口: $PORT_TUIC (UDP)"
        info "TUIC UUID 和密码已自动生成"
        udp_reminder "TUIC" "$PORT_TUIC"
    fi

    if $ENABLE_REALITY; then
        info "=== 配置 VLESS Reality ==="
        ask_proto_port "VLESS Reality" "${SINGBOX_PORT_REALITY:-$(nat_auto REALITY)}" "tcp"
        PORT_REALITY="$CHOSEN_PORT"
        UUID=$(rand_uuid)
        info "VLESS Reality 端口: $PORT_REALITY (TCP)"
        info "VLESS Reality UUID 已自动生成"
    fi

    if $ENABLE_ANYTLS; then
        info "=== 配置 AnyTLS Reality ==="
        ask_proto_port "AnyTLS Reality" "${SINGBOX_PORT_ANYTLS:-$(nat_auto ANYTLS)}" "tcp"
        PORT_ANYTLS="$CHOSEN_PORT"
        ANYTLS_USER=$(openssl rand -hex 4 2>/dev/null || head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
        ANYTLS_PSK=$(rand_pass)
        info "AnyTLS Reality 端口: $PORT_ANYTLS (TCP)"
        info "AnyTLS Reality 用户名: $ANYTLS_USER"
        info "AnyTLS Reality 密码已自动生成"
    fi

    info "配置完成，继续安装..."
}

get_config

# -----------------------
# 安装 sing-box
install_singbox() {
    info "开始安装 sing-box..."

    if command -v sing-box >/dev/null 2>&1; then
        CURRENT_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
        warn "检测到已安装 sing-box: $CURRENT_VERSION"
        local have
        have=$(sb_version)
        if [ -n "$have" ] && ! ver_ge "$have" "$SB_MIN_VER"; then
            warn "已安装的 sing-box $have 低于本次所选协议需要的 $SB_MIN_VER（AnyTLS 需要 1.12，HY2 的 BBR 设置需要 1.11）"
            read -r -p "是否重新安装新版?(Y/n): " REINSTALL || REINSTALL=""
            [[ "$REINSTALL" =~ ^[Nn]$ ]] && { warn "继续使用 $have，可能出现配置校验失败"; return 0; }
        else
            read -p "是否重新安装?(y/N): " REINSTALL
            if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
                info "跳过 sing-box 安装"
                return 0
            fi
        fi
    fi

    case "$OS" in
        alpine)
            install_singbox_alpine "$SB_MIN_VER" || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        debian|redhat)
            (cd "$(mktemp -d)" && bash <(curl -fsSL https://sing-box.app/install.sh)) || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        *)
            err "未支持的系统,无法安装 sing-box"
            exit 1
            ;;
    esac

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 安装后未找到可执行文件"
        exit 1
    fi

    INSTALLED_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
    info "sing-box 安装成功: $INSTALLED_VERSION"
}

# ===== 安装 sing-box：Alpine 优先官方仓库，版本太旧/没有时从 GitHub 下载官方二进制，再不行用 edge 仓库 =====
SB_MIN_VER="1.11.0"   # hysteria2 ignore_client_bandwidth 需要 1.11；AnyTLS 需要 1.12（落地机安装时会提高要求）
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]; }
sb_version() { sing-box version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true; }
sb_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; armv7*) echo armv7 ;; armv6*) echo armv6 ;;
        i?86) echo 386 ;; s390x) echo s390x ;; riscv64) echo riscv64 ;; *) return 1 ;;
    esac
}
install_singbox_github() {
    local arch ver tmp dir v variants
    arch=$(sb_arch) || { err "不支持的 CPU 架构: $(uname -m)"; return 1; }
    ver=$(curl -fsSI --max-time 15 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | tr -d '\r' \
        | awk 'tolower($1)=="location:"{n=split($2,a,"/"); print a[n]}' | sed 's/^v//' || true)
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn "获取 GitHub 上 sing-box 最新版本失败"; return 1; }
    # Alpine(musl) 先用 -musl 版本；其他系统先用默认版本；下载后先运行一次确认能用，才替换现有程序
    if ls /lib/ld-musl-* >/dev/null 2>&1; then variants="musl plain"; else variants="plain glibc"; fi
    tmp=$(mktemp -d)
    for v in $variants; do
        if [ "$v" = "plain" ]; then v=""; else v="-$v"; fi
        dir="sing-box-${ver}-linux-${arch}${v}"
        info "从 GitHub 下载 sing-box ${ver}（官方程序 ${arch}${v}）..."
        rm -rf "${tmp:?}"/*
        if curl -fsSL --max-time 300 -o "$tmp/sb.tgz" "https://github.com/SagerNet/sing-box/releases/download/v${ver}/${dir}.tar.gz" \
            && tar -xzf "$tmp/sb.tgz" -C "$tmp" && [ -f "$tmp/$dir/sing-box" ] && "$tmp/$dir/sing-box" version >/dev/null 2>&1; then
            cp "$tmp/$dir/sing-box" /usr/bin/sing-box.new && chmod 755 /usr/bin/sing-box.new && mv -f /usr/bin/sing-box.new /usr/bin/sing-box
            rm -rf "$tmp"
            return 0
        fi
    done
    rm -rf "$tmp" /usr/bin/sing-box.new
    warn "从 GitHub 下载 sing-box 失败(或下载的程序在本机无法运行)"
    return 1
}
# $1 = 最低版本
install_singbox_alpine() {
    local need="${1:-$SB_MIN_VER}" repo
    repo=$(apk --no-cache search -x sing-box 2>/dev/null | sed -n 's/^sing-box-\([0-9][0-9.]*\)-r[0-9]*$/\1/p' | head -n1 || true)
    if [ -n "$repo" ] && ver_ge "$repo" "$need"; then
        info "使用 Alpine 官方仓库的 sing-box $repo"
        apk add --no-cache sing-box && return 0
    elif [ -n "$repo" ]; then
        warn "Alpine 官方仓库的 sing-box 是 $repo，低于本脚本需要的 $need，改从 GitHub 下载"
    else
        info "当前 Alpine 版本的官方仓库没有 sing-box，改从 GitHub 下载"
    fi
    install_singbox_github && return 0
    warn "改用 Alpine edge 仓库安装 sing-box"
    apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box
}
# 本次所选协议需要的最低 sing-box 版本：AnyTLS 1.12，其余 1.11（HY2 ignore_client_bandwidth）
$ENABLE_ANYTLS && SB_MIN_VER="1.12.0"

# -----------------------
# 纯 IPv6 机器：GitHub 等不支持 IPv6，sing-box 官方安装脚本会下载失败
# 提示使用公共 NAT64/DNS64（nat64.net 提供），可选临时切换 /etc/resolv.conf，安装后自动恢复
RESOLV_BAK=""
RESOLV_MODE=""
restore_resolv() {
    [ -n "$RESOLV_BAK" ] || return 0
    case "$RESOLV_MODE" in
        mv)   rm -f /etc/resolv.conf; mv -f "$RESOLV_BAK" /etc/resolv.conf ;;
        cp)   if cat "$RESOLV_BAK" > /etc/resolv.conf; then rm -f "$RESOLV_BAK"
              else warn "恢复 /etc/resolv.conf 失败，原文件保存在 $RESOLV_BAK，请手动恢复"; fi ;;
        none) rm -f /etc/resolv.conf ;;
    esac
    RESOLV_BAK=""
    info "已恢复原来的 /etc/resolv.conf"
}

check_ipv6_only_download() {
    local has4 has6 ans
    command -v ip >/dev/null 2>&1 || return 0
    has4=$(ip -4 route show default 2>/dev/null | head -n1 || true)
    has6=$(ip -6 route show default 2>/dev/null | head -n1 || true)
    if [ -n "$has4" ] || [ -z "$has6" ]; then
        return 0
    fi
    info "检测到本机只有 IPv6（没有 IPv4 默认路由）"
    if [ "$OS" = "alpine" ]; then
        info "Alpine 会从 Alpine 官方仓库安装 sing-box（dl-cdn.alpinelinux.org 支持 IPv6），一般不需要额外设置"
        return 0
    fi
    if curl -s --max-time 8 -o /dev/null https://github.com && curl -s --max-time 8 -o /dev/null https://sing-box.app/install.sh; then
        info "GitHub 可以访问，继续安装"
        return 0
    fi
    warn "=================== ⚠️ 纯 IPv6 机器无法访问 GitHub ==================="
    warn "sing-box 官方安装脚本要从 GitHub 下载，而 GitHub 不支持 IPv6，直接安装会失败。"
    echo "   解决办法：临时把 DNS 换成公共 NAT64/DNS64 服务器（nat64.net 免费提供），"
    echo "   它会让纯 IPv6 机器也能访问只有 IPv4 的网站。服务器地址: 2a00:1098:2b::1 、2a01:4f8:c2c:123f::1"
    echo "   手动做法: cp /etc/resolv.conf /etc/resolv.conf.bak && echo 'nameserver 2a00:1098:2b::1' > /etc/resolv.conf"
    echo "             装完后再改回: mv /etc/resolv.conf.bak /etc/resolv.conf"
    warn "======================================================================"
    read -r -p "是否让脚本临时切换 DNS 到 NAT64，安装完成后自动恢复原 DNS?(y/N): " ans || ans=""
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        warn "未切换 DNS，继续尝试安装（可能失败）"
        return 0
    fi
    RESOLV_BAK="/etc/resolv.conf.sb-nat64-bak"
    if [ ! -e /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
        RESOLV_MODE="none"
    elif mv /etc/resolv.conf "$RESOLV_BAK" 2>/dev/null; then
        RESOLV_MODE="mv"
    elif cp /etc/resolv.conf "$RESOLV_BAK" 2>/dev/null; then
        RESOLV_MODE="cp"
    else
        err "无法备份 /etc/resolv.conf，已放弃切换 DNS"
        RESOLV_BAK=""
        return 0
    fi
    trap restore_resolv EXIT
    if ! printf 'nameserver 2a00:1098:2b::1\nnameserver 2a01:4f8:c2c:123f::1\n' > /etc/resolv.conf 2>/dev/null; then
        err "无法写入 /etc/resolv.conf（可能被系统锁定），已放弃切换 DNS"
        restore_resolv
        trap - EXIT
        return 0
    fi
    info "已临时切换 DNS 到 NAT64（原文件备份为 $RESOLV_BAK，安装完成或脚本退出时自动恢复）"
}

check_ipv6_only_download
install_singbox
restore_resolv
trap - EXIT

# -----------------------
# 生成 Reality 密钥对（必须在 sing-box 安装之后）
generate_reality_keys() {
    if ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        info "跳过 Reality 密钥生成（未选择 Reality 协议）"
        return 0
    fi
    
    info "生成 Reality 密钥对..."
    
    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 未安装，无法生成 Reality 密钥"
        exit 1
    fi
    
    REALITY_KEYS=$(sing-box generate reality-keypair 2>&1) || {
        err "生成 Reality 密钥失败"
        exit 1
    }
    
    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || {
        err "生成 Reality ShortID 失败"
        exit 1
    }
    
    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ] || [ -z "$REALITY_SID" ]; then
        err "Reality 密钥生成结果为空"
        exit 1
    fi
    
    mkdir -p /etc/sing-box
    echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
    echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid
    
    info "Reality 密钥已生成"
}

generate_reality_keys

# -----------------------
# 生成 HY2/TUIC 自签证书(仅在需要时)
generate_cert() {
    if ! $ENABLE_HY2 && ! $ENABLE_TUIC; then
        info "跳过证书生成(未选择 HY2 或 TUIC)"
        return 0
    fi
    
    info "生成 HY2/TUIC 自签证书..."
    mkdir -p /etc/sing-box/certs
    
    if [ ! -f /etc/sing-box/certs/fullchain.pem ] || [ ! -f /etc/sing-box/certs/privkey.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /etc/sing-box/certs/privkey.pem \
          -out /etc/sing-box/certs/fullchain.pem \
          -days 3650 \
          -subj "/CN=www.bing.com" || {
            err "证书生成失败"
            exit 1
        }
        info "证书已生成"
    else
        info "证书已存在"
    fi
}

generate_cert

# -----------------------
# sing-box 版本 >= $1.$2 ?
singbox_at_least() {
    local v maj min
    v=$(sing-box version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)
    [ -n "$v" ] || return 1
    maj=${v%%.*}; min=$(printf '%s' "$v" | cut -d. -f2)
    [ "$maj" -gt "$1" ] || { [ "$maj" -eq "$1" ] && [ "$min" -ge "$2" ]; }
}

# -----------------------
# 生成配置文件
CONFIG_PATH="/etc/sing-box/config.json"

create_config() {
    info "生成配置文件: $CONFIG_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"

    # 重装时先备份旧配置；新配置校验不通过就还原，避免把正在运行的节点弄坏
    CONFIG_BAK=""
    if [ -f "$CONFIG_PATH" ]; then
        CONFIG_BAK="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$CONFIG_PATH" "$CONFIG_BAK"
        info "旧配置已备份到: $CONFIG_BAK"
    fi

    # 构建 inbounds 内容（使用临时文件避免字符串处理问题）
    local TEMP_INBOUNDS="/tmp/singbox_inbounds_$.json"
    > "$TEMP_INBOUNDS"
    
    local need_comma=false
    
    if $ENABLE_SS; then
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_SS'
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": PORT_SS_PLACEHOLDER,
      "method": "METHOD_SS_PLACEHOLDER",
      "password": "PSK_SS_PLACEHOLDER",
      "tag": "ss-in"
    }
INBOUND_SS
        sed -i "s|PORT_SS_PLACEHOLDER|$PORT_SS|g" "$TEMP_INBOUNDS"
        sed -i "s|METHOD_SS_PLACEHOLDER|$SS_METHOD|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_SS_PLACEHOLDER|$PSK_SS|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_HY2; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_HY2'
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": PORT_HY2_PLACEHOLDER,
      "users": [
        {
          "password": "PSK_HY2_PLACEHOLDER"
        }
      ],
      "ignore_client_bandwidth": true,
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_HY2
        sed -i "s|PORT_HY2_PLACEHOLDER|$PORT_HY2|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_HY2_PLACEHOLDER|$PSK_HY2|g" "$TEMP_INBOUNDS"
        # ignore_client_bandwidth（sing-box 1.11+）：未设置 up/down_mbps 时让客户端使用 BBR 拥塞控制，
        # 不按客户端填写的带宽跑 Brutal。旧版 sing-box 不认识该字段，去掉以免配置校验失败
        if ! singbox_at_least 1 11; then
            sed -i '/"ignore_client_bandwidth"/d' "$TEMP_INBOUNDS"
        fi
        need_comma=true
    fi
    
    if $ENABLE_TUIC; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_TUIC'
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": PORT_TUIC_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_TUIC_PLACEHOLDER",
          "password": "PSK_TUIC_PLACEHOLDER"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_TUIC
        sed -i "s|PORT_TUIC_PLACEHOLDER|$PORT_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_TUIC_PLACEHOLDER|$UUID_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_TUIC_PLACEHOLDER|$PSK_TUIC|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_REALITY; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_REALITY'
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": PORT_REALITY_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_REALITY_PLACEHOLDER",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": ["REALITY_SID_PLACEHOLDER"]
        }
      }
    }
INBOUND_REALITY
        sed -i "s|PORT_REALITY_PLACEHOLDER|$PORT_REALITY|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_REALITY_PLACEHOLDER|$UUID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_ANYTLS; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_ANYTLS'
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": PORT_ANYTLS_PLACEHOLDER,
      "users": [
        {
          "name": "ANYTLS_USER_PLACEHOLDER",
          "password": "ANYTLS_PSK_PLACEHOLDER"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": [
            "REALITY_SID_PLACEHOLDER"
          ]
        }
      }
    }
INBOUND_ANYTLS

    sed -i "s|PORT_ANYTLS_PLACEHOLDER|$PORT_ANYTLS|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_USER_PLACEHOLDER|$ANYTLS_USER|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_PSK_PLACEHOLDER|$ANYTLS_PSK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"

    need_comma=true
    fi

    # 生成最终配置
    cat > "$CONFIG_PATH" <<'CONFIG_HEAD'
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "inbounds": [
CONFIG_HEAD
    
    cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"
    
    cat >> "$CONFIG_PATH" <<'CONFIG_TAIL'
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
CONFIG_TAIL

    rm -f "$TEMP_INBOUNDS"

    local check_out
    if check_out=$(sing-box check -c "$CONFIG_PATH" 2>&1); then
        info "配置文件验证通过"
    else
        err "配置文件校验失败(sing-box check):"
        printf '%s\n' "$check_out" | tail -n 20 >&2
        if [ -n "$CONFIG_BAK" ]; then
            cp "$CONFIG_BAK" "$CONFIG_PATH"
            err "已还原旧配置($CONFIG_BAK)，服务未改动。请把上面的错误信息反馈给作者。"
        else
            mv "$CONFIG_PATH" "${CONFIG_PATH}.invalid"
            err "错误的配置已保存为 ${CONFIG_PATH}.invalid，安装中止。"
        fi
        exit 1
    fi

    # 保存配置缓存（追加/覆盖）
    cat > /etc/sing-box/.config_cache <<CACHEEOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
CACHEEOF

    $ENABLE_SS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
SS_PORT=$PORT_SS
SS_PSK=$PSK_SS
SS_METHOD=$SS_METHOD
CACHEEOF

    $ENABLE_HY2 && cat >> /etc/sing-box/.config_cache <<CACHEEOF
HY2_PORT=$PORT_HY2
HY2_PSK=$PSK_HY2
CACHEEOF

    $ENABLE_TUIC && cat >> /etc/sing-box/.config_cache <<CACHEEOF
TUIC_PORT=$PORT_TUIC
TUIC_UUID=$UUID_TUIC
TUIC_PSK=$PSK_TUIC
CACHEEOF

    $ENABLE_REALITY && cat >> /etc/sing-box/.config_cache <<CACHEEOF
REALITY_PORT=$PORT_REALITY
REALITY_UUID=$UUID
REALITY_PK=$REALITY_PK
REALITY_SID=$REALITY_SID
REALITY_PUB=$REALITY_PUB
REALITY_SNI=$REALITY_SNI
CACHEEOF

    $ENABLE_ANYTLS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
ANYTLS_PORT=$PORT_ANYTLS
ANYTLS_USER=$ANYTLS_USER
ANYTLS_PSK=$ANYTLS_PSK
CACHEEOF

    # 全局写入 CUSTOM_IP（哪怕为空也写）
    echo "CUSTOM_IP=$CUSTOM_IP" >> /etc/sing-box/.config_cache
    # NAT 模式下商家给的端口范围（仅作记录，方便以后查看）
    printf 'NAT_PORT_RANGE=%q\n' "${NAT_PORT_RANGE:-}" >> /etc/sing-box/.config_cache

    info "配置缓存已保存到 /etc/sing-box/.config_cache"
}

# 调用配置生成
create_config

# NAT 模式设置保存到 /etc/sb-nat.conf（落地机/线路机共用）；拒绝 NAT 模式时记录为关闭
if $NAT_ON; then
    NAT_MODE=1
    nat_save
    info "NAT 模式设置已保存到 $NAT_CONF（映射端口: $NAT_PORTS，入口IP: $ENTRY_IP）"
elif $NAT_ASKED && [ -f "$NAT_CONF" ]; then
    NAT_MODE=0
    nat_save
fi

info "配置生成完成，准备设置服务..."

# -----------------------
# 设置服务
setup_service() {
    info "配置系统服务..."
    
    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"
        
        cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
# 自动拉起（程序崩溃、OOM、被 kill 后自动恢复）
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
OPENRC
        
        if [ "${LOW_MEM:-false}" = "true" ]; then
            # 低内存模式：通过 supervise-daemon --env 传给 sing-box，同时 export 兼容其他启动方式
            sed -i "s|^supervise_daemon_args=\"\(.*\)\"|supervise_daemon_args=\"\1 --env GOMEMLIMIT=${GO_MEMLIMIT} --env GOGC=70\"|" "$SERVICE_PATH"
            sed -i "s|^name=\"sing-box\"|export GOMEMLIMIT=${GO_MEMLIMIT}\nexport GOGC=70\nname=\"sing-box\"|" "$SERVICE_PATH"
            info "低内存模式: 已在 $SERVICE_PATH 设置 GOMEMLIMIT=${GO_MEMLIMIT} GOGC=70"
        fi
        chmod +x "$SERVICE_PATH"
        rc-update add sing-box default >/dev/null 2>&1 || warn "添加开机自启失败"
        rc-service sing-box restart || {
            err "服务启动失败"
            tail -20 /var/log/sing-box.err 2>/dev/null || tail -20 /var/log/sing-box.log 2>/dev/null || true
            exit 1
        }
        
        sleep 2
        if rc-service sing-box status >/dev/null 2>&1; then
            info "✅ OpenRC 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
        
    else
        SERVICE_PATH="/etc/systemd/system/sing-box.service"
        
        cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD
        if [ "${LOW_MEM:-false}" = "true" ]; then
            sed -i "s|^LimitNOFILE=1048576|LimitNOFILE=1048576\nEnvironment=GOMEMLIMIT=${GO_MEMLIMIT}\nEnvironment=GOGC=70|" "$SERVICE_PATH"
            info "低内存模式: 已在 $SERVICE_PATH 设置 GOMEMLIMIT=${GO_MEMLIMIT} GOGC=70"
        fi
        
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || {
            err "服务启动失败"
            journalctl -u sing-box -n 20 --no-pager 2>/dev/null || true
            exit 1
        }
        
        sleep 2
        if systemctl is-active sing-box >/dev/null 2>&1; then
            info "✅ Systemd 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
    fi
    
    info "服务配置完成: $SERVICE_PATH"
}

setup_service

# -----------------------
# 安装后自检：服务状态、各端口监听(TCP/UDP)、Reality 目标握手
show_service_logs() {
    if [ "$OS" = "alpine" ]; then
        tail -n 20 /var/log/sing-box.err 2>/dev/null || true
        tail -n 20 /var/log/sing-box.log 2>/dev/null || true
    else
        journalctl -u sing-box -n 20 --no-pager 2>/dev/null || true
    fi
}

check_listen() {
    # $1=协议名 $2=端口 $3=tcp|udp
    local NET
    NET=$(printf '%s' "$3" | tr '[:lower:]' '[:upper:]')
    if port_in_use "$2" "$3"; then
        echo "   ✅ $1 端口 $2/${NET} 正在监听"
    else
        echo "   ❌ $1 端口 $2/${NET} 没有在监听"
        SELF_CHECK_FAIL=1
    fi
}

post_install_check() {
    SELF_CHECK_FAIL=0
    echo ""
    info "=== 安装后自检 ==="
    local active=false
    if [ "$OS" = "alpine" ]; then
        rc-service sing-box status >/dev/null 2>&1 && active=true
    else
        systemctl is-active sing-box >/dev/null 2>&1 && active=true
    fi
    if $active; then
        echo "   ✅ sing-box 服务正在运行"
    else
        echo "   ❌ sing-box 服务没有运行，最近 20 行日志："
        show_service_logs
        SELF_CHECK_FAIL=1
    fi
    if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
        warn "未找到 ss/netstat，跳过端口监听检查（Debian 可 apt-get install -y iproute2）"
    else
        # sing-box 启动时若 NTP(UDP 123)不通会多等约 10 秒才开始监听，这里最多等 20 秒
        local waited=0 first_port=""
        $ENABLE_SS && first_port="${PORT_SS} tcp"
        [ -z "$first_port" ] && $ENABLE_REALITY && first_port="${PORT_REALITY} tcp"
        [ -z "$first_port" ] && $ENABLE_ANYTLS && first_port="${PORT_ANYTLS} tcp"
        [ -z "$first_port" ] && $ENABLE_HY2 && first_port="${PORT_HY2} udp"
        [ -z "$first_port" ] && $ENABLE_TUIC && first_port="${PORT_TUIC} udp"
        if [ -n "$first_port" ] && $active; then
            while ! port_in_use "${first_port% *}" "${first_port#* }" && [ "$waited" -lt 20 ]; do
                [ "$waited" -eq 0 ] && echo "   等待 sing-box 开始监听端口(最多 20 秒)..."
                sleep 2; waited=$((waited + 2))
            done
        fi
        $ENABLE_SS && { check_listen "SS" "$PORT_SS" tcp; check_listen "SS" "$PORT_SS" udp; }
        $ENABLE_HY2 && check_listen "HY2" "$PORT_HY2" udp
        $ENABLE_TUIC && check_listen "TUIC" "$PORT_TUIC" udp
        $ENABLE_REALITY && check_listen "VLESS Reality" "$PORT_REALITY" tcp
        $ENABLE_ANYTLS && check_listen "AnyTLS" "$PORT_ANYTLS" tcp
        echo "   本机 sing-box 监听列表:"
        if command -v ss >/dev/null 2>&1; then
            ss -lntup 2>/dev/null | grep -E 'sing-box|^Netid' | sed 's/^/     /' || true
        else
            netstat -lntup 2>/dev/null | grep -E 'sing-box|^Proto' | sed 's/^/     /' || true
        fi
    fi
    if $ENABLE_REALITY || $ENABLE_ANYTLS; then
        reality_target_check "$REALITY_SNI" || true
    fi
    if [ "$SELF_CHECK_FAIL" -ne 0 ]; then
        warn "自检发现问题（见上面 ❌），可以运行 sb 查看状态，或把上面的日志反馈给作者"
    fi
    tcping_hint
    return 0
}

# 自检提示：列出每个 TCP 节点的 入口IP:端口，用 itdog tcping 从国内测试
tcping_hint() {
    local h udp=""
    h="${CUSTOM_IP:-${DETECTED_IP:-你的入口IP}}"
    h="${h#[}"; h="${h%]}"
    [[ "$h" == *:* ]] && h="[$h]"
    echo ""
    info "💡 从国内测试端口通不通：打开 https://www.itdog.cn/tcping/ ，把下面每一行(入口IP:端口)粘进去测试"
    $ENABLE_SS && echo "     ${h}:${PORT_SS}    (SS)"
    $ENABLE_REALITY && echo "     ${h}:${PORT_REALITY}    (VLESS Reality)"
    $ENABLE_ANYTLS && echo "     ${h}:${PORT_ANYTLS}    (AnyTLS Reality)"
    $ENABLE_SS && udp="$udp ${PORT_SS}(SS)"
    $ENABLE_HY2 && udp="$udp ${PORT_HY2}(HY2)"
    $ENABLE_TUIC && udp="$udp ${PORT_TUIC}(TUIC)"
    [ -n "$udp" ] && echo "   UDP 端口无法用 tcping 测试，请直接用客户端连接测试:${udp}"
    if $NAT_ON; then
        echo "   NAT 小鸡：在本机内部测不出商家的端口映射是否生效，必须从外网(itdog)测【入口IP:映射端口】"
    fi
    echo "   服务器自己判断不了是否被墙（被墙发生在国内那一端），只能从国内测试；以后可在 sb「IP 被墙了？」里再看"
    return 0
}

post_install_check

# -----------------------
# 节点连接地址：用户填写的 CUSTOM_IP 优先，否则用前面检测到的公网 IP（IPv6 在链接里自动加方括号）
if [ -n "${CUSTOM_IP:-}" ]; then
    PUB_IP="$CUSTOM_IP"
    info "使用用户提供的连接IP或ddns域名 : $PUB_IP"
elif [ -n "${DETECTED_IP:-}" ]; then
    PUB_IP="$DETECTED_IP"
    info "检测到公网 IP: $PUB_IP"
else
    PUB_IP="YOUR_SERVER_IP"
    warn "无法获取公网 IP,请手动替换"
fi

# -----------------------
# HY2 自签证书 SHA-256 指纹(64 位小写十六进制, 无冒号)
# v2rayNG/Xray 26.2.6+ 已移除 allowInsecure(insecure=1), 必须用证书指纹 pinSHA256 才能连接自签证书节点
cert_sha256_hex() {
    local cert="${1:-/etc/sing-box/certs/fullchain.pem}" fp
    [ -f "$cert" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    fp=$(openssl x509 -noout -fingerprint -sha256 -in "$cert" 2>/dev/null | sed 's/^[^=]*=//' | tr -d ':[:space:]' | tr 'A-F' 'a-f')
    [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$fp"
}

# -----------------------
# 生成链接(仅生成已选择的协议)
generate_uris() {
    local host
    host=$(uri_host "$PUB_IP")
    
    if $ENABLE_SS; then
        local ss_userinfo="${SS_METHOD}:${PSK_SS}"
        ss_encoded=$(printf "%s" "$ss_userinfo" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')

        echo "=== Shadowsocks (SS) ==="
        echo "ss://${ss_encoded}@${host}:${PORT_SS}#ss${suffix}"
        echo "ss://${ss_b64}@${host}:${PORT_SS}#ss${suffix}"
        echo ""
    fi
    
    if $ENABLE_HY2; then
        hy2_encoded=$(printf "%s" "$PSK_HY2" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        local hy2_pin
        hy2_pin=$(cert_sha256_hex /etc/sing-box/certs/fullchain.pem || true)
        if [ -n "$hy2_pin" ]; then
            echo "=== Hysteria2 (HY2) 通用链接: v2rayNG/Xray + Shadowrocket(带证书指纹) ==="
            echo "hy2://${hy2_encoded}@${host}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1&pinSHA256=${hy2_pin}#hy2${suffix}"
            echo "=== Hysteria2 (HY2) Shadowrocket 备用(旧格式, 无指纹, v2rayNG 不可用) ==="
            echo "hy2://${hy2_encoded}@${host}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}-SR-legacy"
        else
            echo "=== Hysteria2 (HY2) ==="
            echo "[WARN] 无法读取证书指纹(/etc/sing-box/certs/fullchain.pem 或 openssl 缺失), 以下链接 v2rayNG 不可用"
            echo "hy2://${hy2_encoded}@${host}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}"
        fi
        echo ""
    fi

    if $ENABLE_TUIC; then
        tuic_encoded=$(printf "%s" "$PSK_TUIC" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== TUIC ==="
        echo "tuic://${UUID_TUIC}:${tuic_encoded}@${host}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${suffix}"
        echo ""
    fi
    
    if $ENABLE_REALITY; then
        echo "=== VLESS Reality ==="
        echo "vless://${UUID}@${host}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
        echo ""
    fi

    if $ENABLE_ANYTLS; then
        anytls_user_encoded=$(printf "%s" "$ANYTLS_USER" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        anytls_pass_encoded=$(printf "%s" "$ANYTLS_PSK" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== AnyTLS Reality ==="
        echo "anytls://${anytls_pass_encoded}@${host}:${PORT_ANYTLS}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${suffix}"
        echo ""
    fi
}

# -----------------------
# 最终输出
echo ""
echo "=========================================="
info "🎉 Sing-box 部署完成!"
echo "=========================================="
echo ""
info "📋 配置信息:"
$ENABLE_SS && echo "   SS 端口: $PORT_SS | 密码: $PSK_SS | 加密: $SS_METHOD"
$ENABLE_HY2 && echo "   HY2 端口: $PORT_HY2 | 密码: $PSK_HY2"
$ENABLE_TUIC && echo "   TUIC 端口: $PORT_TUIC | UUID: $UUID_TUIC | 密码: $PSK_TUIC"
$ENABLE_REALITY && echo "   Reality 端口: $PORT_REALITY | UUID: $UUID"
$ENABLE_ANYTLS && echo "   AnyTLS 端口: $PORT_ANYTLS | 用户: $ANYTLS_USER | 密码: $ANYTLS_PSK"
echo "   服务器: $PUB_IP"
echo "   Reality server_name(SNI): ${REALITY_SNI:-addons.mozilla.org}"
if $NAT_ON; then
    echo ""
    info "🔌 NAT 模式 映射端口 → 协议:"
    nat_collect_used "$CONFIG_PATH" "$RELAY_CONFIG_FILE"
    nat_table
    echo "   入口IP(链接里用): $ENTRY_IP | 出口IP: ${DETECTED_IP:-未检测}${DETECTED_ORG:+ ($DETECTED_ORG)}"
fi
echo ""
info "📂 文件位置:"
echo "   配置: $CONFIG_PATH"
($ENABLE_HY2 || $ENABLE_TUIC) && echo "   证书: /etc/sing-box/certs/"
echo "   服务: $SERVICE_PATH"
echo ""
info "📜 客户端链接:"
generate_uris | while IFS= read -r line; do
    echo "   $line"
done
echo ""
warn "⚠️ 链接不要分享给别人，避免连接数异常被商家封机"
echo ""
info "🔧 管理命令:"
if [ "$OS" = "alpine" ]; then
    echo "   启动: rc-service sing-box start"
    echo "   停止: rc-service sing-box stop"
    echo "   重启: rc-service sing-box restart"
    echo "   状态: rc-service sing-box status"
    echo "   日志: tail -f /var/log/sing-box.log"
    echo "   日志清理: 每小时自动(/usr/local/bin/sb-logrotate，单个日志超过 50MB 只保留最后 1MB)"
else
    echo "   启动: systemctl start sing-box"
    echo "   停止: systemctl stop sing-box"
    echo "   重启: systemctl restart sing-box"
    echo "   状态: systemctl status sing-box"
    echo "   日志: journalctl -u sing-box -f"
    echo "   日志清理: journald 最多 50MB；/var/log/sing-box*.log 每小时自动清理(超过 50MB 只保留最后 1MB)"
fi
echo "   日志级别默认 warn；输入 sb 可「清理日志」或临时切换到 info 排查问题"
echo ""
echo "=========================================="

# -----------------------
# 创建 sb 管理脚本
SB_PATH="/usr/local/bin/sb"
info "正在创建 sb 管理面板: $SB_PATH"

cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"
SERVICE_NAME="sing-box"
# 本机的线路机(中转/直连)节点：独立目录 + 独立服务 sing-box-relay，与上面的落地机节点互不覆盖
RELAY_HOME="/etc/sing-box-relay"
RELAY_SELF="$RELAY_HOME/relay-install.sh"
# NAT 模式设置（落地机/线路机共用）：NAT_MODE NAT_PORTS NAT_UDP_PORTS NAT_SSH_PORT ENTRY_IP
NAT_CONF="/etc/sb-nat.conf"

# 读取 NAT 设置（只读取这几个变量，不影响其他变量）
sb_nat_load() {
    NAT_MODE=0; NAT_PORTS=""; NAT_UDP_PORTS=""; NAT_SSH_PORT=""; ENTRY_IP=""
    if [ -f "$NAT_CONF" ]; then
        # shellcheck disable=SC1090
        . "$NAT_CONF" 2>/dev/null || true
    fi
    return 0
}
sb_nat_on() { [ "${NAT_MODE:-0}" = "1" ] && [ -n "${NAT_PORTS:-}" ]; }
sb_in_words() { [[ " $2 " == *" $1 "* ]]; }

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID="${ID:-}"
        ID_LIKE="${ID_LIKE:-}"
    else
        ID=""
        ID_LIKE=""
    fi

    if echo "$ID $ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$ID $ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$ID $ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os

# 服务控制
service_start() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" start || systemctl start "$SERVICE_NAME"
}
service_stop() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" stop || systemctl stop "$SERVICE_NAME"
}
service_restart() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" restart || systemctl restart "$SERVICE_NAME"
}
service_status() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" status || systemctl status "$SERVICE_NAME" --no-pager
}

# 生成随机值
rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)); }
rand_pass() { openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'; }
rand_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'; }

# URL 编码
url_encode() {
    printf "%s" "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'
}

# 确保有 openssl（计算证书指纹用；缺失时按系统自动安装，失败不退出）
ensure_openssl() {
    command -v openssl >/dev/null 2>&1 && return 0
    warn "未找到 openssl，尝试自动安装..." >&2
    case "$OS" in
        alpine) apk add --no-cache openssl >/dev/null 2>&1 || true ;;
        debian) { DEBIAN_FRONTEND=noninteractive apt-get install -y openssl >/dev/null 2>&1 \
                  || { apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y openssl >/dev/null 2>&1; }; } || true ;;
        redhat) yum install -y openssl >/dev/null 2>&1 || true ;;
    esac
    command -v openssl >/dev/null 2>&1
}

# 证书 SHA-256 指纹(64 位小写十六进制, 无冒号)；失败返回 1
# v2rayNG/Xray 26.2.6+ 已移除 allowInsecure(insecure=1)，自签证书节点必须带 pinSHA256 指纹
cert_sha256_hex() {
    local cert="$1" fp
    [ -n "$cert" ] && [ -f "$cert" ] || return 1
    ensure_openssl || return 1
    fp=$(openssl x509 -noout -fingerprint -sha256 -in "$cert" 2>/dev/null | sed 's/^[^=]*=//' | tr -d ':[:space:]' | tr 'A-F' 'a-f')
    [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$fp"
}

# 从现有 config.json 读取 HY2 入站使用的证书路径（读不到时用默认路径）
hy2_cert_path() {
    local p=""
    [ -f "$CONFIG_PATH" ] && p=$(jq -r 'first((.inbounds // [])[] | select(.type=="hysteria2") | .tls.certificate_path // empty) // empty' "$CONFIG_PATH" 2>/dev/null || true)
    printf '%s' "${p:-/etc/sing-box/certs/fullchain.pem}"
}

# 读取配置
read_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        return 1
    fi
    
    # 优先加载 .protocols 文件（确认协议标记）
    PROTOCOL_FILE="/etc/sing-box/.protocols"
    if [ -f "$PROTOCOL_FILE" ]; then
        . "$PROTOCOL_FILE"
    fi
    
    # 加载缓存文件（包含端口密码等详细配置）
    if [ -f "$CACHE_FILE" ]; then
        . "$CACHE_FILE"
    fi
    
    # 确保有默认值
    REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
    ENABLE_ANYTLS="${ENABLE_ANYTLS:-false}"
    CUSTOM_IP="${CUSTOM_IP:-}"

    # 读取各协议配置
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        SS_PORT=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        SS_PSK=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .password // empty' "$CONFIG_PATH" | head -n1)
        SS_METHOD=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .method // empty' "$CONFIG_PATH" | head -n1)
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        HY2_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        HY2_PSK=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        TUIC_PORT=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        TUIC_UUID=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)
        TUIC_PSK=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
    fi
    
# Reality 公共参数（Reality / AnyTLS 共用）
if [ "${ENABLE_REALITY:-false}" = "true" ] || [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    REALITY_SID=$(jq -r '
        .inbounds[]
        | select(.tls.reality.enabled == true)
        | .tls.reality.short_id[0] // empty
    ' "$CONFIG_PATH" | head -n1)

    [ -f /etc/sing-box/.reality_pub ] && REALITY_PUB=$(cat /etc/sing-box/.reality_pub)
fi

# VLESS Reality 专属参数
if [ "${ENABLE_REALITY:-false}" = "true" ]; then
    REALITY_PORT=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port // empty' "$CONFIG_PATH" | head -n1)

    REALITY_UUID=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)

    REALITY_PK=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.private_key // empty' "$CONFIG_PATH" | head -n1)
fi

if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    ANYTLS_PORT=$(jq -r '.inbounds[] | select(.type=="anytls") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
    ANYTLS_USER=$(jq -r '.inbounds[] | select(.type=="anytls") | .users[0].name // empty' "$CONFIG_PATH" | head -n1)
    ANYTLS_PSK=$(jq -r '.inbounds[] | select(.type=="anytls") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
fi
}

# ---- 公网 IP / NAT / WARP 检测（安装脚本与 sb 面板共用同一套逻辑）----
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "$1" =~ ^[0-9A-Fa-f:.]+$ ]] && [[ "$1" == *:*:* ]]; }

# 内网/运营商级 NAT 地址: 10/8 172.16/12 192.168/16 100.64/10
is_private_ipv4() {
    local a b
    is_ipv4 "$1" || return 1
    a=$(printf '%s' "$1" | cut -d. -f1); b=$(printf '%s' "$1" | cut -d. -f2)
    [ "$a" -eq 10 ] && return 0
    [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
    [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
    [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0
    return 1
}

# 查询公网出口 IP：$1=4 或 6；依次尝试多个接口（每个 5 秒超时），只接受合法 IP
fetch_public_ip() {
    local fam="$1" url ip urls
    if [ "$fam" = "6" ]; then
        urls="https://api64.ipify.org https://ipv6.icanhazip.com https://ifconfig.co/ip"
    else
        urls="https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://ipinfo.io/ip"
    fi
    for url in $urls; do
        ip=$(curl -"$fam" -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ "$fam" = "6" ]; then is_ipv6 "$ip" && { printf '%s' "$ip"; return 0; }
        else is_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }; fi
    done
    return 1
}

# 默认路由网卡上的本机 IPv4 地址（ip route show default → ip addr；失败再用 ip route get）
local_route_ip4() {
    local dev addr=""
    command -v ip >/dev/null 2>&1 || return 0
    dev=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
    if [ -n "$dev" ]; then
        addr=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}' || true)
    fi
    if [ -z "$addr" ]; then
        addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
    fi
    printf '%s' "$addr"
}

# 检测连接 IP。结果:
#   DETECTED_IP / DETECTED_FAMILY(4|6) / DETECTED_ORG(运营商/ASN，可能为空)
#   NAT_REASON：非空表示看起来是 NAT 或 WARP，检测到的 IP 不能直接用作节点连接地址
detect_public_ip() {
    DETECTED_IP=""; DETECTED_FAMILY=""; DETECTED_ORG=""; NAT_REASON=""
    local ip4="" ip6="" trace local4
    ip4=$(fetch_public_ip 4 || true)
    if [ -n "$ip4" ]; then
        DETECTED_IP="$ip4"; DETECTED_FAMILY=4
    else
        ip6=$(fetch_public_ip 6 || true)
        [ -n "$ip6" ] || return 1
        DETECTED_IP="$ip6"; DETECTED_FAMILY=6
    fi
    trace=$(curl -"$DETECTED_FAMILY" -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    DETECTED_ORG=$(curl -s --max-time 5 "https://ipinfo.io/${DETECTED_IP}/org" 2>/dev/null | head -n1 | tr -d '\r' || true)
    case "$DETECTED_ORG" in *"{"*|*"<"*) DETECTED_ORG="" ;; esac
    if printf '%s\n' "$trace" | grep -qE '^warp=(on|plus)$'; then
        NAT_REASON="出口走的是 Cloudflare WARP（cdn-cgi/trace 显示 $(printf '%s\n' "$trace" | grep -E '^warp=' | head -n1)），检测到的 ${DETECTED_IP} 是 Cloudflare 的 IP，客户端连不上"
    elif printf '%s' "$DETECTED_ORG" | grep -qiE 'cloudflare|AS13335'; then
        NAT_REASON="检测到的出口 IP ${DETECTED_IP} 属于 Cloudflare（${DETECTED_ORG}），通常是开了 WARP，客户端连不上"
    elif [ "$DETECTED_FAMILY" = "4" ]; then
        local4=$(local_route_ip4)
        if [ -n "$local4" ] && is_private_ipv4 "$local4" && [ "$local4" != "$ip4" ]; then
            NAT_REASON="本机网卡地址是内网 IP（${local4}），和检测到的公网出口 IP（${ip4}）不一样，说明本机在 NAT 后面（NAT 小鸡/转发机，或云厂商的 1:1 NAT）"
        fi
    fi
    return 0
}

# 打印 NAT/WARP 说明
explain_nat() {
    warn "=================== ⚠️ 注意：不能自动使用检测到的 IP ==================="
    warn "$NAT_REASON"
    echo "   节点链接里必须填【入口地址】：也就是你平时 SSH 登录这台机器用的 IP，"
    echo "   或商家面板里给的 NAT 入口 IP / 域名（例如 'nat.xxx.com' 或 '45.x.x.x'）。"
    echo "   如果你确认 ${DETECTED_IP:-检测到的IP} 就是 SSH 登录用的 IP（例如 Oracle/AWS/GCP 这类云厂商，网卡是内网 IP 属正常），"
    echo "   直接把它输入进去即可。"
    warn "========================================================================"
}

# 生成链接用的主机：去掉空白/方括号，IPv6 加方括号
uri_host() {
    local h
    h=$(printf '%s' "$1" | tr -d '[:space:]')
    h="${h#[}"; h="${h%]}"
    if [[ "$h" == *:* ]]; then printf '[%s]' "$h"; else printf '%s' "$h"; fi
}

# 兼容旧调用：只输出检测到的 IP（IPv4 优先，其次 IPv6），失败输出 YOUR_SERVER_IP
get_public_ip() {
    if detect_public_ip && [ -n "$DETECTED_IP" ]; then
        echo "$DETECTED_IP"
    else
        echo "YOUR_SERVER_IP"
    fi
}

# 决定节点链接用的地址，结果放在 PUBLIC_IP（已处理 IPv6 方括号）
# 已保存的 CUSTOM_IP 优先（老安装不受影响）；否则自动检测，发现 NAT/WARP 时要求输入入口地址并保存
resolve_link_ip() {
    local input
    if [ -n "${CUSTOM_IP:-}" ]; then
        PUBLIC_IP=$(uri_host "$CUSTOM_IP")
        return 0
    fi
    # NAT 模式记录的入口IP（sb「入口/出口 IP」里设置）
    sb_nat_load
    if [ -n "${ENTRY_IP:-}" ]; then
        PUBLIC_IP=$(uri_host "$ENTRY_IP")
        return 0
    fi
    if detect_public_ip && [ -z "$NAT_REASON" ]; then
        PUBLIC_IP=$(uri_host "$DETECTED_IP")
        return 0
    fi
    if [ -n "$NAT_REASON" ]; then
        explain_nat
    else
        warn "无法自动检测到公网 IP（网络不通或检测接口被墙）"
    fi
    if [ ! -t 0 ]; then
        warn "当前不是交互终端，暂时使用 ${DETECTED_IP:-YOUR_SERVER_IP}；请运行 sb 后在提示处填写入口地址"
        PUBLIC_IP=$(uri_host "${DETECTED_IP:-YOUR_SERVER_IP}")
        return 0
    fi
    while true; do
        read -r -p "请输入节点连接 IP 或域名(商家面板里的入口地址): " input || input=""
        input=$(normalize_host "$input")
        if validate_host "$input"; then break; fi
        err "地址无效: '${input}'（需为 IPv4、IPv6 或域名）"
    done
    PUBLIC_IP=$(uri_host "$input")
    cache_set CUSTOM_IP "$PUBLIC_IP"
    CUSTOM_IP="$PUBLIC_IP"
    info "已将入口地址 $PUBLIC_IP 保存为 CUSTOM_IP（以后生成链接都会用它）"
}

# 写入 KEY=VALUE 到指定文件：已存在的 KEY 会被替换而不是重复追加
# fix: 原脚本用 echo >> 追加，导致缓存里出现多个 SS_PSK= 等旧值
kv_set() {
    local file="$1" key="$2" val="$3" tmp
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp=$(mktemp)
    grep -v "^${key}=" "$file" > "$tmp" || true
    printf '%s=%q\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}
cache_set() { kv_set "$CACHE_FILE" "$1" "$2"; }

# 规范化主机：去空白、去掉 IPv6 方括号
normalize_host() {
    local h
    h=$(printf '%s' "$1" | tr -d '[:space:]')
    h="${h#[}"
    h="${h%]}"
    printf '%s' "$h"
}

# 校验落地机地址：IPv4 / IPv6 / 含字母和点的域名；拒绝纯数字(端口)等
validate_host() {
    local h="$1" o
    [ -z "$h" ] && return 1
    # IPv4
    if [[ "$h" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for o in "${BASH_REMATCH[@]:1}"; do
            [ "$((10#$o))" -le 255 ] || return 1
        done
        return 0
    fi
    # IPv6（至少两个冒号，仅含十六进制/冒号/点）
    if [[ "$h" =~ ^[0-9A-Fa-f:.]+$ ]] && [[ "$h" == *:*:* ]]; then
        return 0
    fi
    # 域名：必须包含字母和点
    if [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
        && [[ "$h" =~ [A-Za-z] ]]; then
        return 0
    fi
    return 1
}

# 从 config.json 直接读取 SS 入站（优先 tag=ss-in，其次第一个 shadowsocks）
SS_INBOUND_SELECTOR='first((.inbounds // [])[] | select(.type=="shadowsocks" and .tag=="ss-in")) // first((.inbounds // [])[] | select(.type=="shadowsocks")) // empty'
ss_from_config() {
    # 用法: ss_from_config <字段>   字段: listen_port | method | password
    [ -f "$CONFIG_PATH" ] || return 0
    jq -r "($SS_INBOUND_SELECTOR) | .$1 // empty" "$CONFIG_PATH" 2>/dev/null | head -n1 || true
}

# 端口校验 1-65535
validate_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]
}

# 转义为可放进 shell 单引号 '...' 的内容，再转义 sed 替换串中的特殊字符 \ | &
sed_sq_escape() {
    printf '%s' "$1" | sed -e "s/'/'\\\\''/g" -e 's/[\\|&]/\\&/g'
}

# 遮蔽密码，仅显示前 4 位
mask_secret() {
    local s="$1"
    if [ "${#s}" -le 4 ]; then
        printf '%s' "****"
    else
        printf '%s****' "${s:0:4}"
    fi
}

# 生成并保存URI
generate_uris() {
    read_config || return 1

    # 优先使用用户自定义入口 IP；否则自动检测（NAT/WARP 时要求输入入口地址）
    resolve_link_ip

    node_suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")
    
    URI_FILE="/etc/sing-box/uris.txt"
    > "$URI_FILE"
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        ss_userinfo="${SS_METHOD}:${SS_PSK}"
        ss_encoded=$(url_encode "$ss_userinfo")
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')
        
        echo "=== Shadowsocks (SS) ===" >> "$URI_FILE"
        echo "ss://${ss_encoded}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "ss://${ss_b64}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        hy2_encoded=$(url_encode "$HY2_PSK")
        local hy2_cert hy2_pin
        hy2_cert=$(hy2_cert_path)
        hy2_pin=$(cert_sha256_hex "$hy2_cert" || true)
        if [ -z "$hy2_pin" ]; then
            warn "无法读取 HY2 证书指纹($hy2_cert)，生成的 HY2 链接 v2rayNG 不可用"
        fi
        {
            if [ -n "$hy2_pin" ]; then
                echo "=== Hysteria2 (HY2) 通用链接: v2rayNG/Xray + Shadowrocket(带证书指纹) ==="
                echo "hy2://${hy2_encoded}@${PUBLIC_IP}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1&pinSHA256=${hy2_pin}#hy2${node_suffix}"
                echo "=== Hysteria2 (HY2) Shadowrocket 备用(旧格式, 无指纹, v2rayNG 不可用) ==="
                echo "hy2://${hy2_encoded}@${PUBLIC_IP}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${node_suffix}-SR-legacy"
            else
                echo "=== Hysteria2 (HY2) ==="
                echo "[WARN] 无法读取证书指纹($hy2_cert)，以下链接 v2rayNG 不可用"
                echo "hy2://${hy2_encoded}@${PUBLIC_IP}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${node_suffix}"
            fi
            echo ""
        } >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        tuic_encoded=$(url_encode "$TUIC_PSK")
        echo "=== TUIC ===" >> "$URI_FILE"
        echo "tuic://${TUIC_UUID}:${tuic_encoded}@${PUBLIC_IP}:${TUIC_PORT}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
        echo "=== VLESS Reality ===" >> "$URI_FILE"
        echo "vless://${REALITY_UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        anytls_user_encoded=$(url_encode "$ANYTLS_USER")
        anytls_pass_encoded=$(url_encode "$ANYTLS_PSK")
        echo "=== AnyTLS Reality ===" >> "$URI_FILE"
        echo "anytls://${anytls_pass_encoded}@${PUBLIC_IP}:${ANYTLS_PORT}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    info "URI 已保存到: $URI_FILE"
}

# 查看URI
action_view_uri() {
    info "正在生成并显示 URI..."
    generate_uris || { err "生成 URI 失败"; return 1; }
    echo ""
    cat /etc/sing-box/uris.txt
    sb_share_reminder
}

# 查看配置文件路径
action_view_config() {
    echo "$CONFIG_PATH"
}

# 编辑配置
action_edit_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "配置文件不存在: $CONFIG_PATH"
        return 1
    fi
    
    ${EDITOR:-nano} "$CONFIG_PATH" 2>/dev/null || ${EDITOR:-vi} "$CONFIG_PATH"
    
    if command -v sing-box >/dev/null 2>&1; then
        if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
            info "配置校验通过,已重启服务"
            service_restart || warn "重启失败"
            generate_uris || true
        else
            warn "配置校验失败,服务未重启"
        fi
    fi
}

# 端口是否已被本机线路机节点(sing-box-relay)使用
# $2(可选) = 新端口要用的网络 "tcp" / "udp" / "tcp udp"：给出时只在网络重叠时算冲突（TCP 和 UDP 可以共用同一个端口号）
relay_port_taken() {
    [ -f "$RELAY_HOME/config.json" ] || return 1
    if [ -z "${2:-}" ]; then
        jq -e --argjson p "$1" 'any((.inbounds // [])[]; .listen_port == $p)' "$RELAY_HOME/config.json" >/dev/null 2>&1
        return $?
    fi
    port_nets_overlap "$RELAY_HOME/config.json" "$1" "$2"
}

# 配置文件 $1 里端口 $2 的入站使用的网络是否和 $3 重叠（SS=TCP+UDP，HY2/TUIC=UDP，其余=TCP）
port_nets_overlap() {
    local n used
    [ -f "$1" ] || return 1
    used=$(jq -r --argjson p "$2" '(.inbounds // [])[] | select(.listen_port == $p)
        | (if .type == "shadowsocks" then "tcp udp" elif (.type == "hysteria2" or .type == "tuic") then "udp" else "tcp" end)' "$1" 2>/dev/null | tr '\n' ' ' || true)
    for n in $3; do
        [[ " $used " == *" $n "* ]] && return 0
    done
    return 1
}

# 新端口校验：数字 1-65535，且不能和本机线路机节点冲突；$2(可选) = 网络，见 relay_port_taken
check_new_port() {
    if ! validate_port "$1"; then
        err "端口无效: $1（需为 1-65535 的数字）"
        return 1
    fi
    if relay_port_taken "$1" "${2:-}"; then
        err "端口 $1 已被本机的线路机节点(sing-box-relay，$RELAY_HOME/config.json)使用，请换一个"
        return 1
    fi
    sb_nat_load
    if sb_nat_on; then
        if [ "$((10#$1))" = "${NAT_SSH_PORT:-}" ]; then
            err "端口 $1 是 SSH 用的映射端口，不能用"
            return 1
        fi
        if ! sb_in_words "$((10#$1))" "$NAT_PORTS"; then
            local ans
            warn "NAT 模式：端口 $1 不在商家映射端口($NAT_PORTS)里，外网很可能连不上"
            read -r -p "仍然使用 $1 ?(y/N): " ans || ans=""
            [[ "$ans" =~ ^[Yy]$ ]] || return 1
        fi
    fi
    return 0
}

# NAT 模式下给新端口提示：$1 = tcp|udp|ss，打印建议端口（没有返回 1）
nat_suggest_port() {
    sb_nat_load
    sb_nat_on || return 1
    run_relay_template natpick "$1" 2>/dev/null
}

# 重置SS端口
action_reset_ss() {
    read_config || return 1
    
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        err "SS 协议未启用"
        return 1
    fi
    
    read -p "输入新的 SS 端口(回车保持 $SS_PORT): " new_port
    new_port="${new_port:-$SS_PORT}"
    if [ "$new_port" != "${SS_PORT:-}" ]; then check_new_port "$new_port" || return 1; fi
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="shadowsocks" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 SS 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置HY2端口
action_reset_hy2() {
    read_config || return 1
    
    if [ "${ENABLE_HY2:-false}" != "true" ]; then
        err "HY2 协议未启用"
        return 1
    fi
    
    read -p "输入新的 HY2 端口(回车保持 $HY2_PORT): " new_port
    new_port="${new_port:-$HY2_PORT}"
    if [ "$new_port" != "${HY2_PORT:-}" ]; then check_new_port "$new_port" || return 1; fi
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="hysteria2" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 HY2 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置TUIC端口
action_reset_tuic() {
    read_config || return 1
    
    if [ "${ENABLE_TUIC:-false}" != "true" ]; then
        err "TUIC 协议未启用"
        return 1
    fi
    
    read -p "输入新的 TUIC 端口(回车保持 $TUIC_PORT): " new_port
    new_port="${new_port:-$TUIC_PORT}"
    if [ "$new_port" != "${TUIC_PORT:-}" ]; then check_new_port "$new_port" || return 1; fi
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="tuic" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 TUIC 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置Vless Reality端口
action_reset_reality() {
    read_config || return 1
    
    if [ "${ENABLE_REALITY:-false}" != "true" ]; then
        err "Vless Reality 协议未启用"
        return 1
    fi
    
    read -p "输入新的 Vless Reality 端口(回车保持 $REALITY_PORT): " new_port
    new_port="${new_port:-$REALITY_PORT}"
    if [ "$new_port" != "${REALITY_PORT:-}" ]; then check_new_port "$new_port" || return 1; fi
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="vless" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 Vless Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置AnyTLS Reality端口
action_reset_anytls() {
    read_config || return 1

    if [ "${ENABLE_ANYTLS:-false}" != "true" ]; then
        err "AnyTLS Reality 协议未启用"
        return 1
    fi

    read -p "输入新的 AnyTLS Reality 端口(回车保持 $ANYTLS_PORT): " new_port
    new_port="${new_port:-$ANYTLS_PORT}"
    if [ "$new_port" != "${ANYTLS_PORT:-}" ]; then check_new_port "$new_port" || return 1; fi

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="anytls" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 AnyTLS Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 更新sing-box
action_update() {
    info "开始更新 sing-box..."
    if [ "$OS" = "alpine" ]; then
        # 优先 Alpine 官方仓库(只在版本够新时)，否则从 GitHub 下载官方静态版本，再不行用 edge 仓库
        local need="1.11.0"
        [ "${ENABLE_ANYTLS:-false}" = "true" ] && need="1.12.0"
        if apk info -e sing-box >/dev/null 2>&1 && apk upgrade --no-cache sing-box >/dev/null 2>&1 \
            && [ "$(printf '%s\n%s\n' "$need" "$(sing-box version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$need" ]; then
            info "已从 Alpine 仓库更新"
        else
            run_relay_template sbinstall "$need" || { err "更新 sing-box 失败"; return 1; }
        fi
    else
        bash <(curl -fsSL https://sing-box.app/install.sh) || {
            err "下载 sing-box 失败"
            if [ -z "$(ip -4 route show default 2>/dev/null || true)" ]; then
                warn "本机可能是纯 IPv6，GitHub 不支持 IPv6。可临时改用 NAT64 DNS 再更新："
                echo "   cp /etc/resolv.conf /etc/resolv.conf.bak && echo 'nameserver 2a00:1098:2b::1' > /etc/resolv.conf"
                echo "   更新完成后恢复: mv /etc/resolv.conf.bak /etc/resolv.conf"
            fi
            return 1
        }
    fi
    
    info "更新完成,已重启服务..."
    if command -v sing-box >/dev/null 2>&1; then
        NEW_VER=$(sing-box version 2>/dev/null | head -n1)
        info "当前版本: $NEW_VER"
        service_restart || warn "重启失败"
    fi
}

# 卸载（只卸载落地机节点；本机的线路机节点 sing-box-relay 会询问是否一起卸载）
action_uninstall() {
    read -p "确认卸载落地机节点(sing-box 服务 + /etc/sing-box)?(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && info "已取消" && return 0

    local keep_relay=false ans
    if old_relay_layout; then
        relay_prepare || { err "迁移旧版线路机节点失败，为避免误删，已取消卸载"; return 1; }
    fi
    if relay_installed; then
        warn "本机还有线路机(中转/直连)节点: 服务 sing-box-relay，目录 $RELAY_HOME"
        read -r -p "是否同时卸载线路机节点?(y/N，默认保留): " ans || ans=n
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            if [ -f "$RELAY_SELF" ]; then
                printf 'y\n' | bash "$RELAY_SELF" uninstall || warn "卸载线路机节点失败"
            fi
        else
            keep_relay=true
        fi
    fi

    # Argo 备用入口在落地机节点上时一起卸载（在线路机节点上的不受影响）
    [ -f /etc/sb-argo/argo.env ] && { run_relay_template argo landing-uninstall || true; }
    info "正在卸载..."
    service_stop || true
    if [ "$OS" = "alpine" ]; then
        rc-update del sing-box default 2>/dev/null || true
        rm -f /etc/init.d/sing-box
        $keep_relay || apk del sing-box 2>/dev/null || true
    else
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        $keep_relay || apt purge -y sing-box >/dev/null 2>&1 || true
    fi
    rm -rf /etc/sing-box /var/log/sing-box.log /var/log/sing-box.err /usr/local/bin/sb /root/node_names.txt 2>/dev/null || true
    if $keep_relay; then
        info "已保留线路机节点和 sing-box 程序；sb 已换成线路机快捷菜单"
        bash "$RELAY_SELF" shortcut >/dev/null 2>&1 || true
    else
        rm -f /usr/bin/sing-box "$NAT_CONF" 2>/dev/null || true
        if [ -L /usr/bin/sb ] && [ ! -e /usr/bin/sb ]; then rm -f /usr/bin/sb; fi
    fi
    # 本机已没有任何 sing-box 节点时，删除日志清理脚本/定时任务/journald 设置
    run_relay_template logremove || true
    info "卸载完成"
}

# 本机线路机节点是否已安装（新布局或旧布局）
relay_installed() { [ -f "$RELAY_HOME/relay.env" ] || [ -f /etc/sing-box/relay.env ]; }
old_relay_layout() { [ -f /etc/sing-box/relay.env ] && [ ! -f "$RELAY_HOME/relay.env" ]; }

# 用本面板自带的线路机脚本模板运行一个命令（模板没有落地机参数）
run_relay_template() {
    local tmp rc=0
    tmp=$(mktemp /tmp/relay-install.XXXXXX)
    write_relay_template "$tmp"
    chmod 700 "$tmp"
    bash "$tmp" "$@" || rc=$?
    rm -f "$tmp"
    return "$rc"
}

# 旧版线路机布局(节点在 /etc/sing-box)先迁移到 sing-box-relay；本机线路机脚本副本太旧时换成新版
relay_prepare() {
    if old_relay_layout; then
        info "检测到旧版线路机节点(在 /etc/sing-box，和落地机共用 sing-box 服务)，先迁移到独立服务 sing-box-relay（端口/UUID/链接不变）"
        run_relay_template upgrade || return 1
    fi
    if [ -f "$RELAY_HOME/relay.env" ] && { [ ! -f "$RELAY_SELF" ] || ! grep -q 'SVC_NAME="sing-box-relay"' "$RELAY_SELF" 2>/dev/null \
        || ! grep -q 'sb-logrotate' "$RELAY_SELF" 2>/dev/null || ! grep -q 'NAT_CONF=' "$RELAY_SELF" 2>/dev/null || ! grep -q 'ARGO_DIR=' "$RELAY_SELF" 2>/dev/null || ! grep -q 'sb_restore()' "$RELAY_SELF" 2>/dev/null; }; then
        mkdir -p "$RELAY_HOME"
        write_relay_template "$RELAY_SELF"
        chmod 700 "$RELAY_SELF"
    fi
    return 0
}

# 线路机/直连节点管理（本机）
action_relay_local() {
    relay_prepare || return 1
    if [ -f "$RELAY_HOME/relay.env" ]; then
        bash "$RELAY_SELF" menu || true
        return 0
    fi
    local c
    echo ""
    echo "========== 本机线路机/直连节点 =========="
    echo "本机还没有线路机节点。它们使用独立服务 sing-box-relay（目录 $RELAY_HOME），不会改动本机的落地机节点。"
    echo "1) 在本机添加一个直连节点(VLESS Reality，出口为本机)"
    echo "2) 让本机作为线路机，中转另一台落地机（查看做法）"
    echo "0) 返回"
    echo "========================================"
    read -r -p "请选择: " c || c=0
    case "$c" in
        1) run_relay_template direct || true ;;
        2)
            echo ""
            echo "做法：在【另一台落地机】上输入 sb → 选「生成线路机脚本」，按提示把生成的整行命令复制到【本机】执行，"
            echo "      选「追加」即可。本机的落地机节点和线路机节点各用各的服务，互不覆盖。"
            ;;
        *) ;;
    esac
}

# ===== 日志（具体实现都在线路机脚本模板里：logauto / logclean / loglevel / logremove）=====
SB_LOG_HELPER="/usr/local/bin/sb-logrotate"
SB_LOG_PREF="/etc/sb-log.conf"

# 本机 sing-box 配置当前的日志级别（落地机 / 线路机，没有的跳过），如 "warn" 或 "warn/info"
current_log_levels() {
    local f out=""
    for f in "$CONFIG_PATH" "$RELAY_HOME/config.json"; do
        [ -f "$f" ] || continue
        out="${out:+$out/}$(jq -r '.log.level // "info"' "$f" 2>/dev/null || echo '?')"
    done
    echo "${out:-无}"
}

# 是否需要（再）设置日志：清理脚本缺失/旧版、旧的 sb-logclean.sh 还在、未手动选过级别且仍是 info
log_setup_needed() {
    local f
    grep -qs 'SB_LOGROTATE_VERSION=2' "$SB_LOG_HELPER" || return 0
    [ -e /usr/local/bin/sb-logclean.sh ] && return 0
    if [ -d /run/systemd/system ] && [ ! -f /etc/systemd/journald.conf.d/sing-box.conf ]; then return 0; fi
    if [ ! -f "$SB_LOG_PREF" ] && command -v jq >/dev/null 2>&1; then
        for f in "$CONFIG_PATH" "$RELAY_HOME/config.json"; do
            [ -f "$f" ] || continue
            # 线路机脚本只处理本脚本装的落地机配置(有 .config_cache)，与它保持一致，避免每次都调用
            [ "$f" = "$CONFIG_PATH" ] && [ ! -f "$CACHE_FILE" ] && [ ! -f /etc/sing-box/relay.env ] && continue
            [ "$(jq -r '.log.level // "info"' "$f" 2>/dev/null)" = "info" ] && return 0
        done
    fi
    return 1
}

action_log_clean() { run_relay_template logclean || true; }
action_log_level() { run_relay_template loglevel || true; }

# 线路机脚本模板（落地机参数占位符未替换）：$1=写入路径
# 线路机节点使用独立目录 /etc/sing-box-relay 和独立服务 sing-box-relay，和落地机节点互不覆盖
write_relay_template() {
    cat > "$1" <<'RELAY_EOF'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[ "$(id -u)" != "0" ] && err "必须以 root 运行" && exit 1

# ===== 落地机参数（由落地机 sb 生成时填入）=====
LANDING_SERVER='__INBOUND_IP__'
LANDING_PORT='__INBOUND_PORT__'
LANDING_METHOD='__INBOUND_METHOD__'
LANDING_PASSWORD='__INBOUND_PASSWORD__'
RELAY_SNI='__REALITY_SNI__'

# 线路机(中转/直连)节点使用独立的目录和服务，和本机的落地机节点(/etc/sing-box + sing-box 服务)互不覆盖
SB_DIR="/etc/sing-box-relay"
CONFIG="$SB_DIR/config.json"
RELAY_ENV="$SB_DIR/relay.env"            # 公共参数：线路机IP、Reality 公钥/short_id/SNI、直连节点
RELAY_DIR="$SB_DIR/relays"               # 每台落地机一条记录: relays/<编号>.env
RELAY_URI_FILE="$SB_DIR/relay_uri.txt"   # 所有节点链接（每次整体重写）
SELF_COPY="$SB_DIR/relay-install.sh"
SVC_NAME="sing-box-relay"
SYSTEMD_UNIT="/etc/systemd/system/${SVC_NAME}.service"
OPENRC_INIT="/etc/init.d/${SVC_NAME}"

# 本机落地机节点（落地机一键脚本安装的）；旧版线路机也把配置放在这里
LANDING_DIR="/etc/sing-box"
LANDING_CONFIG="$LANDING_DIR/config.json"
OLD_ENV="$LANDING_DIR/relay.env"
OLD_RELAY_DIR="$LANDING_DIR/relays"
SHIM="$LANDING_DIR/relay-install.sh"     # 兼容旧命令 bash /etc/sing-box/relay-install.sh
SB_CMD="/usr/local/bin/sb"
MAIN_URL="https://raw.githubusercontent.com/demonmanch/singbox-deploy/main/install-singbox-yyds.sh"

# 只看文件开头的标记行（完整 sb 面板里也包含这些字样，不能用全文搜索判断）
is_shortcut() { [ -f "$1" ] && head -n 3 "$1" 2>/dev/null | grep -q '^# SB_RELAY_SHORTCUT'; }
is_shim() { [ -f "$1" ] && head -n 3 "$1" 2>/dev/null | grep -q '^# SB_RELAY_SHIM'; }

# 直连节点默认关闭（旧版 relay.env 里没有这些字段）
DIRECT_ENABLED=false
DIRECT_PORT=""
DIRECT_UUID=""
DIRECT_NAME=""
PUB_IP=""
REALITY_PUB=""
REALITY_SID=""
RECORDS=()

# 节点名称 URL 编码（支持中文/空格）
uri_encode() { jq -rn --arg v "$1" '$v|@uri'; }

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# 本脚本里的落地机参数是否有效（模板未填写时无效）
landing_valid() {
    [ -n "$LANDING_SERVER" ] && [[ "$LANDING_SERVER" != __*__ ]] && valid_port "$LANDING_PORT" \
        && [ -n "$LANDING_PASSWORD" ] && [[ "$LANDING_PASSWORD" != __*__ ]]
}

# 端口是否已被系统占用（检测不到工具时视为未占用）
port_in_use() {
    local addrs="" fl="-lntu"
    # NAT 模式映射端口少：线路机节点只用 TCP，只看 TCP 占用（UDP 可以留给 HY2/TUIC 共用同一端口号）
    nat_on && fl="-lnt"
    if command -v ss >/dev/null 2>&1; then
        addrs=$(ss "$fl" 2>/dev/null | awk 'NR>1{print $5}' || true)
    elif command -v netstat >/dev/null 2>&1; then
        addrs=$(netstat "$fl" 2>/dev/null | awk '{print $4}' || true)
    fi
    printf '%s\n' "$addrs" | grep -qE "[:.]$1\$"
}

# 端口是否写在某个 sing-box 配置里：$1=配置文件 $2=端口
cfg_has_port() {
    [ -f "$1" ] && command -v jq >/dev/null 2>&1 \
        && jq -e --argjson p "$2" 'any((.inbounds // [])[]; .listen_port == $p)' "$1" >/dev/null 2>&1
}

# 端口是否已写在本机线路机配置里
own_port() { cfg_has_port "$CONFIG" "$1"; }

# 端口是否已被本机【落地机节点】(/etc/sing-box/config.json) 使用：任何情况下都不能用
landing_port() { cfg_has_port "$LANDING_CONFIG" "$1"; }

# 随机挑一个空闲端口：$1=需避开的端口(空格分隔) $2=strict(配置里已有的端口也避开)
rand_free_port() {
    local avoid=" ${1:-} " strict="${2:-}" p i
    nat_load
    if nat_on; then
        # NAT 模式：只从商家映射端口里选（不用 SSH 端口、不和落地机/线路机已有节点冲突）
        if [ -n "$strict" ]; then nat_collect_used "$LANDING_CONFIG" "$CONFIG"; else nat_collect_used "$LANDING_CONFIG"; fi
        for p in $avoid; do nat_mark "$p" tcp; nat_mark "$p" udp; done
        for i in $NAT_PORTS; do
            p=$(nat_pick tcp) || return 1
            if port_in_use "$p" && ! own_port "$p"; then nat_mark "$p" tcp; continue; fi
            echo "$p"
            return 0
        done
        return 1
    fi
    for i in $(seq 1 100); do
        p=$(shuf -i 20000-65000 -n 1 2>/dev/null || echo $(( (RANDOM % 45000) + 20000 )))
        [[ "$avoid" == *" $p "* ]] && continue
        port_in_use "$p" && continue
        landing_port "$p" && continue
        if [ -n "$strict" ] && own_port "$p"; then continue; fi
        echo "$p"
        return 0
    done
    return 1
}

# 询问端口：$1=提示 $2=需避开的端口(空格分隔，可空) $3=strict(追加节点时：配置里已有的端口一律不能用)
# 结果放在 ASKED_PORT
ask_port() {
    local prompt="$1" avoid=" ${2:-} " strict="${3:-}" p ans hint
    nat_load
    if nat_on; then
        hint=$(rand_free_port "${2:-}" "$strict" || true)
        info "NAT 模式：回车自动使用商家映射端口${hint:+ $hint}（映射端口: $NAT_PORTS${NAT_SSH_PORT:+，SSH: $NAT_SSH_PORT}）"
        [ -n "$hint" ] && prompt="${prompt/回车随机 20000-65000/回车使用映射端口 $hint}"
    fi
    while true; do
        read -r -p "$prompt" p || { err "没有读到输入，已取消"; return 1; }
        p=$(printf '%s' "$p" | tr -d '[:space:]')
        if [ -z "$p" ]; then
            if ! p=$(rand_free_port "${2:-}" "$strict"); then
                if nat_on; then
                    err "映射端口已经用完（$NAT_PORTS）。请手动输入，或在 sb「NAT 映射端口」里补充商家给的新端口"
                else
                    err "没找到空闲端口，请手动输入"
                fi
                continue
            fi
            info "自动选择端口: $p"
        fi
        if ! valid_port "$p"; then err "端口无效: $p（需为 1-65535 的数字）"; continue; fi
        p=$((10#$p))
        if nat_on; then
            if [ "$p" = "${NAT_SSH_PORT:-}" ]; then err "端口 $p 是 SSH 用的映射端口，不能用"; continue; fi
            if ! in_words "$p" "$NAT_PORTS"; then
                warn "端口 $p 不在商家映射端口($NAT_PORTS)里，外网很可能连不上"
                read -r -p "仍然使用 $p ?(y/N): " ans || ans=""
                [[ "$ans" =~ ^[Yy]$ ]] || continue
            fi
        fi
        if [[ "$avoid" == *" $p "* ]]; then err "端口 $p 已被本机其他节点使用，请换一个"; continue; fi
        # NAT 模式下映射端口少：落地机只用了这个端口的 UDP(HY2/TUIC) 时，线路机节点(TCP)可以共用端口号
        if landing_port "$p" && ! { nat_on && ! cfg_port_nets "$LANDING_CONFIG" x | grep -q "^$p tcp "; }; then
            err "端口 $p 已被本机的落地机节点($LANDING_CONFIG)使用，请换一个"; continue
        fi
        if [ -n "$strict" ]; then
            if own_port "$p"; then err "端口 $p 已被本机线路机的其他节点使用，请换一个"; continue; fi
            if port_in_use "$p"; then err "端口 $p 已被本机其他程序占用，请换一个"; continue; fi
        elif port_in_use "$p" && ! own_port "$p"; then
            err "端口 $p 已被占用，请换一个"; continue
        fi
        ASKED_PORT="$p"
        return 0
    done
}

set_pub_ip_uri() {
    # IPv6 在链接里需要加方括号
    if [[ "$PUB_IP" == *:* ]]; then PUB_IP_URI="[$PUB_IP]"; else PUB_IP_URI="$PUB_IP"; fi
}

make_link() {
    # $1=uuid $2=port $3=name
    echo "vless://$1@$PUB_IP_URI:$2?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$RELAY_SNI&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID#$(uri_encode "$3")"
}

new_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || sing-box generate uuid; }

# ===== 每台落地机一条记录（relays/<编号>.env）=====
list_records() {
    RECORDS=()
    [ -d "$RELAY_DIR" ] || return 0
    local f
    while IFS= read -r f; do
        [ -n "$f" ] && RECORDS+=("$f")
    done < <(find "$RELAY_DIR" -maxdepth 1 -type f -name '*.env' 2>/dev/null \
        | awk -F/ '{n=$NF; sub(/\.env$/,"",n); if (n ~ /^[0-9]+$/) print n "\t" $0}' | sort -n | cut -f2-)
    return 0
}

load_record() {
    R_IDX=""; R_UUID=""; R_PORT=""; R_NAME=""; R_SERVER=""; R_SERVER_PORT=""
    R_METHOD=""; R_PASSWORD=""; R_IN_TAG=""; R_OUT_TAG=""
    # shellcheck disable=SC1090
    . "$1"
}

save_record() {
    mkdir -p "$RELAY_DIR"
    chmod 700 "$RELAY_DIR" 2>/dev/null || true
    {
        printf 'R_IDX=%q\n' "$R_IDX"
        printf 'R_UUID=%q\n' "$R_UUID"
        printf 'R_PORT=%q\n' "$R_PORT"
        printf 'R_NAME=%q\n' "$R_NAME"
        printf 'R_SERVER=%q\n' "$R_SERVER"
        printf 'R_SERVER_PORT=%q\n' "$R_SERVER_PORT"
        printf 'R_METHOD=%q\n' "$R_METHOD"
        printf 'R_PASSWORD=%q\n' "$R_PASSWORD"
        printf 'R_IN_TAG=%q\n' "$R_IN_TAG"
        printf 'R_OUT_TAG=%q\n' "$R_OUT_TAG"
    } > "$RELAY_DIR/$R_IDX.env"
    chmod 600 "$RELAY_DIR/$R_IDX.env"
}

# 公共参数写入 relay.env；UUID/LISTEN_PORT/NODE_NAME 保留第一个中转节点的值，兼容旧版脚本
save_env() {
    mkdir -p "$SB_DIR"
    list_records
    local c_uuid="" c_port="" c_name=""
    if [ "${#RECORDS[@]}" -gt 0 ]; then
        c_uuid=$(load_record "${RECORDS[0]}"; printf '%s' "$R_UUID")
        c_port=$(load_record "${RECORDS[0]}"; printf '%s' "$R_PORT")
        c_name=$(load_record "${RECORDS[0]}"; printf '%s' "$R_NAME")
    fi
    {
        printf 'UUID=%q\n' "$c_uuid"
        printf 'PUB_IP=%q\n' "$PUB_IP"
        printf 'LISTEN_PORT=%q\n' "$c_port"
        printf 'REALITY_PUB=%q\n' "$REALITY_PUB"
        printf 'REALITY_SID=%q\n' "$REALITY_SID"
        printf 'RELAY_SNI=%q\n' "$RELAY_SNI"
        printf 'NODE_NAME=%q\n' "$c_name"
        printf 'DIRECT_ENABLED=%q\n' "$DIRECT_ENABLED"
        printf 'DIRECT_PORT=%q\n' "$DIRECT_PORT"
        printf 'DIRECT_UUID=%q\n' "$DIRECT_UUID"
        printf 'DIRECT_NAME=%q\n' "$DIRECT_NAME"
        printf 'RELAY_FORMAT=%q\n' "2"
    } > "$RELAY_ENV"
    chmod 600 "$RELAY_ENV"
}

# 旧版（只有一个中转节点、没有 relays/ 目录）自动迁移为节点 1：端口/UUID/名称/链接都不变
migrate_old() {
    list_records
    [ "${#RECORDS[@]}" -gt 0 ] && return 0
    [ -n "${UUID:-}" ] && [ -n "${LISTEN_PORT:-}" ] || return 0
    R_IDX=1
    R_UUID="$UUID"
    R_PORT="$LISTEN_PORT"
    R_NAME="${NODE_NAME:-中转-$PUB_IP}"
    R_IN_TAG="vless-in"
    R_OUT_TAG="relay-out"
    R_SERVER=""; R_SERVER_PORT=""; R_METHOD=""; R_PASSWORD=""
    if [ -f "$CONFIG" ]; then
        R_SERVER=$(jq -r '[(.outbounds // [])[] | select(.tag=="relay-out")][0].server // empty' "$CONFIG" 2>/dev/null || true)
        R_SERVER_PORT=$(jq -r '[(.outbounds // [])[] | select(.tag=="relay-out")][0].server_port // empty' "$CONFIG" 2>/dev/null || true)
        R_METHOD=$(jq -r '[(.outbounds // [])[] | select(.tag=="relay-out")][0].method // empty' "$CONFIG" 2>/dev/null || true)
        R_PASSWORD=$(jq -r '[(.outbounds // [])[] | select(.tag=="relay-out")][0].password // empty' "$CONFIG" 2>/dev/null || true)
    fi
    save_record
    list_records
    info "已把旧版的中转节点登记为「节点 1」（端口 $R_PORT、UUID、链接都不变）"
}

load_env() {
    if [ ! -f "$RELAY_ENV" ]; then
        err "未找到 $RELAY_ENV，请先完成线路机安装"
        return 1
    fi
    command -v jq >/dev/null 2>&1 || { err "需要 jq"; return 1; }
    # shellcheck disable=SC1090
    . "$RELAY_ENV"
    set_pub_ip_uri
    migrate_old
}

# 重新生成所有链接并整体重写 relay_uri.txt（不改动运行中的配置）
build_links() {
    set_pub_ip_uri
    list_records
    mkdir -p "$SB_DIR"
    local f tmp="${RELAY_URI_FILE}.tmp"
    : > "$tmp"
    for f in ${RECORDS[@]+"${RECORDS[@]}"}; do
        load_record "$f"
        make_link "$R_UUID" "$R_PORT" "$R_NAME" >> "$tmp"
    done
    if [ "$DIRECT_ENABLED" = "true" ]; then
        make_link "$DIRECT_UUID" "$DIRECT_PORT" "$DIRECT_NAME" >> "$tmp"
    fi
    mv "$tmp" "$RELAY_URI_FILE"
}

# 列出所有中转节点（编号从 1 开始，对应 RECORDS 下标+1）
print_records() {
    local i=0 f
    for f in ${RECORDS[@]+"${RECORDS[@]}"}; do
        i=$((i + 1))
        load_record "$f"
        echo "   $i) ${R_NAME}  | 线路机端口 ${R_PORT} → 落地机 ${R_SERVER:-未知}:${R_SERVER_PORT:-?}"
    done
}

show_link() {
    if [ -f "$RELAY_ENV" ] && command -v jq >/dev/null 2>&1; then
        load_env
        build_links
        local i=0 f
        for f in ${RECORDS[@]+"${RECORDS[@]}"}; do
            i=$((i + 1))
            load_record "$f"
            echo "=============== 中转节点 $i (出口落地机 ${R_SERVER:-未知}:${R_SERVER_PORT:-?}) ==============="
            echo "名称: $R_NAME    线路机端口: $R_PORT"
            make_link "$R_UUID" "$R_PORT" "$R_NAME"
        done
        if [ "$DIRECT_ENABLED" = "true" ]; then
            echo "=============== 直连节点(出口本机) ================="
            echo "名称: $DIRECT_NAME    线路机端口: $DIRECT_PORT"
            make_link "$DIRECT_UUID" "$DIRECT_PORT" "$DIRECT_NAME"
        fi
        echo "===================================================="
        echo "所有链接也保存在: $RELAY_URI_FILE"
        share_reminder
    elif [ -f "$RELAY_URI_FILE" ]; then
        echo "=============== 中转节点 Reality 链接 ==============="
        cat "$RELAY_URI_FILE"
        echo "===================================================="
        share_reminder
    else
        err "未找到 $RELAY_URI_FILE"
        return 1
    fi
}

# 让用户从中转节点列表里选一个，结果放在 CHOSEN（记录文件路径）
choose_record() {
    local prompt="$1" n
    CHOSEN=""
    print_records
    read -r -p "$prompt" n || return 1
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#RECORDS[@]}" ]; then
        CHOSEN="${RECORDS[$((n - 1))]}"
        return 0
    fi
    err "无效选择: $n"
    return 1
}

# 修改节点名称：只重新生成链接和 relay_uri.txt，不动 config.json / 服务
rename_node() {
    load_env || return 1
    local which new_name f
    echo "要修改哪个节点的名称?"
    print_records
    [ "$DIRECT_ENABLED" = "true" ] && echo "   d) 直连节点(出口本机): $DIRECT_NAME"
    read -r -p "请输入编号(回车默认 1): " which || return 1
    which="${which:-1}"
    if [[ "$which" =~ ^[Dd]$ ]] && [ "$DIRECT_ENABLED" = "true" ]; then
        read -r -p "请输入新的直连节点名称(回车保持「$DIRECT_NAME」): " new_name || true
        DIRECT_NAME="${new_name:-$DIRECT_NAME}"
        info "✅ 直连节点名称: $DIRECT_NAME（未改动运行中的配置）"
    elif [[ "$which" =~ ^[0-9]+$ ]] && [ "$which" -ge 1 ] && [ "$which" -le "${#RECORDS[@]}" ]; then
        f="${RECORDS[$((which - 1))]}"
        load_record "$f"
        read -r -p "请输入新的中转节点名称(回车保持「$R_NAME」): " new_name || true
        R_NAME="${new_name:-$R_NAME}"
        save_record
        info "✅ 中转节点 $which 名称: $R_NAME（未改动运行中的配置）"
    else
        err "无效选择: $which"
        return 1
    fi
    save_env
    build_links
    show_link
}

# ===== NAT 模式（LXC/NAT 小鸡：商家只映射少数几个端口，入口IP ≠ 出口IP）=====
# 落地机和线路机共用 /etc/sb-nat.conf：
#   NAT_MODE=1/0  NAT_PORTS=商家映射端口  NAT_UDP_PORTS=其中也映射了 UDP 的端口  NAT_SSH_PORT=SSH 用的映射端口  ENTRY_IP=入口IP
NAT_CONF="/etc/sb-nat.conf"
NAT_MODE=0; NAT_PORTS=""; NAT_UDP_PORTS=""; NAT_SSH_PORT=""; ENTRY_IP=""
NAT_USED=" "
declare -A NAT_LABEL=()

nat_load() {
    NAT_MODE=0; NAT_PORTS=""; NAT_UDP_PORTS=""; NAT_SSH_PORT=""; ENTRY_IP=""
    if [ -f "$NAT_CONF" ]; then
        # shellcheck disable=SC1090
        . "$NAT_CONF" 2>/dev/null || true
    fi
    return 0
}

nat_save() {
    {
        printf '# sb NAT 模式设置（落地机/线路机共用；sb 菜单「NAT 映射端口」「入口/出口 IP」里修改）\n'
        printf 'NAT_MODE=%q\n' "$NAT_MODE"
        printf 'NAT_PORTS=%q\n' "$NAT_PORTS"
        printf 'NAT_UDP_PORTS=%q\n' "$NAT_UDP_PORTS"
        printf 'NAT_SSH_PORT=%q\n' "$NAT_SSH_PORT"
        printf 'ENTRY_IP=%q\n' "$ENTRY_IP"
    } > "$NAT_CONF"
    chmod 600 "$NAT_CONF" 2>/dev/null || true
}

nat_on() { [ "${NAT_MODE:-0}" = "1" ] && [ -n "${NAT_PORTS:-}" ]; }
in_words() { [[ " $2 " == *" $1 "* ]]; }

# 解析端口列表：逗号/空格分隔，支持范围 a-b（最多 256 个端口）；结果放 NAT_PARSED（升序去重）
nat_parse_list() {
    local item lo hi p out=""
    for item in $(printf '%s' "$1" | tr ',，;' '   '); do
        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo=$((10#${BASH_REMATCH[1]})); hi=$((10#${BASH_REMATCH[2]}))
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            lo=$((10#$item)); hi=$lo
        else
            return 1
        fi
        [ "$lo" -ge 1 ] && [ "$hi" -le 65535 ] && [ "$lo" -le "$hi" ] || return 1
        [ $((hi - lo)) -le 256 ] || return 1
        for ((p = lo; p <= hi; p++)); do out="$out $p"; done
    done
    NAT_PARSED=$(printf '%s\n' $out | sort -n -u | tr '\n' ' ' | sed 's/ *$//')
    [ -n "$NAT_PARSED" ] && [ "$(printf '%s\n' $NAT_PARSED | wc -l)" -le 256 ]
}

# 某配置里各入站占用的 端口 网络 名称（SS=TCP+UDP，HY2/TUIC=UDP，其余=TCP）
cfg_port_nets() {
    [ -f "$1" ] && command -v jq >/dev/null 2>&1 || return 0
    jq -r --arg who "$2" '(.inbounds // [])[] | select(.listen_port != null) | .listen_port as $p | (.tag // .type) as $t
        | (if .type == "shadowsocks" then ["tcp","udp"] elif (.type == "hysteria2" or .type == "tuic") then ["udp"] else ["tcp"] end)[]
        | "\($p) \(.) \($who):\($t)"' "$1" 2>/dev/null || true
}

# 收集已占用的 端口/网络：$@ = 配置文件（落地机/线路机）
nat_collect_used() {
    local f p n l who
    NAT_USED=" "
    NAT_LABEL=()
    for f in "$@"; do
        [ -f "$f" ] || continue
        if [ "$f" = "$LANDING_CONFIG" ]; then who="落地机"; else who="线路机"; fi
        while read -r p n l; do
            [ -n "$p" ] || continue
            NAT_USED="$NAT_USED$p/$n "
            if [ "$n" = "udp" ] && [[ "${NAT_LABEL[$p]:-}" == *"$l(TCP)" ]]; then
                NAT_LABEL[$p]="${NAT_LABEL[$p]%(TCP)}(TCP+UDP)"
            else
                NAT_LABEL[$p]="${NAT_LABEL[$p]:+${NAT_LABEL[$p]}, }$l($(printf '%s' "$n" | tr 'a-z' 'A-Z'))"
            fi
        done < <(cfg_port_nets "$f" "$who")
    done
}
nat_mark() { NAT_USED="$NAT_USED$1/$2 "; }
nat_used() { [[ "$NAT_USED" == *" $1/$2 "* ]]; }

# 从映射端口里挑一个：$1 = tcp(VLESS/AnyTLS) | udp(HY2/TUIC，只用映射了 UDP 的端口) | ss(TCP+UDP)
# 优先完全空闲的端口；TCP 协议优先不占用映射了 UDP 的端口（留给 HY2/TUIC）；不用 SSH 端口
nat_pick() {
    local need="$1" p score best="" bs=99
    for p in $NAT_PORTS; do
        [ "$p" = "${NAT_SSH_PORT:-}" ] && continue
        score=0
        case "$need" in
            tcp)
                nat_used "$p" tcp && continue
                nat_used "$p" udp && score=$((score + 2))
                in_words "$p" "$NAT_UDP_PORTS" && score=$((score + 1))
                ;;
            udp)
                in_words "$p" "$NAT_UDP_PORTS" || continue
                nat_used "$p" udp && continue
                nat_used "$p" tcp && score=$((score + 2))
                ;;
            ss)
                nat_used "$p" tcp && continue
                nat_used "$p" udp && continue
                in_words "$p" "$NAT_UDP_PORTS" && score=$((score + 1))
                ;;
        esac
        if [ "$score" -lt "$bs" ]; then bs=$score; best=$p; fi
    done
    [ -n "$best" ] || return 1
    printf '%s' "$best"
}

# 打印 映射端口 → 用途 表
nat_table() {
    local p maps use free=""
    echo "   映射端口   商家映射      用途"
    for p in $NAT_PORTS; do
        maps="TCP"; in_words "$p" "$NAT_UDP_PORTS" && maps="TCP+UDP"
        if [ "$p" = "${NAT_SSH_PORT:-}" ]; then
            use="SSH(不能用)"
        else
            use="${NAT_LABEL[$p]:-}"
            [ -z "$use" ] && { use="空闲"; free="$free $p"; }
        fi
        printf '   %-10s %-12s %s\n' "$p" "$maps" "$use"
    done
    echo "   剩余空闲映射端口:${free:- 无}"
}

# 本机 sshd 端口（检测不到为 22）
detect_sshd_port() {
    local p=""
    p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
    [ -n "$p" ] || p=$(grep -Ei '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2; exit}' || true)
    printf '%s' "${p:-22}"
}

# 交互输入 映射端口列表 / SSH 端口 / UDP 端口；$1=tcponly 时 UDP 回车默认沿用（线路机节点只用 TCP）
# 环境变量: SINGBOX_NAT_PORTS SINGBOX_NAT_SSH_PORT SINGBOX_NAT_UDP(all|none|端口列表)
nat_ask_ports() {
    local in def sshd udp_in
    echo ""
    info "=== NAT 模式：填写商家映射给你的端口 ==="
    echo "   NAT 小鸡只有商家映射的几个端口能从外网连进来（例如 56566,56567,56568 或 56566-56570）。"
    echo "   脚本只会使用这些端口，自动给每个协议分配，不会碰 SSH 端口。"
    def="${NAT_PORTS:-}"
    in="${SINGBOX_NAT_PORTS:-}"
    while true; do
        if [ -z "$in" ]; then
            read -r -p "商家映射端口列表${def:+(回车沿用 $def)}: " in || { err "没有读到输入，退出"; exit 1; }
            in="${in:-$def}"
        fi
        if [ -n "$in" ] && nat_parse_list "$in"; then break; fi
        err "端口列表格式不对: '${in}'（例: 56566,56567,56568 或 56566-56570，最多 256 个）"
        in=""
    done
    NAT_PORTS="$NAT_PARSED"
    sshd=$(detect_sshd_port)
    def="${NAT_SSH_PORT:-}"
    in_words "$def" "$NAT_PORTS" || def=""
    if [ -z "$def" ] && in_words "$sshd" "$NAT_PORTS"; then def="$sshd"; fi
    in="${SINGBOX_NAT_SSH_PORT-__ask__}"
    while true; do
        if [ "$in" = "__ask__" ]; then
            echo "   本机 sshd 监听端口: $sshd。如果列表里有一个端口是商家给 SSH 用的(映射到本机 $sshd)，请填它；没有就输入 0。"
            read -r -p "列表中的 SSH 端口${def:+(回车默认 $def)}: " in || { err "没有读到输入，退出"; exit 1; }
            in="${in:-${def:-0}}"
        fi
        in=$(printf '%s' "$in" | tr -d '[:space:]')
        if [ -z "$in" ] || [ "$in" = "0" ]; then NAT_SSH_PORT=""; break; fi
        if in_words "$in" "$NAT_PORTS"; then NAT_SSH_PORT="$in"; break; fi
        err "SSH 端口 $in 不在映射端口列表里"
        in="__ask__"
    done
    def="${NAT_UDP_PORTS:-}"
    udp_in="${SINGBOX_NAT_UDP:-}"
    while true; do
        if [ -z "$udp_in" ]; then
            echo "   哪些端口商家也映射了 UDP？HY2/TUIC 只会放在映射了 UDP 的端口上（不确定就问商家，或填 none）。"
            if [ -n "$def" ]; then
                read -r -p "UDP 端口: all=全部 / none=没有 / 端口列表 (回车沿用 $def): " udp_in || { err "没有读到输入，退出"; exit 1; }
                udp_in="${udp_in:-$def}"
            else
                read -r -p "UDP 端口: all=全部 / none=没有 / 端口列表 (回车默认 all): " udp_in || { err "没有读到输入，退出"; exit 1; }
                udp_in="${udp_in:-all}"
            fi
        fi
        case "$udp_in" in
            all|ALL|All) NAT_UDP_PORTS="$NAT_PORTS"; break ;;
            none|NONE|None|0) NAT_UDP_PORTS=""; break ;;
        esac
        if nat_parse_list "$udp_in"; then
            local p ok=1 out=""
            for p in $NAT_PARSED; do
                if in_words "$p" "$NAT_PORTS"; then out="$out $p"; else err "UDP 端口 $p 不在映射端口列表里"; ok=0; fi
            done
            if [ "$ok" = 1 ]; then NAT_UDP_PORTS="${out# }"; break; fi
        else
            err "格式不对: '$udp_in'"
        fi
        udp_in=""
    done
    # SSH 端口不算可用的 UDP 端口
    if [ -n "$NAT_SSH_PORT" ]; then
        NAT_UDP_PORTS=$(printf '%s\n' $NAT_UDP_PORTS | grep -vx "$NAT_SSH_PORT" | tr '\n' ' ' | sed 's/ *$//' || true)
    fi
    info "映射端口: $NAT_PORTS | SSH: ${NAT_SSH_PORT:-无} | 映射了 UDP: ${NAT_UDP_PORTS:-无}"
}

# 是否像 NAT/容器（用于建议开启 NAT 模式）
local_ip4() {
    command -v ip >/dev/null 2>&1 || return 0
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true
}
is_private4() {
    local a b
    [[ "$1" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+\.[0-9]+$ ]] || return 1
    a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
    [ "$a" -eq 10 ] || { [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } \
        || { [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; } || { [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; }
}
in_container() {
    [ -f /proc/user_beancounters ] || grep -qa 'container=' /proc/1/environ 2>/dev/null \
        || grep -qE '/lxc/|lxc\.payload|docker' /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ] \
        || { command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -c -q 2>/dev/null; }
}
looks_nat() { in_container || is_private4 "$(local_ip4)"; }

# 线路机全新安装时：本机像 NAT/容器且还没设置过时，询问是否开启 NAT 模式（SINGBOX_NAT_MODE=1/0 可跳过询问）
nat_offer() {
    nat_load
    local ans="${SINGBOX_NAT_MODE:-}"
    if [ -z "$ans" ]; then
        [ -f "$NAT_CONF" ] && return 0
        looks_nat || return 0
        echo ""
        warn "检测到本机是容器或在 NAT 后面（网卡是内网 IP）。"
        echo "   如果商家只给了几个映射端口（LXC/NAT 小鸡），建议开启 NAT 模式：只用映射端口、自动分配，并单独记录入口IP。"
        echo "   Oracle/AWS 这类所有端口都通的云服务器(1:1 NAT)选 n。"
        read -r -p "是否开启 NAT 模式?(Y/n): " ans || ans=n
        case "$ans" in [Nn]*) ans=0 ;; *) ans=1 ;; esac
    fi
    if [ "$ans" = "1" ]; then
        NAT_MODE=1
        nat_ask_ports
    else
        NAT_MODE=0
    fi
    nat_save
}

# ===== 入口IP（客户端连接用）与 出口IP（本机访问外网显示的 IP）=====
valid_host() {
    local h="$1" o
    [ -n "$h" ] || return 1
    if [[ "$h" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for o in "${BASH_REMATCH[@]:1}"; do [ "$((10#$o))" -le 255 ] || return 1; done
        return 0
    fi
    [[ "$h" =~ ^[0-9A-Fa-f:.]+$ ]] && [[ "$h" == *:*:* ]] && return 0
    [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] && [[ "$h" =~ [A-Za-z] ]]
}
strip_host() { local h; h=$(printf '%s' "$1" | tr -d '[:space:]'); h="${h#[}"; printf '%s' "${h%]}"; }

# 检测出口 IP 和运营商：EXIT_IP / EXIT_ORG / EXIT_WARP
detect_exit_ip() {
    local u trace
    EXIT_IP=""; EXIT_ORG=""; EXIT_WARP=""
    for u in https://api.ipify.org https://ipv4.icanhazip.com https://api64.ipify.org; do
        EXIT_IP=$(curl -s --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)
        if valid_host "$EXIT_IP" && [[ "$EXIT_IP" =~ ^[0-9A-Fa-f:.]+$ ]]; then break; fi
        EXIT_IP=""
    done
    [ -n "$EXIT_IP" ] || return 1
    EXIT_ORG=$(curl -s --max-time 5 "https://ipinfo.io/${EXIT_IP}/org" 2>/dev/null | head -n1 | tr -d '\r' || true)
    case "$EXIT_ORG" in *"{"*|*"<"*) EXIT_ORG="" ;; esac
    trace=$(curl -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    printf '%s\n' "$trace" | grep -qE '^warp=(on|plus)$' && EXIT_WARP=1
    return 0
}

show_exit_ip() {
    if detect_exit_ip; then
        echo "   出口IP(本机访问外网时显示): ${EXIT_IP}${EXIT_ORG:+  ($EXIT_ORG)}${EXIT_WARP:+  [Cloudflare WARP]}"
        if [ -n "$1" ] && [ "$(strip_host "$1")" != "$EXIT_IP" ]; then
            echo "   入口IP 和出口IP 不一样：NAT 小鸡上这是正常的（出口可能是商家的解锁出口/家宽，或 WARP）。"
            echo "   客户端/线路机一律连【入口IP】，看网站、解锁时显示的是【出口IP】。"
        fi
    else
        echo "   出口IP: 检测失败（网络不通或检测接口被墙，不影响使用）"
    fi
}

# 本机已保存的入口IP：/etc/sb-nat.conf 的 ENTRY_IP > 落地机 CUSTOM_IP > 线路机 relay.env 的 PUB_IP
saved_entry_ip() {
    local e=""
    nat_load
    e="$ENTRY_IP"
    [ -n "$e" ] || e=$( (. "$LANDING_DIR/.config_cache" >/dev/null 2>&1; printf '%s' "${CUSTOM_IP:-}") 2>/dev/null || true)
    # shellcheck disable=SC1090
    [ -n "$e" ] || e=$( (. "$RELAY_ENV" >/dev/null 2>&1; printf '%s' "${PUB_IP:-}") 2>/dev/null || true)
    strip_host "$e"
}

# 写入 KEY=VALUE（替换已有的 KEY）
kv_put() {
    local file="$1" key="$2" val="$3" tmp
    [ -f "$file" ] || return 0
    tmp=$(mktemp)
    grep -v "^${key}=" "$file" > "$tmp" || true
    printf '%s=%q\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# 查看/修改入口IP：只重新生成链接（落地机 CUSTOM_IP、线路机 PUB_IP），不改节点、不重启
# $1 = 新入口IP（可空，空则交互）
entry_ip_menu() {
    local cur new ans lc_host
    cur=$(saved_entry_ip)
    echo ""
    info "=== 入口IP / 出口IP ==="
    echo "   入口IP(节点链接里用的地址): ${cur:-未设置}"
    show_exit_ip "$cur"
    new=$(strip_host "${1:-}")
    if [ -z "$new" ]; then
        read -r -p "输入新的入口IP/域名(商家面板里的公网IP，回车不修改): " new || new=""
        new=$(strip_host "$new")
    fi
    [ -n "$new" ] || { info "未修改"; return 0; }
    if ! valid_host "$new"; then err "地址无效: '$new'（需为 IPv4、IPv6 或域名）"; return 1; fi
    nat_load
    ENTRY_IP="$new"
    nat_save
    lc_host="$new"; [[ "$lc_host" == *:* ]] && lc_host="[$lc_host]"
    if [ -f "$LANDING_DIR/.config_cache" ]; then
        kv_put "$LANDING_DIR/.config_cache" CUSTOM_IP "$lc_host"
        info "落地机节点的入口地址已改为 $lc_host（输入 sb → 1 查看新链接）"
    fi
    if [ -f "$RELAY_ENV" ]; then
        ans=y
        if [ -f "$LANDING_DIR/.config_cache" ] && [ -z "${1:-}" ]; then
            read -r -p "同时更新本机线路机/直连节点链接里的地址?(Y/n): " ans || ans=y
        fi
        if [[ ! "$ans" =~ ^[Nn]$ ]]; then
            load_env || return 1
            PUB_IP="$new"
            save_env
            build_links
            info "线路机/直连节点链接已改用入口地址 $new（节点、端口、密钥都没变，服务未重启）："
            show_link
        fi
    fi
    return 0
}

# 查看/修改 NAT 映射端口（不改动已有节点）
nat_menu() {
    local c
    nat_load
    nat_collect_used "$LANDING_CONFIG" "$CONFIG"
    echo ""
    info "=== NAT 模式 / 映射端口 ==="
    if nat_on; then
        echo "   NAT 模式: 已开启（新协议/新节点只从下面的映射端口里自动选）"
        nat_table
    else
        echo "   NAT 模式: 未开启${NAT_PORTS:+（已保存的映射端口: $NAT_PORTS）}"
    fi
    echo "1) 设置/修改映射端口列表（含 SSH 端口、哪些端口映射了 UDP），并开启 NAT 模式"
    nat_on && echo "2) 关闭 NAT 模式（以后新节点随机端口，与普通 VPS 一样）"
    echo "0) 返回"
    read -r -p "请选择: " c || c=0
    case "$c" in
        1)
            nat_ask_ports
            NAT_MODE=1
            nat_save
            nat_collect_used "$LANDING_CONFIG" "$CONFIG"
            nat_table
            local p bad=""
            for p in $(printf '%s\n' $NAT_USED | sed 's|/.*||' | sort -u); do
                in_words "$p" "$NAT_PORTS" || bad="$bad $p"
            done
            [ -n "$bad" ] && warn "这些已有节点的端口不在映射列表里，外网可能连不上:${bad}（可在 sb 里「重置端口」改到映射端口）"
            info "已保存到 $NAT_CONF（已有节点没有任何改动）"
            ;;
        2) if nat_on; then NAT_MODE=0; nat_save; info "已关闭 NAT 模式（端口列表保留在 $NAT_CONF）"; fi ;;
        *) ;;
    esac
}

# ===== 低内存：内存 ≤256MiB 时给 sing-box 设置 GOMEMLIMIT/GOGC =====
mem_mib() {
    local kb lim m=""
    kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || true)
    [ -n "$kb" ] && m=$((kb / 1024))
    for lim in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        lim=$(cat "$lim" 2>/dev/null || true)
        if [[ "$lim" =~ ^[0-9]+$ ]] && [ "$lim" -gt 0 ] && [ "$lim" -lt 1099511627776 ]; then
            lim=$((lim / 1024 / 1024))
            if [ -z "$m" ] || [ "$lim" -lt "$m" ]; then m="$lim"; fi
        fi
    done
    printf '%s' "${m:-0}"
}
# 线路机服务的 GOMEMLIMIT（空 = 不限制）：本机也有落地机节点时两个 sing-box 各 45%，否则 75%
relay_gomem() {
    local m pct=75
    m=$(mem_mib)
    { [ -n "${SINGBOX_MEM_MIB:-}" ] && m="$SINGBOX_MEM_MIB"; } || true
    [ "$m" -gt 0 ] && [ "$m" -le 256 ] || return 0
    [ -f "$LANDING_CONFIG" ] && [ -f "$LANDING_DIR/.config_cache" ] && pct=45
    printf '%sMiB' "$((m * pct / 100))"
}

# ===== 磁盘 / 安装缓存 =====
check_disk() {
    local avail
    avail=$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}' || true)
    [[ "$avail" =~ ^[0-9]+$ ]] || return 0
    avail=$((avail / 1024))
    if [ "$avail" -lt 150 ]; then
        warn "磁盘剩余空间只有约 ${avail} MB（低于 150MB）：安装 sing-box 需要约 50~80MB，空间不足可能失败。"
        warn "   可先清理: rm -rf /var/cache/apk/* ; apt-get clean ; 删除不用的日志/文件"
    else
        info "磁盘剩余空间: 约 ${avail} MB"
    fi
}
clean_pkg_cache() {
    if command -v apk >/dev/null 2>&1; then
        rm -rf /var/cache/apk/* 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get clean >/dev/null 2>&1 || true
    fi
}

# ===== 安装 sing-box：Alpine 优先官方仓库，版本太旧/没有时从 GitHub 下载官方二进制，再不行用 edge 仓库 =====
SB_MIN_VER="1.11.0"   # hysteria2 ignore_client_bandwidth 需要 1.11；AnyTLS 需要 1.12（落地机安装时会提高要求）
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]; }
sb_version() { sing-box version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true; }
sb_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; armv7*) echo armv7 ;; armv6*) echo armv6 ;;
        i?86) echo 386 ;; s390x) echo s390x ;; riscv64) echo riscv64 ;; *) return 1 ;;
    esac
}
install_singbox_github() {
    local arch ver tmp dir v variants
    arch=$(sb_arch) || { err "不支持的 CPU 架构: $(uname -m)"; return 1; }
    ver=$(curl -fsSI --max-time 15 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | tr -d '\r' \
        | awk 'tolower($1)=="location:"{n=split($2,a,"/"); print a[n]}' | sed 's/^v//' || true)
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn "获取 GitHub 上 sing-box 最新版本失败"; return 1; }
    # Alpine(musl) 先用 -musl 版本；其他系统先用默认版本；下载后先运行一次确认能用，才替换现有程序
    if ls /lib/ld-musl-* >/dev/null 2>&1; then variants="musl plain"; else variants="plain glibc"; fi
    tmp=$(mktemp -d)
    for v in $variants; do
        if [ "$v" = "plain" ]; then v=""; else v="-$v"; fi
        dir="sing-box-${ver}-linux-${arch}${v}"
        info "从 GitHub 下载 sing-box ${ver}（官方程序 ${arch}${v}）..."
        rm -rf "${tmp:?}"/*
        if curl -fsSL --max-time 300 -o "$tmp/sb.tgz" "https://github.com/SagerNet/sing-box/releases/download/v${ver}/${dir}.tar.gz" \
            && tar -xzf "$tmp/sb.tgz" -C "$tmp" && [ -f "$tmp/$dir/sing-box" ] && "$tmp/$dir/sing-box" version >/dev/null 2>&1; then
            cp "$tmp/$dir/sing-box" /usr/bin/sing-box.new && chmod 755 /usr/bin/sing-box.new && mv -f /usr/bin/sing-box.new /usr/bin/sing-box
            rm -rf "$tmp"
            return 0
        fi
    done
    rm -rf "$tmp" /usr/bin/sing-box.new
    warn "从 GitHub 下载 sing-box 失败(或下载的程序在本机无法运行)"
    return 1
}
# $1 = 最低版本
install_singbox_alpine() {
    local need="${1:-$SB_MIN_VER}" repo
    repo=$(apk --no-cache search -x sing-box 2>/dev/null | sed -n 's/^sing-box-\([0-9][0-9.]*\)-r[0-9]*$/\1/p' | head -n1 || true)
    if [ -n "$repo" ] && ver_ge "$repo" "$need"; then
        info "使用 Alpine 官方仓库的 sing-box $repo"
        apk add --no-cache sing-box && return 0
    elif [ -n "$repo" ]; then
        warn "Alpine 官方仓库的 sing-box 是 $repo，低于本脚本需要的 $need，改从 GitHub 下载"
    else
        info "当前 Alpine 版本的官方仓库没有 sing-box，改从 GitHub 下载"
    fi
    install_singbox_github && return 0
    warn "改用 Alpine edge 仓库安装 sing-box"
    apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box
}

# ===== 服务管理：独立服务 sing-box-relay（systemd 或 OpenRC），与落地机的 sing-box 服务互不影响 =====
svc_kind() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        echo systemd
    elif command -v rc-service >/dev/null 2>&1; then
        echo openrc
    elif command -v systemctl >/dev/null 2>&1; then
        echo systemd
    else
        echo none
    fi
}

singbox_bin() { command -v sing-box 2>/dev/null || echo /usr/bin/sing-box; }

# 服务文件内容：$1 = openrc | systemd（内存 ≤256MiB 时加 GOMEMLIMIT/GOGC）
service_text() {
    local bin gm
    bin=$(singbox_bin)
    gm=$(relay_gomem)
    case "$1" in
        openrc)
            echo "#!/sbin/openrc-run"
            if [ -n "$gm" ]; then
                echo "export GOMEMLIMIT=${gm}"
                echo "export GOGC=70"
            fi
            cat <<SVC
name="${SVC_NAME}"
description="sing-box relay (线路机中转/直连节点)"
command="${bin}"
command_args="run -c ${CONFIG}"
command_background="yes"
pidfile="/run/${SVC_NAME}.pid"
output_log="/var/log/${SVC_NAME}.log"
error_log="/var/log/${SVC_NAME}.err"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5${gm:+ --env GOMEMLIMIT=${gm} --env GOGC=70}"

depend() {
    need net
    after firewall
}
SVC
            ;;
        systemd)
            cat <<SVC
[Unit]
Description=sing-box relay (线路机中转/直连节点)
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${SB_DIR}
ExecStart=${bin} run -c ${CONFIG}
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576
${gm:+Environment=GOMEMLIMIT=${gm}
Environment=GOGC=70
}
[Install]
WantedBy=multi-user.target
SVC
            ;;
    esac
}

# 写入服务文件并设置开机自启（不启动）
install_service() {
    local gm
    gm=$(relay_gomem)
    [ -n "$gm" ] && info "低内存模式: $SVC_NAME 服务设置 GOMEMLIMIT=${gm} GOGC=70"
    case "$(svc_kind)" in
        openrc)
            service_text openrc > "$OPENRC_INIT"
            chmod +x "$OPENRC_INIT"
            rc-update add "$SVC_NAME" default >/dev/null 2>&1 || warn "添加开机自启失败: rc-update add $SVC_NAME default"
            ;;
        systemd)
            service_text systemd > "$SYSTEMD_UNIT"
            systemctl daemon-reload || true
            systemctl enable "$SVC_NAME" >/dev/null 2>&1 || warn "设置开机自启失败: systemctl enable $SVC_NAME"
            ;;
        *)
            warn "未检测到 systemd / OpenRC，无法创建服务；请自行运行: $(singbox_bin) run -c $CONFIG"
            return 1
            ;;
    esac
}

service_installed() { [ -f "$SYSTEMD_UNIT" ] || [ -f "$OPENRC_INIT" ]; }

# 升级时：服务文件和应有内容不同（例如内存 ≤256MiB 需要 GOMEMLIMIT）就更新；只在服务原本运行时重启
refresh_service() {
    local kind target tmp gm
    kind=$(svc_kind)
    case "$kind" in
        openrc) target="$OPENRC_INIT" ;;
        systemd) target="$SYSTEMD_UNIT" ;;
        *) return 0 ;;
    esac
    [ -f "$target" ] || return 0
    tmp=$(mktemp)
    service_text "$kind" > "$tmp"
    if cmp -s "$tmp" "$target"; then rm -f "$tmp"; return 0; fi
    cat "$tmp" > "$target"
    rm -f "$tmp"
    [ "$kind" = "openrc" ] && chmod +x "$target"
    [ "$kind" = "systemd" ] && { systemctl daemon-reload >/dev/null 2>&1 || true; }
    gm=$(relay_gomem)
    info "已更新 $SVC_NAME 服务文件${gm:+（内存 ≤256MiB：GOMEMLIMIT=${gm} GOGC=70）}"
    if svc_active; then
        svc_restart >/dev/null 2>&1 && info "已重启 $SVC_NAME 使设置生效（节点/端口/链接不变）" || warn "重启 $SVC_NAME 失败，请运行: bash $SELF_COPY status"
    fi
    return 0
}

svc_restart() {
    service_installed || install_service || return 1
    case "$(svc_kind)" in
        openrc) rc-service "$SVC_NAME" restart ;;
        systemd) systemctl restart "$SVC_NAME" ;;
        *) return 1 ;;
    esac
}

svc_stop() {
    case "$(svc_kind)" in
        openrc) rc-service "$SVC_NAME" stop >/dev/null 2>&1 || true ;;
        systemd) systemctl stop "$SVC_NAME" >/dev/null 2>&1 || true ;;
    esac
}

svc_active() {
    case "$(svc_kind)" in
        openrc) rc-service "$SVC_NAME" status >/dev/null 2>&1 ;;
        systemd) systemctl is-active "$SVC_NAME" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

svc_status() {
    case "$(svc_kind)" in
        openrc) rc-service "$SVC_NAME" status || true; tail -n 20 "/var/log/${SVC_NAME}.err" 2>/dev/null || true ;;
        systemd) systemctl status "$SVC_NAME" --no-pager || true ;;
        *) warn "未检测到 systemd / OpenRC" ;;
    esac
}

# 关闭并删除本服务（卸载用）
remove_service() {
    svc_stop
    case "$(svc_kind)" in
        openrc) rc-update del "$SVC_NAME" default >/dev/null 2>&1 || true ;;
        systemd) systemctl disable "$SVC_NAME" >/dev/null 2>&1 || true ;;
    esac
    rm -f "$OPENRC_INIT" "$SYSTEMD_UNIT"
    if [ "$(svc_kind)" = "systemd" ]; then systemctl daemon-reload >/dev/null 2>&1 || true; fi
}

# 落地机的 sing-box 服务（仅迁移旧版线路机时使用）
landing_svc() {
    # $1 = stop | start | restart | disable | active
    case "$(svc_kind):$1" in
        openrc:disable) rc-update del sing-box default >/dev/null 2>&1 || true ;;
        openrc:active) rc-service sing-box status >/dev/null 2>&1 ;;
        openrc:*) rc-service sing-box "$1" ;;
        systemd:disable) systemctl disable sing-box >/dev/null 2>&1 || true ;;
        systemd:active) systemctl is-active sing-box >/dev/null 2>&1 ;;
        systemd:*) systemctl "$1" sing-box ;;
        *) return 1 ;;
    esac
}

# ===== 日志：默认 warn 级别 + 每小时自动清理（落地机 sing-box 和线路机 sing-box-relay 共用）=====
LOG_HELPER="/usr/local/bin/sb-logrotate"
LOG_PREF="/etc/sb-log.conf"                         # 用户在菜单里手动选过的日志级别（有它就不再自动改级别）
CRON_FILE="/etc/crontabs/root"                      # Alpine/busybox crond
CRON_D="/etc/cron.d/sb-logrotate"                   # Debian/Ubuntu cron
LOG_TIMER_SVC="/etc/systemd/system/sb-logrotate.service"
LOG_TIMER="/etc/systemd/system/sb-logrotate.timer"
JOURNALD_DROPIN="/etc/systemd/journald.conf.d/sing-box.conf"
OLD_LOGCLEAN="/usr/local/bin/sb-logclean.sh"         # 以前手动加的清理脚本，换成 sb-logrotate

# 本脚本装的落地机配置（有 .config_cache）或旧版线路机配置（有 relay.env）；
# 不碰 apk/deb 包自带的示例 /etc/sing-box/config.json
landing_log_config() {
    [ -f "$LANDING_CONFIG" ] && { [ -f "$LANDING_DIR/.config_cache" ] || [ -f "$LANDING_DIR/relay.env" ]; }
}
has_any_config() { landing_log_config || [ -f "$CONFIG" ]; }

# 本机存在的 sing-box 配置（落地机 / 线路机）
log_configs() {
    landing_log_config && printf '%s\n' "$LANDING_CONFIG"
    [ -f "$CONFIG" ] && printf '%s\n' "$CONFIG"
    return 0
}

cfg_log_level() { jq -r '.log.level // "info"' "$1" 2>/dev/null || echo "?"; }

# 写入/更新清理脚本（纯 POSIX sh，busybox 可用；只截断不重启，OpenRC 打开的日志文件继续可写）
write_log_helper() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<'LOGROTATE_EOF'
#!/bin/sh
# SB_LOGROTATE: sing-box 日志自动清理（由 sb / 线路机脚本安装，每小时运行一次）
# SB_LOGROTATE_VERSION=2
# 单个日志超过 50MB 时只保留最后约 1MB（原地截断，不用重启服务）；--now 立即清空全部日志
# 包括 Argo 备用入口 cloudflared 的日志 /var/log/sb-argo.log
MAX=${SB_LOG_MAX_BYTES:-52428800}
KEEP=${SB_LOG_KEEP_BYTES:-1048576}
NOW=0
[ "${1:-}" = "--now" ] && NOW=1
for f in /var/log/sing-box*.log /var/log/sing-box*.err /var/log/sb-argo.log; do
    [ -f "$f" ] || continue
    if [ "$NOW" = 1 ]; then
        : > "$f"
        continue
    fi
    size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) continue ;; esac
    [ "$size" -gt "$MAX" ] || continue
    tmp=$(mktemp /tmp/sb-logrotate.XXXXXX) || continue
    if tail -c "$KEEP" "$f" > "$tmp"; then
        cat "$tmp" > "$f"
    fi
    rm -f "$tmp"
done
exit 0
LOGROTATE_EOF
    if [ -f "$LOG_HELPER" ] && cmp -s "$tmp" "$LOG_HELPER"; then
        rm -f "$tmp"
        return 1   # 无变化
    fi
    mkdir -p "$(dirname "$LOG_HELPER")"
    cat "$tmp" > "$LOG_HELPER"
    rm -f "$tmp"
    chmod 755 "$LOG_HELPER"
    return 0
}

# 删除以前手动加的 /usr/local/bin/sb-logclean.sh 及其定时任务
remove_old_logclean() {
    local f found=false
    for f in "$CRON_FILE" /var/spool/cron/crontabs/root; do
        if [ -f "$f" ] && grep -q 'sb-logclean\.sh' "$f" 2>/dev/null; then
            grep -v 'sb-logclean\.sh' "$f" > "$f.sbtmp" || true
            cat "$f.sbtmp" > "$f"
            rm -f "$f.sbtmp"
            found=true
        fi
    done
    if [ -f "$OLD_LOGCLEAN" ]; then
        rm -f "$OLD_LOGCLEAN"
        found=true
    fi
    if $found; then
        info "已删除以前手动添加的 $OLD_LOGCLEAN 及其定时任务，改用 $LOG_HELPER（超过 50MB 只保留最后 1MB）"
    fi
    return 0
}

# 安排每小时运行：OpenRC 用 busybox crond；systemd 优先 cron，没有 cron 用 systemd timer
schedule_log_helper() {
    local kind changed=false
    kind=$(svc_kind)
    if [ "$kind" = "systemd" ]; then
        if [ -d /etc/cron.d ] && { command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1; }; then
            if ! grep -qs 'sb-logrotate' "$CRON_D"; then
                printf '# sing-box 日志自动清理（sb 安装）\n0 * * * * root %s >/dev/null 2>&1\n' "$LOG_HELPER" > "$CRON_D"
                chmod 644 "$CRON_D"
                changed=true
            fi
        elif [ ! -f "$LOG_TIMER" ]; then
            cat > "$LOG_TIMER_SVC" <<UNIT
[Unit]
Description=sing-box 日志自动清理 (sb-logrotate)

[Service]
Type=oneshot
ExecStart=$LOG_HELPER
UNIT
            cat > "$LOG_TIMER" <<UNIT
[Unit]
Description=每小时清理 sing-box 日志 (sb-logrotate)

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
UNIT
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable --now sb-logrotate.timer >/dev/null 2>&1 || warn "启用 sb-logrotate.timer 失败"
            changed=true
        fi
    else
        mkdir -p "$(dirname "$CRON_FILE")"
        touch "$CRON_FILE"
        if ! grep -q 'sb-logrotate' "$CRON_FILE" 2>/dev/null; then
            printf '0 * * * * %s >/dev/null 2>&1\n' "$LOG_HELPER" >> "$CRON_FILE"
            changed=true
        fi
        if [ "$kind" = "openrc" ]; then
            if [ ! -f /etc/init.d/crond ] && command -v apk >/dev/null 2>&1; then
                apk add --no-cache busybox-openrc >/dev/null 2>&1 || true
            fi
            if [ -f /etc/init.d/crond ]; then
                if [ ! -e /etc/runlevels/default/crond ]; then
                    rc-update add crond default >/dev/null 2>&1 || true
                    changed=true
                fi
                rc-service crond status >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || warn "启动 crond 失败，日志不会自动清理：rc-service crond start"
            else
                warn "未找到 crond 服务（/etc/init.d/crond），日志不会自动清理；可运行 apk add busybox-openrc 后再执行一次 sb"
            fi
        fi
    fi
    $changed && info "已设置每小时自动清理 sing-box 日志（单个日志超过 50MB 时只保留最后 1MB）"
    return 0
}

# systemd：限制 journald 日志最多 50MB
setup_journald() {
    [ "$(svc_kind)" = "systemd" ] || return 0
    local want
    want=$'# sing-box 日志限制（sb 安装）\n[Journal]\nSystemMaxUse=50M'
    if [ -f "$JOURNALD_DROPIN" ] && [ "$(cat "$JOURNALD_DROPIN")" = "$want" ]; then
        return 0
    fi
    mkdir -p "$(dirname "$JOURNALD_DROPIN")"
    printf '%s\n' "$want" > "$JOURNALD_DROPIN"
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    info "已限制 systemd 日志(journald)最多占用 50MB: $JOURNALD_DROPIN"
}

# 重启某个配置对应的服务（服务本来没在运行就不启动它）
restart_for_cfg() {
    if [ "$1" = "$CONFIG" ]; then
        svc_active || return 0
        svc_restart
    else
        landing_svc active || return 0
        landing_svc restart
    fi
}

# 把一个配置的日志级别改成 $2：只改 log.level 这一处（其余内容逐字节不变），sing-box check 通过才重启，失败还原
set_cfg_level() {
    local cfg="$1" lvl="$2" cur bak
    cur=$(cfg_log_level "$cfg")
    [ "$cur" = "$lvl" ] && return 0
    bak="${cfg}.bak.loglevel.$(date +%Y%m%d%H%M%S)"
    cp -p "$cfg" "$bak"
    if jq -e 'has("log") and (.log | has("level"))' "$cfg" >/dev/null 2>&1 \
        && [ "$(grep -c '"level"[[:space:]]*:[[:space:]]*"'"$cur"'"' "$cfg")" -eq 1 ]; then
        sed -i 's/\("level"[[:space:]]*:[[:space:]]*"\)'"$cur"'"/\1'"$lvl"'"/' "$cfg"
    else
        jq --arg l "$lvl" '.log = ((.log // {}) + {level: $l})' "$bak" > "${cfg}.tmp" && cat "${cfg}.tmp" > "$cfg"
        rm -f "${cfg}.tmp"
    fi
    if [ "$(cfg_log_level "$cfg")" != "$lvl" ] \
        || [ "$(jq -cS 'del(.log.level)' "$cfg" 2>/dev/null)" != "$(jq -cS 'del(.log.level)' "$bak" 2>/dev/null)" ] \
        || { command -v sing-box >/dev/null 2>&1 && ! sing-box check -c "$cfg" >/dev/null 2>&1; }; then
        cp -p "$bak" "$cfg"
        rm -f "$bak"
        err "修改 $cfg 的日志级别失败（校验未通过），已还原，服务未重启"
        return 1
    fi
    if ! restart_for_cfg "$cfg" >/dev/null 2>&1; then
        warn "$cfg 已改为 $lvl，但重启服务失败，已还原为 $cur"
        cp -p "$bak" "$cfg"
        restart_for_cfg "$cfg" >/dev/null 2>&1 || true
        rm -f "$bak"
        return 1
    fi
    rm -f "$bak"
    info "日志级别: $cfg  $cur → $lvl（运行中的服务已重启）"
    return 0
}

# 自动设置（每次运行都会检查，已设置好时什么都不做）：清理脚本 + 定时任务 + journald + info→warn
log_autosetup() {
    command -v jq >/dev/null 2>&1 || return 0
    local cfg
    has_any_config || return 0               # 本机还没有任何节点
    write_log_helper && info "已安装日志清理脚本: $LOG_HELPER"
    remove_old_logclean
    schedule_log_helper
    setup_journald
    # 用户没在菜单里手动选过级别：info 自动改为 warn（只改这一处，节点/端口/密钥/链接都不变）
    if [ ! -f "$LOG_PREF" ]; then
        while IFS= read -r -u 3 cfg; do
            [ "$(cfg_log_level "$cfg")" = "info" ] || continue
            info "日志级别 info 产生的日志太多（小鸡磁盘可能被写满），改为 warn: $cfg"
            set_cfg_level "$cfg" warn || true
        done 3< <(log_configs)
    fi
    return 0
}

# 立即清空日志
log_clean_now() {
    local before f
    before=$(du -ch /var/log/sing-box*.log /var/log/sing-box*.err 2>/dev/null | tail -n1 | awk '{print $1}' || true)
    if [ -x "$LOG_HELPER" ]; then
        "$LOG_HELPER" --now
    else
        for f in /var/log/sing-box*.log /var/log/sing-box*.err; do [ -f "$f" ] && : > "$f"; done
    fi
    info "已清空 sing-box 日志文件(/var/log/sing-box*.log /var/log/sing-box*.err，清理前共 ${before:-0})，服务无需重启"
    if [ "$(svc_kind)" = "systemd" ] && command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-size=50M >/dev/null 2>&1 || true
        info "已把 systemd 日志(journald)压缩到 50MB 以内"
    fi
}

# 切换日志级别（warn ↔ info），同时作用于本机的落地机和线路机配置；$1 可直接给 warn/info
log_level_menu() {
    command -v jq >/dev/null 2>&1 || { err "需要 jq"; return 1; }
    local cfg lvl="${1:-}" ans rc=0
    if ! has_any_config; then
        err "本机还没有 sing-box 节点配置"
        return 1
    fi
    echo "当前日志级别:"
    while IFS= read -r cfg; do
        echo "   $cfg: $(cfg_log_level "$cfg")"
    done < <(log_configs)
    if [ -z "$lvl" ]; then
        echo "1) warn（推荐：只记录警告/错误，日志很少）"
        echo "2) info（排查问题时临时使用：记录每个连接，日志很多，排查完请改回 warn）"
        read -r -p "请选择(其他键取消): " ans || ans=""
        case "$ans" in
            1) lvl=warn ;;
            2) lvl=info ;;
            *) info "已取消"; return 0 ;;
        esac
    fi
    case "$lvl" in warn|info) ;; *) err "只支持 warn 或 info"; return 1 ;; esac
    while IFS= read -r -u 3 cfg; do
        set_cfg_level "$cfg" "$lvl" || rc=1
    done 3< <(log_configs)
    if [ "$rc" -ne 0 ]; then
        err "部分配置未能修改，未保存日志级别选择"
        return "$rc"
    fi
    printf 'LOG_LEVEL=%s\n' "$lvl" > "$LOG_PREF"
    info "已记住你的选择($lvl)，以后自动升级不会再改日志级别"
    [ "$lvl" = "info" ] && warn "info 级别日志很多，排查完请在菜单里改回 warn（日志每小时自动清理，超过 50MB 只保留最后 1MB）"
    return "$rc"
}

# 本机落地机和线路机都没有了：删除清理脚本、定时任务、journald 设置
log_remove() {
    if has_any_config; then
        return 0
    fi
    rm -f "$LOG_HELPER" "$LOG_PREF" "$CRON_D"
    if [ -f "$CRON_FILE" ] && grep -q 'sb-logrotate' "$CRON_FILE" 2>/dev/null; then
        grep -v 'sb-logrotate' "$CRON_FILE" > "$CRON_FILE.sbtmp" || true
        cat "$CRON_FILE.sbtmp" > "$CRON_FILE"
        rm -f "$CRON_FILE.sbtmp"
    fi
    if [ -f "$LOG_TIMER" ]; then
        systemctl disable --now sb-logrotate.timer >/dev/null 2>&1 || true
        rm -f "$LOG_TIMER" "$LOG_TIMER_SVC"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if [ -f "$JOURNALD_DROPIN" ]; then
        rm -f "$JOURNALD_DROPIN"
        systemctl restart systemd-journald >/dev/null 2>&1 || true
    fi
    info "本机已没有 sing-box 节点，已删除日志清理脚本和定时任务"
}

check_config() {
    if command -v sing-box >/dev/null 2>&1 && ! sing-box check -c "$CONFIG"; then
        return 1
    fi
    return 0
}

backup_config() {
    BAK="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    [ -e "$BAK" ] && BAK="${BAK}-$$-$RANDOM"
    cp "$CONFIG" "$BAK"
}

# 校验新配置，通过则重启；失败则从备份还原并报错
apply_or_restore() {
    if ! check_config; then
        err "新配置校验失败(sing-box check)，已从备份还原: $BAK，运行中的服务未改动"
        cp "$BAK" "$CONFIG"
        return 1
    fi
    info "配置校验通过（修改前已备份到: $BAK），正在重启 $SVC_NAME（本机落地机节点不受影响）..."
    svc_restart || warn "重启失败，请检查: sing-box check -c $CONFIG"
    return 0
}

save_self_copy() {
    # 保存一份脚本副本，方便以后管理: bash /etc/sing-box-relay/relay-install.sh（或输入 sb）
    mkdir -p "$SB_DIR"
    if [ -f "$0" ] && [ "$(readlink -f "$0")" != "$(readlink -f "$SELF_COPY" 2>/dev/null || echo "$SELF_COPY")" ]; then
        if cp "$0" "$SELF_COPY" 2>/dev/null; then chmod 700 "$SELF_COPY" || true; fi
    fi
    write_shim
    install_shortcut
}

# 兼容旧命令: bash /etc/sing-box/relay-install.sh ... 转到新位置（只在 /etc/sing-box 目录存在时写）
write_shim() {
    [ -d "$LANDING_DIR" ] || return 0
    [ -f "$SELF_COPY" ] || return 0
    cat > "$SHIM" <<'SHIM_EOF'
#!/usr/bin/env bash
# SB_RELAY_SHIM: 线路机脚本已迁移到 /etc/sing-box-relay/relay-install.sh（独立服务 sing-box-relay）
exec bash /etc/sing-box-relay/relay-install.sh "$@"
SHIM_EOF
    chmod 700 "$SHIM" 2>/dev/null || true
}

# 本机没有 sb 时安装一个简易 sb 快捷菜单；已有完整 sb 面板(落地机脚本装的)或别的 sb 命令时绝不覆盖
# $1=force：卸载落地机后用来补回快捷菜单（仍然不会覆盖完整面板）
install_shortcut() {
    local fresh=true
    if [ -e "$SB_CMD" ] || [ -L "$SB_CMD" ]; then
        is_shortcut "$SB_CMD" || return 0
        fresh=false
    fi
    [ -f "$SELF_COPY" ] || return 0
    mkdir -p "$(dirname "$SB_CMD")"
    cat > "$SB_CMD" <<'SB_SHORTCUT'
#!/usr/bin/env bash
# SB_RELAY_SHORTCUT: 线路机脚本生成的简易 sb 快捷菜单。
# 在本机安装落地机节点后，会被完整的 sb 管理面板替换（完整面板里同样有「线路机/直连节点管理」）。
RELAY=/etc/sing-box-relay/relay-install.sh
MAIN_URL=https://raw.githubusercontent.com/demonmanch/singbox-deploy/main/install-singbox-yyds.sh
if [ "$(id -u)" != "0" ]; then echo "请以 root 运行 sb"; exit 1; fi
case "${1:-}" in
    relay) shift; exec bash "$RELAY" "$@" ;;
    logclean|loglevel|entryip|natports|argo|blocked|backup|restore) exec bash "$RELAY" "$@" ;;
esac
while true; do
    echo ""
    echo "=========================="
    echo " sb 快捷菜单（线路机）"
    echo "=========================="
    echo "1) 线路机管理(追加/查看/改名/删除中转节点、直连节点)"
    echo "2) 查看线路机所有节点链接"
    echo "3) 添加/删除直连节点(出口本机)"
    echo "4) 重启线路机服务(sing-box-relay)"
    echo "5) 查看线路机服务状态"
    echo "6) 安装落地机节点(运行落地机一键脚本，不影响线路机节点)"
    echo "7) 清理日志(立即清空 sing-box 日志)"
    echo "8) 日志级别(warn/info 切换)"
    echo "9) 入口/出口 IP(修改入口IP 只重新生成链接)"
    echo "10) NAT 映射端口(查看/修改)"
    echo "11) Argo 备用入口(Cloudflare 临时隧道)"
    echo "12) IP 被墙了？(怎么测试 + 一键开启 Argo)"
    echo "13) 备份/恢复"
    echo "0) 退出"
    echo "=========================="
    read -r -p "请输入选项: " opt || exit 0
    case "$opt" in
        1) bash "$RELAY" menu || true ;;
        2) bash "$RELAY" show || true ;;
        3) bash "$RELAY" direct || true ;;
        4) bash "$RELAY" restart || true ;;
        5) bash "$RELAY" status || true ;;
        6)
            tmp=$(mktemp /tmp/sb-install.XXXXXX) || exit 1
            if curl -fsSL "$MAIN_URL" -o "$tmp" && bash -n "$tmp"; then
                bash "$tmp"
                rc=$?
                rm -f "$tmp"
                # 安装成功后 /usr/local/bin/sb 已换成完整面板
                if [ "$rc" -eq 0 ] && [ -f /usr/local/bin/sb ] && ! head -n 3 /usr/local/bin/sb | grep -q '^# SB_RELAY_SHORTCUT'; then
                    echo "落地机节点已安装，sb 已升级为完整管理面板（里面有「线路机/直连节点管理」）"
                    exit 0
                fi
            else
                rm -f "$tmp"
                echo "下载落地机脚本失败: $MAIN_URL"
            fi
            ;;
        7) bash "$RELAY" logclean || true ;;
        8) bash "$RELAY" loglevel || true ;;
        9) bash "$RELAY" entryip || true ;;
        10) bash "$RELAY" natports || true ;;
        11) bash "$RELAY" argo || true ;;
        12) bash "$RELAY" blocked || true ;;
        13) bash "$RELAY" backupmenu || true ;;
        0) exit 0 ;;
        *) echo "无效选项: $opt" ;;
    esac
done
SB_SHORTCUT
    chmod +x "$SB_CMD"
    if [ ! -e /usr/bin/sb ] || [ -L /usr/bin/sb ]; then ln -sf "$SB_CMD" /usr/bin/sb 2>/dev/null || true; fi
    if $fresh; then info "已安装 sb 快捷菜单: 以后输入 sb 即可管理线路机节点 / 安装落地机节点"; fi
}

# 提醒放行端口；系统防火墙开着时询问是否自动放行
firewall_reminder() {
    local p ans
    echo ""
    nat_load
    if nat_on; then
        warn "NAT 模式：端口 $* 是商家映射端口；如果连不上，请到商家面板确认这些端口已映射到本机。"
        return 0
    fi
    warn "=================== ⚠️ 重要：放行端口 ==================="
    warn "请在云厂商安全组放行端口(TCP): $*  ，否则节点连不上！"
    echo "   Oracle 甲骨文云: 控制台 → 网络(Networking) → 虚拟云网络(Virtual Cloud Networks)"
    echo "   → 点你的 VCN → 安全列表(Security Lists) → Default Security List → 添加入站规则(Add Ingress Rules)"
    echo "   源 CIDR 填 0.0.0.0/0，IP 协议选 TCP，目标端口范围填上面的端口号 → 保存"
    for p in "$@"; do
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
            read -r -p "检测到系统防火墙 ufw 已开启，是否自动放行 ${p}/tcp?(Y/n): " ans || ans=n
            [[ "$ans" =~ ^[Nn]$ ]] || ufw allow "${p}/tcp" || true
        elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
            read -r -p "检测到系统防火墙 firewalld 已开启，是否自动放行 ${p}/tcp?(Y/n): " ans || ans=n
            if [[ ! "$ans" =~ ^[Nn]$ ]]; then
                if firewall-cmd --permanent --add-port="${p}/tcp"; then firewall-cmd --reload || true; fi
            fi
        elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT' \
            && ! iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
            read -r -p "检测到系统 iptables 有拦截规则(Oracle 的 Ubuntu 镜像默认如此)，是否自动放行 ${p}/tcp?(Y/n): " ans || ans=n
            if [[ ! "$ans" =~ ^[Nn]$ ]]; then
                iptables -I INPUT -p tcp --dport "$p" -j ACCEPT || true
                if command -v netfilter-persistent >/dev/null 2>&1; then
                    netfilter-persistent save >/dev/null 2>&1 || true
                else
                    warn "iptables 规则重启后可能失效；如需永久生效请安装 iptables-persistent"
                fi
            fi
        fi
    done
    warn "========================================================"
}

# 本机现有的 Reality 设置（新节点复用同一套密钥/SNI/short_id，链接里的 pbk/sid 与 relay.env 一致）
REALITY_TLS_JQ='([(.inbounds // [])[] | select(.type=="vless" and (.tls.reality.enabled // false))] | sort_by(if .tag=="vless-direct-in" then 1 else 0 end) | .[0].tls)'

# 向 config.json 加入直连 inbound（复用中转节点的 Reality 密钥/SNI/short_id）和路由规则
apply_direct_config() {
    local tmp="${CONFIG}.tmp"
    jq --argjson port "$DIRECT_PORT" --arg uuid "$DIRECT_UUID" "
      $REALITY_TLS_JQ as \$tls
      | if \$tls == null then error(\"本机配置里没有 Reality 入站\") else . end
      | .inbounds = ([(.inbounds // [])[] | select(.tag != \"vless-direct-in\")] + [{
          \"type\": \"vless\",
          \"listen\": \"::\",
          \"listen_port\": \$port,
          \"users\": [{ \"uuid\": \$uuid, \"flow\": \"xtls-rprx-vision\" }],
          \"tls\": \$tls,
          \"tag\": \"vless-direct-in\"
        }])
      | .outbounds = ((.outbounds // []) | if any(.[]; .tag==\"direct-out\") then . else . + [{\"type\":\"direct\",\"tag\":\"direct-out\"}] end)
      | .route.rules = ([(.route.rules // [])[] | select(.inbound != \"vless-direct-in\")] + [{ \"inbound\": \"vless-direct-in\", \"outbound\": \"direct-out\" }])
    " "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

remove_direct_config() {
    local tmp="${CONFIG}.tmp"
    jq '
      .inbounds = [(.inbounds // [])[] | select(.tag != "vless-direct-in")]
      | .route.rules = [(.route.rules // [])[] | select(.inbound != "vless-direct-in")]
    ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

# 询问直连节点端口/名称（结果写入 DIRECT_* 变量）：$1=需避开的端口 $2=strict
ask_direct() {
    ask_port "请输入直连节点监听端口(回车随机 20000-65000，不能与中转端口相同): " "${1:-}" "${2:-}" || return 1
    DIRECT_PORT="$ASKED_PORT"
    DIRECT_UUID=$(new_uuid)
    local def="直连-$PUB_IP" n
    read -r -p "请输入直连节点名称/备注(回车默认「$def」): " n || true
    DIRECT_NAME="${n:-$def}"
    DIRECT_ENABLED=true
}

# 添加/删除直连节点（会修改 config.json 并重启 sing-box-relay，修改前自动备份）
# 本机还没有线路机节点时：只装一个直连节点（落地机上也可以用，独立服务，不影响落地机节点）
manage_direct() {
    if [ ! -f "$RELAY_ENV" ]; then
        info "本机还没有线路机(中转/直连)节点，将新建一个直连节点：VLESS Reality，出口为本机"
        info "它使用独立的目录 $SB_DIR 和服务 $SVC_NAME，不会改动本机已有的落地机节点"
        fresh_install direct
        return $?
    fi
    load_env || return 1
    need_tools || return 1
    local ans
    if [ "$DIRECT_ENABLED" = "true" ]; then
        echo "当前已有直连节点(出口本机)，端口: $DIRECT_PORT，名称: $DIRECT_NAME"
        read -r -p "是否删除该直连节点?(y/N): " ans || ans=n
        [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return 0; }
        if [ "${#RECORDS[@]}" -eq 0 ]; then
            err "直连节点是本机线路机服务里唯一的节点，不能单独删除。如需全部删除，请在线路机菜单选「卸载线路机节点」。"
            return 1
        fi
        backup_config
        remove_direct_config
        apply_or_restore || return 1
        DIRECT_ENABLED=false; DIRECT_PORT=""; DIRECT_UUID=""; DIRECT_NAME=""
    else
        ask_direct "" strict || return 1
        backup_config
        if ! apply_direct_config; then
            err "写入直连节点失败，已还原: $BAK"
            cp "$BAK" "$CONFIG"
            return 1
        fi
        apply_or_restore || return 1
    fi
    save_env
    build_links
    save_self_copy
    show_link
    if [ "$DIRECT_ENABLED" = "true" ]; then
        firewall_reminder "$DIRECT_PORT"
    fi
    return 0
}

find_dup() {
    DUP_FILE=""
    landing_valid || return 1
    local f s
    s=$(lower "$LANDING_SERVER")
    for f in ${RECORDS[@]+"${RECORDS[@]}"}; do
        load_record "$f"
        if [ "$(lower "$R_SERVER")" = "$s" ] && [ "$R_SERVER_PORT" = "$LANDING_PORT" ]; then
            DUP_FILE="$f"
            return 0
        fi
    done
    return 1
}

need_tools() {
    command -v jq >/dev/null 2>&1 || { err "未找到 jq，请先安装: apk add jq 或 apt-get install -y jq"; return 1; }
    command -v sing-box >/dev/null 2>&1 || { err "未找到 sing-box，请选择「全部重新安装」"; return 1; }
    [ -f "$CONFIG" ] || { err "未找到 $CONFIG，请选择「全部重新安装」"; return 1; }
}

# 已存在的落地机：用本脚本里的新 SS 密码/加密方式原地更新
update_dup() {
    load_record "$DUP_FILE"
    local ans idx="$R_IDX" pos=0 i=0 f
    for f in ${RECORDS[@]+"${RECORDS[@]}"}; do i=$((i + 1)); [ "$f" = "$DUP_FILE" ] && pos=$i; done
    echo ""
    warn "这台落地机 ${LANDING_SERVER}:${LANDING_PORT} 已经添加过了：中转节点 $pos「$R_NAME」(线路机端口 $R_PORT)，不会重复添加。"
    if [ "$R_METHOD" = "$LANDING_METHOD" ] && [ "$R_PASSWORD" = "$LANDING_PASSWORD" ]; then
        info "SS 加密方式和密码也都一样，无需修改。下面是现有链接："
        show_link
        return 0
    fi
    echo "   落地机的 SS 参数有变化: 加密方式 ${R_METHOD:-未知} → $LANDING_METHOD，密码也将更新为本次脚本里的值"
    read -r -p "是否更新该节点的 SS 密码/加密方式?(链接不变，Y/n): " ans || ans=n
    [[ "$ans" =~ ^[Nn]$ ]] && { info "已取消"; return 0; }
    backup_config
    if ! jq --arg t "$R_OUT_TAG" --arg m "$LANDING_METHOD" --arg p "$LANDING_PASSWORD" \
        '.outbounds = [(.outbounds // [])[] | if .tag == $t then (.method = $m | .password = $p) else . end]' \
        "$CONFIG" > "${CONFIG}.tmp"; then
        rm -f "${CONFIG}.tmp"; err "修改失败，配置未改动"; return 1
    fi
    mv "${CONFIG}.tmp" "$CONFIG"
    apply_or_restore || return 1
    R_IDX="$idx"; R_METHOD="$LANDING_METHOD"; R_PASSWORD="$LANDING_PASSWORD"
    save_record
    save_self_copy
    info "✅ 已更新中转节点 $pos 的 SS 参数，客户端链接不变，无需重新导入"
    return 0
}

# 追加本脚本对应的落地机为新的中转节点（不动已有的入站/出站/直连节点）
append_node() {
    load_env || return 1
    need_tools || return 1
    if ! landing_valid; then
        err "本脚本里没有有效的落地机参数（是线路机上保存的副本？）。请到【新落地机】上运行 sb → 生成线路机脚本，再把新脚本拿到本机运行。"
        return 1
    fi
    list_records
    if find_dup; then
        update_dup
        return $?
    fi
    if [ -z "$(jq -r "$REALITY_TLS_JQ | .reality.private_key // empty" "$CONFIG")" ]; then
        err "$CONFIG 里没有 Reality 入站，无法追加。请选择「全部重新安装」"
        return 1
    fi

    # 新编号 = 现有最大编号 + 1；tag 与配置里已有的不冲突
    local max=0 f idx in_tag out_tag def name ans
    for f in ${RECORDS[@]+"${RECORDS[@]}"}; do
        load_record "$f"
        [[ "$R_IDX" =~ ^[0-9]+$ ]] && [ "$R_IDX" -gt "$max" ] && max="$R_IDX"
    done
    idx=$((max + 1))
    while true; do
        if [ "$idx" -eq 1 ]; then in_tag="vless-in"; out_tag="relay-out"; else in_tag="vless-in-$idx"; out_tag="relay-out-$idx"; fi
        if [ ! -f "$RELAY_DIR/$idx.env" ] && ! jq -e --arg a "$in_tag" --arg b "$out_tag" \
            'any((.inbounds // [])[]; .tag == $a) or any((.outbounds // [])[]; .tag == $b)' "$CONFIG" >/dev/null; then
            break
        fi
        idx=$((idx + 1))
    done

    echo ""
    info "=== 追加新的中转节点：线路机 → 落地机 ${LANDING_SERVER}:${LANDING_PORT} ==="
    echo "   已有节点不受影响（端口/UUID/链接都不变）。"
    ask_port "请输入新中转节点的监听端口(回车随机 20000-65000，不能和已有节点相同): " "" strict || return 1
    R_PORT="$ASKED_PORT"
    def="中转-落地${LANDING_SERVER}"
    read -r -p "请输入新中转节点名称/备注(回车默认「$def」): " name || true
    R_NAME="${name:-$def}"
    R_IDX="$idx"
    R_UUID=$(new_uuid)
    R_SERVER="$LANDING_SERVER"
    R_SERVER_PORT="$LANDING_PORT"
    R_METHOD="$LANDING_METHOD"
    R_PASSWORD="$LANDING_PASSWORD"
    R_IN_TAG="$in_tag"
    R_OUT_TAG="$out_tag"

    echo ""
    echo "   新节点: 名称「$R_NAME」，线路机端口 $R_PORT，落地机 ${R_SERVER}:${R_SERVER_PORT} ($R_METHOD)"
    read -r -p "确认追加?(Y/n): " ans || ans=n
    [[ "$ans" =~ ^[Nn]$ ]] && { info "已取消"; return 0; }

    backup_config
    if ! jq --argjson port "$R_PORT" --arg uuid "$R_UUID" --arg itag "$R_IN_TAG" --arg otag "$R_OUT_TAG" \
        --arg server "$R_SERVER" --argjson sport "$R_SERVER_PORT" --arg method "$R_METHOD" --arg pw "$R_PASSWORD" "
      $REALITY_TLS_JQ as \$tls
      | .inbounds = ((.inbounds // []) + [{
          \"type\": \"vless\",
          \"listen\": \"::\",
          \"listen_port\": \$port,
          \"users\": [{ \"uuid\": \$uuid, \"flow\": \"xtls-rprx-vision\" }],
          \"tls\": \$tls,
          \"tag\": \$itag
        }])
      | .outbounds = ((.outbounds // []) + [{
          \"type\": \"shadowsocks\",
          \"server\": \$server,
          \"server_port\": \$sport,
          \"method\": \$method,
          \"password\": \$pw,
          \"tag\": \$otag
        }])
      | .route.rules = ((.route.rules // []) + [{ \"inbound\": \$itag, \"outbound\": \$otag }])
    " "$CONFIG" > "${CONFIG}.tmp"; then
        rm -f "${CONFIG}.tmp"
        err "生成新配置失败，配置未改动"
        return 1
    fi
    mv "${CONFIG}.tmp" "$CONFIG"
    apply_or_restore || return 1

    save_record
    save_env
    build_links
    save_self_copy
    echo ""
    info "✅ 已追加中转节点「$R_NAME」（线路机端口 $R_PORT → 落地机 ${R_SERVER}:${R_SERVER_PORT}）"
    show_link
    echo ""
    info "👉 新节点的链接是上面「名称: $R_NAME」下面那一行，复制到小火箭(Shadowrocket)导入即可；旧节点不用动。"
    firewall_reminder "$R_PORT"
    return 0
}

# 删除某个中转节点（至少保留一个）
# 删除某个中转节点（线路机服务里至少保留一个节点）
delete_node() {
    load_env || return 1
    need_tools || return 1
    local ans pos del_port
    if [ "${#RECORDS[@]}" -eq 0 ]; then
        err "本机没有中转节点"
        return 1
    fi
    if [ "${#RECORDS[@]}" -le 1 ] && [ "$DIRECT_ENABLED" != "true" ]; then
        err "本机只有 1 个中转节点，不能删除最后一个。如需全部删除，请选择「卸载线路机节点」；如需重来，请选择「全部重新安装」。"
        return 1
    fi
    echo "要删除哪个中转节点?"
    choose_record "请输入编号(其他键取消): " || { info "已取消"; return 0; }
    load_record "$CHOSEN"
    pos="$R_NAME"
    del_port="$R_PORT"
    warn "将删除中转节点「$pos」(线路机端口 $R_PORT → 落地机 ${R_SERVER:-未知}:${R_SERVER_PORT:-?})，它的链接会失效。"
    read -r -p "确认删除?(y/N): " ans || ans=n
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return 0; }
    backup_config
    if ! jq --arg itag "$R_IN_TAG" --arg otag "$R_OUT_TAG" '
      .inbounds = [(.inbounds // [])[] | select(.tag != $itag)]
      | .outbounds = [(.outbounds // [])[] | select(.tag != $otag)]
      | .route.rules = [(.route.rules // [])[] | select(.inbound != $itag and .outbound != $otag)]
    ' "$CONFIG" > "${CONFIG}.tmp"; then
        rm -f "${CONFIG}.tmp"; err "修改失败，配置未改动"; return 1
    fi
    mv "${CONFIG}.tmp" "$CONFIG"
    # Argo 备用入口的出口正是被删的这台落地机时，改为本机直连出口
    if argo_enabled && [ "$ARGO_HOST" = "relay" ] && [ "$ARGO_EXIT" = "$R_OUT_TAG" ]; then
        ARGO_EXIT="direct-out"
        argo_cfg_add "$CONFIG" && argo_save
        warn "Argo 备用入口原来从「$pos」出去，已改为本机(线路机)直连出口（Argo 链接不变）"
    fi
    apply_or_restore || return 1
    rm -f "$CHOSEN"
    save_env
    build_links
    save_self_copy
    info "✅ 已删除中转节点「$pos」。可以顺手到 Oracle 安全列表里删掉端口 $del_port 的放行规则（可选）。"
    show_link
}

# 「全部重新安装」前的确认
confirm_overwrite() {
    local ans
    echo ""
    warn "⚠️ 全部重新安装：会删除本机【所有】线路机中转节点和直连节点，只为本次这台落地机(${LANDING_SERVER}:${LANDING_PORT})新建 1 个节点！"
    warn "   所有旧的线路机链接都会失效，需要重新导入。旧配置会自动备份(config.json.bak.时间戳)。本机落地机节点不受影响。"
    warn "   如果只是想再加一台落地机，请不要选这个，而是选「追加」。"
    read -r -p "确定要全部重新安装吗? 请输入 yes 确认(其他任意键取消): " ans || ans=""
    [ "$ans" = "yes" ]
}

# ===== 旧版布局迁移：线路机节点原来放在 /etc/sing-box（与落地机共用 sing-box 服务）=====
# 中转入站 = 路由规则里出站为 relay-out* 的入站，再加直连入站 vless-direct-in
RELAY_TAGS_JQ='[ ((.route.rules // [])[] | select((.outbound // "") | tostring | startswith("relay-out")) | (.inbound // empty) | if type == "array" then .[] else . end), "vless-direct-in" ] | unique'

# 配置里是否有线路机节点（relay-out* 出站或直连入站）
cfg_has_relay() {
    [ -f "$1" ] && jq -e 'any((.outbounds // [])[]; (.tag // "") | startswith("relay-out")) or any((.inbounds // [])[]; .tag == "vless-direct-in")' "$1" >/dev/null 2>&1
}

need_migrate() { [ -f "$OLD_ENV" ] && [ ! -f "$RELAY_ENV" ]; }

# 把 /etc/sing-box 里的线路机相关文件挪到备份目录（不删除）
move_old_relay_files() {
    local dest="$1" f
    mkdir -p "$dest"
    chmod 700 "$dest" 2>/dev/null || true
    for f in "$OLD_ENV" "$OLD_RELAY_DIR" "$LANDING_DIR/relay_uri.txt" "$LANDING_DIR/relay_uri.txt.tmp"; do
        [ -e "$f" ] && mv "$f" "$dest/" 2>/dev/null || true
    done
    # 旧的脚本副本（不是新版转发小脚本时）
    if [ -f "$SHIM" ] && ! is_shim "$SHIM"; then
        mv "$SHIM" "$dest/relay-install.sh.old" 2>/dev/null || true
    fi
}

# 等待服务启动并检查
wait_active() {
    local i
    for i in 1 2 3 4 5; do
        "$@" && return 0
        sleep 1
    done
    return 1
}

relay_active() { svc_active; }
landing_active() { landing_svc active; }

# 旧配置被落地机脚本覆盖、线路机记录还在时：从 config.json.bak.* 里找最新一份含线路机节点的配置
find_relay_backup() {
    local f
    for f in $(ls -1t "$LANDING_DIR"/config.json.bak* 2>/dev/null || true); do
        cfg_has_relay "$f" && { printf '%s' "$f"; return 0; }
    done
    return 1
}

migrate_layout() {
    command -v jq >/dev/null 2>&1 || { err "迁移需要 jq，请先安装: apk add jq 或 apt-get install -y jq"; return 1; }
    local ts tags n_land src="$LANDING_CONFIG" bk ans p kind f
    ts=$(date +%Y%m%d%H%M%S)
    kind=$(svc_kind)
    echo ""
    info "=== 检测到旧版线路机（节点在 $LANDING_DIR，和落地机共用 sing-box 服务）==="
    info "正在迁移到独立目录 $SB_DIR + 独立服务 $SVC_NAME："
    info "端口、UUID、Reality 密钥、short_id、SNI、节点名称全部不变，客户端里已有的链接继续有效。"

    if ! cfg_has_relay "$LANDING_CONFIG"; then
        warn "$LANDING_DIR 里有线路机记录(relay.env)，但 $LANDING_CONFIG 里已经没有线路机节点（可能被落地机脚本覆盖了）。"
        if bk=$(find_relay_backup); then
            echo "   找到含线路机节点的旧配置备份: $bk"
            read -r -p "是否用这份备份恢复线路机节点(放到独立服务 $SVC_NAME，不影响落地机节点)?(y/N): " ans || ans=n
            if [[ "$ans" =~ ^[Yy]$ ]]; then
                src="$bk"
            fi
        fi
        if [ "$src" = "$LANDING_CONFIG" ]; then
            move_old_relay_files "$LANDING_DIR/relay-stale-backup.$ts"
            warn "已把过期的线路机记录挪到 $LANDING_DIR/relay-stale-backup.$ts（落地机节点未改动）"
            return 0
        fi
    fi

    tags=$(jq -c "$RELAY_TAGS_JQ" "$src") || { err "读取 $src 失败，未做任何修改"; return 1; }
    n_land=$(jq --argjson tags "$tags" '[(.inbounds // [])[] | select((.tag // "") as $t | ($tags | index($t)) == null)] | length' "$src")
    [ "$src" != "$LANDING_CONFIG" ] && n_land=0

    rm -rf "${SB_DIR}.migrating"
    mkdir -p "${SB_DIR}.migrating"
    chmod 700 "${SB_DIR}.migrating"
    if [ "$n_land" -eq 0 ]; then
        # 纯线路机：原样复制配置，保证完全不变
        cp "$src" "${SB_DIR}.migrating/config.json"
    else
        info "本机 $LANDING_CONFIG 里同时有落地机节点($n_land 个入站)，只把线路机节点拆分出去"
        jq --argjson tags "$tags" '
          .inbounds = [(.inbounds // [])[] | select((.tag // "") as $t | ($tags | index($t)) != null)]
          | .outbounds = [(.outbounds // [])[] | select(((.tag // "") | startswith("relay-out")) or .tag == "direct-out")]
          | (if any(.outbounds[]; .tag == "direct-out") then . else .outbounds += [{"type":"direct","tag":"direct-out"}] end)
          | .route = ((.route // {}) | .rules = [(.rules // [])[] | select(((.inbound // "") | if type == "array" then .[0] else . end) as $i | ($tags | index($i)) != null)])
        ' "$src" > "${SB_DIR}.migrating/config.json"
        jq --argjson tags "$tags" '
          .inbounds = [(.inbounds // [])[] | select((.tag // "") as $t | ($tags | index($t)) == null)]
          | .outbounds = [(.outbounds // [])[] | select(((.tag // "") | startswith("relay-out")) | not)]
          | .route = ((.route // {}) | .rules = [(.rules // [])[] | select(((.inbound // "") | if type == "array" then .[0] else . end) as $i | ($tags | index($i)) == null)])
        ' "$src" > "${SB_DIR}.migrating/landing.json"
        if command -v sing-box >/dev/null 2>&1 && ! sing-box check -c "${SB_DIR}.migrating/landing.json"; then
            err "拆分后的落地机配置校验失败，未做任何修改"
            rm -rf "${SB_DIR}.migrating"
            return 1
        fi
    fi
    if command -v sing-box >/dev/null 2>&1 && ! sing-box check -c "${SB_DIR}.migrating/config.json"; then
        err "迁移后的线路机配置校验失败，未做任何修改"
        rm -rf "${SB_DIR}.migrating"
        return 1
    fi
    if [ "$src" != "$LANDING_CONFIG" ]; then
        # 从备份恢复：端口不能和现在的落地机节点冲突
        for p in $(jq -r '(.inbounds // [])[].listen_port // empty' "${SB_DIR}.migrating/config.json"); do
            if landing_port "$p"; then
                err "备份里的线路机端口 $p 已被现在的落地机节点使用，无法恢复。未做任何修改"
                rm -rf "${SB_DIR}.migrating"
                return 1
            fi
        done
    fi
    for f in "$OLD_ENV" "$LANDING_DIR/relay_uri.txt"; do
        [ -f "$f" ] && cp -p "$f" "${SB_DIR}.migrating/"
    done
    [ -d "$OLD_RELAY_DIR" ] && cp -a "$OLD_RELAY_DIR" "${SB_DIR}.migrating/relays"

    # 已有 /etc/sing-box-relay 且里面有配置/节点记录（之前失败的残留等）先整体挪开；只有脚本副本时直接合并
    if [ -e "$SB_DIR/config.json" ] || [ -e "$SB_DIR/relays" ]; then
        mv "$SB_DIR" "${SB_DIR}.old.$ts"
    fi
    if [ -d "$SB_DIR" ]; then
        cp -a "${SB_DIR}.migrating/." "$SB_DIR/"
        rm -rf "${SB_DIR}.migrating"
    else
        mv "${SB_DIR}.migrating" "$SB_DIR"
    fi
    install_service || { mv "$SB_DIR" "${SB_DIR}.failed.$ts"; err "创建 $SVC_NAME 服务失败，未做任何修改"; return 1; }

    local landing_bak="${LANDING_CONFIG}.bak.premigrate.$ts"
    if [ "$src" = "$LANDING_CONFIG" ]; then
        cp -p "$LANDING_CONFIG" "$landing_bak"
        # 先停旧服务释放端口，再启动新服务（中断约几秒）
        landing_svc stop >/dev/null 2>&1 || true
        if [ "$n_land" -gt 0 ]; then
            mv "$SB_DIR/landing.json" "$LANDING_CONFIG"
        fi
    fi
    rm -f "$SB_DIR/landing.json"

    local ok=true
    svc_restart >/dev/null 2>&1 || ok=false
    $ok && { wait_active relay_active || ok=false; }
    if $ok && [ "$src" = "$LANDING_CONFIG" ] && [ "$n_land" -gt 0 ]; then
        landing_svc restart >/dev/null 2>&1 || ok=false
        $ok && { wait_active landing_active || ok=false; }
    fi
    if ! $ok; then
        err "新服务 $SVC_NAME 启动失败，正在还原为迁移前的状态..."
        svc_status
        remove_service
        mv "$SB_DIR" "${SB_DIR}.failed.$ts"
        if [ "$src" = "$LANDING_CONFIG" ]; then
            cp -p "$landing_bak" "$LANDING_CONFIG"
            landing_svc restart >/dev/null 2>&1 || landing_svc start >/dev/null 2>&1 || true
        fi
        err "已还原，线路机节点仍由原来的 sing-box 服务运行。失败的文件保存在 ${SB_DIR}.failed.$ts"
        return 1
    fi

    if [ "$src" = "$LANDING_CONFIG" ] && [ "$n_land" -eq 0 ]; then
        # 纯线路机：原来的 sing-box 服务只跑线路机节点，迁移后关闭它；旧配置改名保留
        landing_svc disable
        mv "$LANDING_CONFIG" "$SB_DIR/migrated-config.json.$ts" 2>/dev/null || true
        rm -f "$landing_bak"
        local b
        for b in "$LANDING_DIR"/config.json.bak.*; do
            [ -f "$b" ] || continue
            mkdir -p "$SB_DIR/old-backups"
            mv "$b" "$SB_DIR/old-backups/" 2>/dev/null || true
        done
    fi
    move_old_relay_files "$SB_DIR/migrated-from-etc-sing-box.$ts"
    save_self_copy
    # /root/relay-install.sh 是旧版脚本时：备份后换成转发小脚本，免得以后误运行旧版另装一套
    if [ -f /root/relay-install.sh ] && ! grep -q 'SVC_NAME="sing-box-relay"' /root/relay-install.sh 2>/dev/null \
        && ! is_shim /root/relay-install.sh && [ -f "$SHIM" ]; then
        mv /root/relay-install.sh "/root/relay-install.sh.old.$ts" && cp "$SHIM" /root/relay-install.sh \
            && info "   旧版 /root/relay-install.sh 已备份为 /root/relay-install.sh.old.$ts，现在运行它会自动转到新脚本"
    fi
    info "✅ 迁移完成：线路机节点现在由独立服务 $SVC_NAME 运行（配置 $CONFIG）"
    [ "$kind" = "openrc" ] && info "   管理: rc-service $SVC_NAME status|restart   日志: /var/log/$SVC_NAME.log"
    [ "$kind" = "systemd" ] && info "   管理: systemctl status|restart $SVC_NAME   日志: journalctl -u $SVC_NAME"
    if [ "$n_land" -eq 0 ] && [ "$src" = "$LANDING_CONFIG" ]; then
        info "   原来的 sing-box 服务已停用（它只跑线路机节点）。以后可以在本机用落地机脚本安装落地机节点，二者互不覆盖。"
    fi
    return 0
}

maybe_migrate() {
    need_migrate || return 0
    migrate_layout
}

# 更新本机线路机脚本副本 + 迁移旧版布局 + 服务文件/快捷命令（不改节点）
do_upgrade() {
    if [ ! -f "$RELAY_ENV" ]; then
        info "本机没有线路机节点，无需升级。（在本机添加直连节点: 运行本脚本并加参数 direct，或输入 sb）"
        return 0
    fi
    load_env || return 1
    mkdir -p "$SB_DIR"
    save_self_copy
    if ! service_installed; then install_service || true; else refresh_service; fi
    if ! svc_active; then svc_restart || warn "启动 $SVC_NAME 失败，请运行: bash $SELF_COPY status"; fi
    info "✅ 线路机脚本已更新到 $SELF_COPY（节点、端口、链接都没有改动）"
    echo "   以后管理: 输入 sb（或 bash $SELF_COPY）"
    show_link
}

# 卸载线路机节点（只删 sing-box-relay，不动落地机节点）
uninstall_relay() {
    local ans
    if [ ! -d "$SB_DIR" ] && ! service_installed; then
        info "本机没有安装线路机节点"
        return 0
    fi
    warn "将删除本机【所有】线路机中转节点和直连节点（服务 $SVC_NAME、目录 $SB_DIR），它们的链接会失效。"
    warn "本机的落地机节点($LANDING_CONFIG、sing-box 服务)不受影响。"
    read -r -p "确认卸载线路机节点?(y/N): " ans || ans=n
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return 0; }
    argo_on_relay_uninstall || true
    remove_service
    rm -rf "$SB_DIR"
    rm -f "/var/log/${SVC_NAME}.log" "/var/log/${SVC_NAME}.err"
    if is_shim "$SHIM"; then rm -f "$SHIM"; fi
    if is_shortcut "$SB_CMD"; then
        rm -f "$SB_CMD"
        if [ -L /usr/bin/sb ] && [ ! -e /usr/bin/sb ]; then rm -f /usr/bin/sb; fi
    fi
    info "✅ 线路机节点已卸载"
    log_remove
    if [ ! -f "$LANDING_CONFIG" ]; then
        rm -f "$NAT_CONF"
        info "本机也没有落地机节点；sing-box 程序保留在 $(singbox_bin)，不需要可自行删除"
    fi
}

# 安装/管理本机的落地机节点：已有完整 sb 面板就打开它，否则下载落地机一键脚本运行
open_landing() {
    if [ -f "$SB_CMD" ] && ! is_shortcut "$SB_CMD" && [ -f "$LANDING_CONFIG" ]; then
        exec bash "$SB_CMD"
    fi
    info "将下载并运行落地机一键脚本（安装落地机节点到 $LANDING_DIR，不影响本机线路机节点）"
    local tmp rc=0
    tmp=$(mktemp /tmp/sb-install.XXXXXX)
    if curl -fsSL "$MAIN_URL" -o "$tmp" && bash -n "$tmp"; then
        bash "$tmp" || rc=$?
    else
        err "下载落地机脚本失败: $MAIN_URL"
        rc=1
    fi
    rm -f "$tmp"
    return "$rc"
}

relay_menu() {
    load_env || return 1
    local choice
    echo ""
    echo "==================== 线路机管理 ===================="
    echo "本机线路机现有 ${#RECORDS[@]} 个中转节点（服务 $SVC_NAME，配置 $CONFIG）:"
    print_records
    [ "$DIRECT_ENABLED" = "true" ] && echo "   另有直连节点(出口本机): $DIRECT_NAME | 端口 $DIRECT_PORT"
    if landing_valid; then
        echo "本次脚本对应的落地机: ${LANDING_SERVER}:${LANDING_PORT}"
        echo "----------------------------------------------------"
        if find_dup; then
            echo "1) 这台落地机已添加过 → 检查/更新它的 SS 密码(不会重复添加)"
        else
            echo "1) 追加这台落地机为新的中转节点（推荐，已有节点不受影响）"
        fi
    else
        echo "----------------------------------------------------"
        echo "1) 追加新的落地机（需用新落地机 sb 生成的脚本，本副本无落地机参数）"
    fi
    echo "2) 查看所有节点链接"
    echo "3) 修改节点名称"
    echo "4) 删除某个中转节点"
    echo "5) 添加/删除直连节点(出口本机)"
    echo "6) 重启线路机服务 / 查看状态"
    echo "7) 安装/管理本机的落地机节点(sb 完整面板)"
    echo "8) 卸载线路机节点(不影响落地机节点)"
    echo "9) ⚠️ 全部重新安装（删除所有线路机节点，旧链接全部失效）"
    echo "10) 清理日志(立即清空 sing-box 日志)"
    echo "11) 日志级别(warn/info 切换，排查问题时临时用 info)"
    echo "12) 入口/出口 IP(查看；修改入口IP 只重新生成链接)"
    echo "13) NAT 映射端口(查看/修改商家映射端口，新节点自动从中选)"
    echo "14) Argo 备用入口(Cloudflare 临时隧道，不占映射端口)"
    echo "15) IP 被墙了？(怎么从国内测试 + 一键开启 Argo 备用入口)"
    echo "16) 备份/恢复(节点配置和密钥打包到 /root，换机/重装后一键恢复)"
    echo "0) 退出"
    echo "===================================================="
    read -r -p "请选择(直接回车 = 1): " choice || choice=0
    case "${choice:-1}" in
        1) append_node; return $? ;;
        2) show_link; return $? ;;
        3) rename_node; return $? ;;
        4) delete_node; return $? ;;
        5) manage_direct; return $? ;;
        6) svc_restart && info "已重启 $SVC_NAME"; svc_status; tcp_hint || true; return 0 ;;
        7) open_landing; return $? ;;
        8) uninstall_relay; return $? ;;
        10) log_clean_now; return 0 ;;
        11) log_level_menu; return $? ;;
        12) entry_ip_menu; return $? ;;
        13) nat_menu; return 0 ;;
        14) argo_menu; return 0 ;;
        15) blocked_guide; return 0 ;;
        16) backup_menu; return 0 ;;
        9)
            if ! landing_valid; then
                err "本脚本里没有有效的落地机参数。请在落地机上运行 sb → 生成线路机脚本，再用新脚本重新安装。"
                return 1
            fi
            confirm_overwrite || { info "已取消"; return 0; }
            fresh_install relay
            return $?
            ;;
        *) return 0 ;;
    esac
}

usage() {
    echo "用法: bash $SELF_COPY [命令]"
    echo "  (无参数)/menu  线路机管理菜单"
    echo "  append    追加本脚本对应的落地机为中转节点"
    echo "  show      查看所有节点链接"
    echo "  rename    修改节点名称"
    echo "  delete    删除某个中转节点"
    echo "  direct    添加/删除直连节点(本机没有线路机节点时新建一个直连节点)"
    echo "  restart / status   重启 / 查看线路机服务 $SVC_NAME"
    echo "  upgrade   迁移旧版布局并更新脚本副本(不改节点)"
    echo "  landing   安装/管理本机的落地机节点"
    echo "  uninstall 卸载线路机节点(不影响落地机节点)"
    echo "  logclean  立即清空 sing-box 日志"
    echo "  loglevel [warn|info]  切换日志级别(落地机和线路机配置都会改)"
    echo "  entryip [IP]  查看出口IP / 修改入口IP(只重新生成链接)"
    echo "  natports  查看/修改 NAT 映射端口"
    echo "  argo [show|restart|pref|off]  Argo 备用入口(Cloudflare 临时隧道)"
    echo "  blocked   IP 被墙了？(从国内测试的方法 + 一键开启 Argo)"
    echo "  backup    备份节点配置到 /root/sb-backup-日期-时间.tar.gz"
    echo "  restore [文件]  从备份恢复(不带文件则列出 /root 下的备份)"
    echo "  install   全部重新安装(删除所有线路机节点)"
}

# ===== 全新安装 / 全部重新安装 =====
detect_os(){
    . /etc/os-release 2>/dev/null || true
    case "${ID:-}" in
        alpine) OS=alpine ;;
        debian|ubuntu) OS=debian ;;
        centos|rhel|fedora) OS=redhat ;;
        *) OS=unknown ;;
    esac
}

# 默认 Reality SNI：本脚本里的值 > 本机落地机用的 SNI > addons.mozilla.org
default_sni() {
    local s="$RELAY_SNI"
    if [ -z "$s" ] || [[ "$s" == __*__ ]]; then
        s=$( (. "$LANDING_DIR/.config_cache" >/dev/null 2>&1; printf '%s' "${REALITY_SNI:-}") 2>/dev/null || true)
    fi
    printf '%s' "${s:-addons.mozilla.org}"
}

# $1 = relay（中转节点 + 可选直连节点）| direct（只有直连节点）
fresh_install() {
    local what="$1" ADD_DIRECT="" UUID REALITY_KEYS REALITY_PK LISTEN_PORT=0 NODE_NAME DEFAULT_NAME ip_url sni_in
    if [ "$what" = "relay" ] && ! landing_valid; then
        err "本脚本里没有有效的落地机参数。请在落地机上运行 sb → 生成线路机脚本。"
        return 1
    fi
    DIRECT_ENABLED=false; DIRECT_PORT=""; DIRECT_UUID=""; DIRECT_NAME=""
    detect_os

    if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
        info "安装依赖..."
        case "$OS" in
            alpine) apk add --no-cache curl jq bash ca-certificates ;;
            debian) apt-get update -y; apt-get install -y curl jq bash openssl ca-certificates ;;
            redhat) yum install -y curl jq bash openssl ca-certificates ;;
        esac
    fi

    if command -v sing-box >/dev/null 2>&1; then
        info "本机已安装 sing-box: $(sing-box version 2>/dev/null | head -n1)（与落地机节点共用同一个程序）"
        local have
        have=$(sb_version)
        if [ -n "$have" ] && ! ver_ge "$have" "$SB_MIN_VER"; then
            warn "sing-box $have 低于建议版本 $SB_MIN_VER，可在 sb 里选「更新 sing-box」"
        fi
    else
        check_disk
        info "安装 sing-box..."
        case "$OS" in
            alpine) install_singbox_alpine "$SB_MIN_VER" || true ;;
            *) (cd "$(mktemp -d)" && bash <(curl -fsSL https://sing-box.app/install.sh)) || true ;;
        esac
        clean_pkg_cache
        command -v sing-box >/dev/null 2>&1 && info "sing-box 版本: $(sb_version)"
    fi
    command -v sing-box >/dev/null 2>&1 || { err "sing-box 安装失败"; return 1; }

    # NAT/容器：询问是否开启 NAT 模式（只用商家映射端口）
    nat_offer

    UUID=$(new_uuid)

    info "生成 Reality 密钥对"
    REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null || echo "")
    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r' || echo "")
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r' || echo "")
    REALITY_SID=$(sing-box generate rand 8 --hex 2>/dev/null || echo "0123456789abcdef")
    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ]; then
        err "生成 Reality 密钥失败，请检查 sing-box 是否安装成功"
        return 1
    fi

    if [ "$what" = "direct" ]; then
        RELAY_SNI=$(default_sni)
        read -r -p "请输入直连节点的 Reality SNI(回车默认 $RELAY_SNI): " sni_in || sni_in=""
        sni_in=$(printf '%s' "$sni_in" | tr -d '[:space:]')
        RELAY_SNI="${sni_in:-$RELAY_SNI}"
    else
        ask_port "请输入线路机(中转节点)监听端口(留空随机 20000-65000): " "" || return 1
        LISTEN_PORT="$ASKED_PORT"
    fi

    # 入口IP：本机已保存的(NAT 入口IP / 落地机 CUSTOM_IP)优先；否则自动检测，NAT/容器/WARP 时请用户确认
    PUB_IP=$(saved_entry_ip)
    if [ -n "$PUB_IP" ]; then
        info "使用本机已保存的入口IP: $PUB_IP（链接里用它；可在 sb「入口/出口 IP」修改）"
    else
        detect_exit_ip || true
        PUB_IP="${EXIT_IP:-}"
        nat_load
        if nat_on || looks_nat || [ -n "${EXIT_WARP:-}" ] || [ -z "$PUB_IP" ]; then
            echo ""
            info "=== 本机入口IP（客户端连接用）==="
            show_exit_ip ""
            echo "   NAT 小鸡请填商家面板里的公网IP/域名（也就是 SSH 登录用的 IP），不要填出口IP。"
            while true; do
                read -r -p "请输入本机入口IP/域名${PUB_IP:+(回车使用 $PUB_IP)}: " ip_url || ip_url=""
                ip_url=$(strip_host "${ip_url:-$PUB_IP}")
                if valid_host "$ip_url"; then PUB_IP="$ip_url"; break; fi
                err "地址无效: '${ip_url}'"
            done
            ENTRY_IP="$PUB_IP"
            nat_save
        fi
    fi
    [ -z "$PUB_IP" ] && PUB_IP="YOUR_RELAY_IP"
    set_pub_ip_uri

    if [ "$what" = "direct" ]; then
        ask_direct "" || return 1
    else
        DEFAULT_NAME="中转-落地${LANDING_SERVER}"
        read -r -p "请输入中转节点名称/备注(显示在链接 # 后，回车默认「$DEFAULT_NAME」): " NODE_NAME || true
        NODE_NAME="${NODE_NAME:-$DEFAULT_NAME}"

        echo ""
        read -r -p "是否同时添加一个本机(线路机)直连出口的 VLESS Reality 节点? (y/N): " ADD_DIRECT || ADD_DIRECT=n
        if [[ "$ADD_DIRECT" =~ ^[Yy]$ ]]; then
            ask_direct "$LISTEN_PORT" || return 1
        fi
    fi

    mkdir -p "$SB_DIR"
    chmod 700 "$SB_DIR" 2>/dev/null || true

    BAK=""
    if [ -f "$CONFIG" ]; then
        BAK="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
        warn "将覆盖已有的 $CONFIG，旧配置已备份到: $BAK"
        cp "$CONFIG" "$BAK"
    fi

    if [ "$what" = "direct" ]; then
        # 只有直连节点：入站 vless-direct-in → 出站 direct-out
        jq -n \
          --argjson port "$DIRECT_PORT" \
          --arg uuid "$DIRECT_UUID" \
          --arg sni "$RELAY_SNI" \
          --arg pk "$REALITY_PK" \
          --arg sid "$REALITY_SID" '
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $port,
      "users": [{ "uuid": $uuid, "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": $sni,
        "reality": {
          "enabled": true,
          "handshake": { "server": $sni, "server_port": 443 },
          "private_key": $pk,
          "short_id": [$sid]
        }
      },
      "tag": "vless-direct-in"
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct-out" } ],
  "route": { "rules": [{ "inbound": "vless-direct-in", "outbound": "direct-out" }] }
}' > "$CONFIG"
    else
        # 用 jq 生成配置，避免密码中的特殊字符破坏 JSON
        jq -n \
          --argjson listen_port "$LISTEN_PORT" \
          --arg uuid "$UUID" \
          --arg sni "$RELAY_SNI" \
          --arg pk "$REALITY_PK" \
          --arg sid "$REALITY_SID" \
          --arg server "$LANDING_SERVER" \
          --argjson server_port "$LANDING_PORT" \
          --arg method "$LANDING_METHOD" \
          --arg password "$LANDING_PASSWORD" '
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $listen_port,
      "users": [{ "uuid": $uuid, "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": $sni,
        "reality": {
          "enabled": true,
          "handshake": { "server": $sni, "server_port": 443 },
          "private_key": $pk,
          "short_id": [$sid]
        }
      },
      "tag": "vless-in"
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "server": $server,
      "server_port": $server_port,
      "method": $method,
      "password": $password,
      "tag": "relay-out"
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": { "rules": [{ "inbound": "vless-in", "outbound": "relay-out" }] }
}' > "$CONFIG"

        if [ "$DIRECT_ENABLED" = "true" ]; then
            apply_direct_config
        fi
    fi
    # Argo 备用入口在线路机节点上时，把它的本地入站补回新配置（链接不变）
    if argo_enabled && [ "$ARGO_HOST" = "relay" ]; then
        argo_cfg_add "$CONFIG" && argo_save
    fi

    if ! check_config; then
        if [ -n "$BAK" ]; then
            cp "$BAK" "$CONFIG"
            err "sing-box 配置校验未通过，已还原旧配置: $BAK（未重启服务）"
        else
            mv "$CONFIG" "${CONFIG}.invalid"
            err "sing-box 配置校验未通过，错误的配置已保存为 ${CONFIG}.invalid"
        fi
        return 1
    fi

    install_service || true
    svc_restart || warn "启动 $SVC_NAME 失败，请运行: bash $SELF_COPY status 查看"

    # 保存参数并生成链接：旧的节点记录(如果有)挪到备份目录，新建节点 1
    if [ -d "$RELAY_DIR" ]; then
        mv "$RELAY_DIR" "${RELAY_DIR}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    if [ "$what" = "relay" ]; then
        R_IDX=1; R_UUID="$UUID"; R_PORT="$LISTEN_PORT"; R_NAME="$NODE_NAME"
        R_SERVER="$LANDING_SERVER"; R_SERVER_PORT="$LANDING_PORT"; R_METHOD="$LANDING_METHOD"; R_PASSWORD="$LANDING_PASSWORD"
        R_IN_TAG="vless-in"; R_OUT_TAG="relay-out"
        save_record
    fi
    save_env
    build_links
    save_self_copy
    log_autosetup || true

    echo ""
    info "✅ 安装完成（线路机节点使用独立服务 $SVC_NAME，不影响本机落地机节点）"
    show_link
    echo ""
    info "💡 链接已保存到: $RELAY_URI_FILE"
    info "💡 以后管理(查看/改名/删除/直连节点): 输入 sb，或 bash $SELF_COPY"
    info "💡 再加一台落地机: 在新落地机上 sb → 生成线路机脚本，把新脚本拿到本机运行，选「1) 追加」"
    if [ "$what" = "direct" ]; then
        firewall_reminder "$DIRECT_PORT"
    elif [ "$DIRECT_ENABLED" = "true" ]; then
        firewall_reminder "$LISTEN_PORT" "$DIRECT_PORT"
    else
        firewall_reminder "$LISTEN_PORT"
    fi
    tcp_hint || true
    return 0
}

# ===== Argo 备用入口：Cloudflare 临时隧道(trycloudflare) → 本机 127.0.0.1 上的 VLESS-ws 入站 =====
# 入站只监听 127.0.0.1（不占用商家映射端口）；cloudflared 用独立服务 sb-argo；状态在 /etc/sb-argo
ARGO_DIR="/etc/sb-argo"
ARGO_ENV="$ARGO_DIR/argo.env"
ARGO_URI_FILE="$ARGO_DIR/argo_uri.txt"
ARGO_LOG="/var/log/sb-argo.log"
ARGO_SVC="sb-argo"
ARGO_UNIT="/etc/systemd/system/${ARGO_SVC}.service"
ARGO_INIT="/etc/init.d/${ARGO_SVC}"
ARGO_TAG="argo-ws-in"
ARGO_BIN_DEFAULT="/usr/local/bin/cloudflared"
ARGO_DEF_PREF="www.visa.com.sg"
ARGO_WAIT="${SB_ARGO_WAIT:-25}"     # 等待隧道建立的秒数

argo_load() {
    ARGO_HOST=""; ARGO_PORT=""; ARGO_UUID=""; ARGO_PATH=""; ARGO_PREF="$ARGO_DEF_PREF"; ARGO_EXIT="direct-out"
    ARGO_NAME=""; ARGO_BIN=""; ARGO_BIN_OURS="0"; ARGO_DOMAIN=""; ARGOX_ROLLBACK=""
    [ -f "$ARGO_ENV" ] || return 1
    # shellcheck disable=SC1090
    . "$ARGO_ENV"
    return 0
}

argo_save() {
    mkdir -p "$ARGO_DIR"
    chmod 700 "$ARGO_DIR" 2>/dev/null || true
    {
        printf '# sb Argo 备用入口设置（sb → Argo 备用入口 里修改）\n'
        printf 'ARGO_HOST=%q\n' "$ARGO_HOST"
        printf 'ARGO_PORT=%q\n' "$ARGO_PORT"
        printf 'ARGO_UUID=%q\n' "$ARGO_UUID"
        printf 'ARGO_PATH=%q\n' "$ARGO_PATH"
        printf 'ARGO_PREF=%q\n' "$ARGO_PREF"
        printf 'ARGO_EXIT=%q\n' "$ARGO_EXIT"
        printf 'ARGO_NAME=%q\n' "$ARGO_NAME"
        printf 'ARGO_BIN=%q\n' "$ARGO_BIN"
        printf 'ARGO_BIN_OURS=%q\n' "$ARGO_BIN_OURS"
        printf 'ARGO_DOMAIN=%q\n' "$ARGO_DOMAIN"
        printf 'ARGOX_ROLLBACK=%q\n' "$ARGOX_ROLLBACK"
    } > "$ARGO_ENV"
    chmod 600 "$ARGO_ENV" 2>/dev/null || true
}

# Argo 入站所在的配置文件：线路机节点(sing-box-relay) 或 落地机节点(sing-box)
argo_cfg_file() { if [ "$ARGO_HOST" = "landing" ]; then printf '%s' "$LANDING_CONFIG"; else printf '%s' "$CONFIG"; fi; }
argo_host_label() { if [ "$ARGO_HOST" = "landing" ]; then printf '落地机节点(sing-box 服务)'; else printf '线路机节点(sing-box-relay 服务)'; fi; }

# 重启 Argo 入站所在的 sing-box 服务；$1=ifactive 时只在服务运行中才重启
argo_host_restart() {
    if [ "$ARGO_HOST" = "landing" ]; then
        if [ "${1:-}" = "ifactive" ] && ! landing_svc active; then return 0; fi
        landing_svc restart >/dev/null 2>&1
    else
        if [ "${1:-}" = "ifactive" ] && ! svc_active; then return 0; fi
        svc_restart >/dev/null 2>&1
    fi
}

# 把 Argo 入站和路由规则写进配置文件 $1（已有就替换）；出口没有了就改成本机直连
argo_cfg_add() {
    local f="$1" tmp
    if ! jq -e --arg t "$ARGO_EXIT" 'any((.outbounds // [])[]; .tag == $t)' "$f" >/dev/null 2>&1; then
        [ "$ARGO_EXIT" != "direct-out" ] && warn "Argo 原来的出口 $ARGO_EXIT 已不存在，改为本机直连出口"
        ARGO_EXIT="direct-out"
    fi
    tmp="${f}.argo.tmp"
    jq --argjson port "$ARGO_PORT" --arg uuid "$ARGO_UUID" --arg path "$ARGO_PATH" --arg tag "$ARGO_TAG" --arg out "$ARGO_EXIT" '
      .inbounds = ([(.inbounds // [])[] | select(.tag != $tag)] + [{
          "type": "vless",
          "tag": $tag,
          "listen": "127.0.0.1",
          "listen_port": $port,
          "users": [{ "uuid": $uuid }],
          "transport": {
            "type": "ws",
            "path": $path,
            "max_early_data": 2560,
            "early_data_header_name": "Sec-WebSocket-Protocol"
          }
        }])
      | .outbounds = ((.outbounds // []) | if any(.[]; .tag == "direct-out") then . else . + [{"type":"direct","tag":"direct-out"}] end)
      | .route = ((.route // {}) | .rules = ([(.rules // [])[] | select(.inbound != $tag)] + [{ "inbound": $tag, "outbound": $out }]))
    ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# 从配置文件 $1 删除 Argo 入站和它的路由规则（其他节点不动）
argo_cfg_del() {
    local f="$1" tmp="${1}.argo.tmp"
    [ -f "$f" ] || return 0
    jq -e --arg tag "$ARGO_TAG" 'any((.inbounds // [])[]; .tag == $tag)' "$f" >/dev/null 2>&1 || return 0
    jq --arg tag "$ARGO_TAG" '
      .inbounds = [(.inbounds // [])[] | select(.tag != $tag)]
      | if .route then .route.rules = [(.route.rules // [])[] | select(.inbound != $tag)] else . end
      | if .route == {"rules": []} then del(.route) else . end
    ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# 修改配置：$1=add|del。先备份，sing-box check 不通过就还原；通过后重启所在服务（服务没在运行就不启动）
argo_apply_cfg() {
    local f bak
    f=$(argo_cfg_file)
    [ -f "$f" ] || { err "未找到配置文件: $f"; return 1; }
    bak="${f}.bak.argo"
    cp "$f" "$bak"
    if [ "$1" = "add" ]; then argo_cfg_add "$f" || { cp "$bak" "$f"; err "写入 Argo 入站失败，配置未改动"; return 1; }
    else argo_cfg_del "$f" || { cp "$bak" "$f"; err "删除 Argo 入站失败，配置未改动"; return 1; }
    fi
    if command -v sing-box >/dev/null 2>&1 && ! sing-box check -c "$f" >/dev/null 2>&1; then
        sing-box check -c "$f" 2>&1 | tail -n 5 >&2 || true
        cp "$bak" "$f"; rm -f "$bak"
        err "配置校验失败，已还原，节点未改动"
        return 1
    fi
    if ! argo_host_restart ifactive; then
        cp "$bak" "$f"; argo_host_restart ifactive || true; rm -f "$bak"
        err "重启 $(argo_host_label) 失败，已还原配置"
        return 1
    fi
    rm -f "$bak"
    return 0
}

# 本地随机端口：避开 8080/30000/30001(ArgoX 常用)、两套节点已用端口、NAT 映射端口、本机已监听的端口
argo_port_free() {
    local p="$1"
    case "$p" in 8080|30000|30001) return 1 ;; esac
    nat_load
    in_words "$p" "$NAT_PORTS" && return 1
    cfg_has_port "$CONFIG" "$p" && return 1
    cfg_has_port "$LANDING_CONFIG" "$p" && return 1
    # 本机已在监听的 TCP 端口（如 ArgoX 的 8080/30000/30001）；ss 优先，busybox 回退 netstat
    # （先存到变量再 grep：pipefail 下 grep -q 提前退出会让管道失败）
    local addrs=""
    if command -v ss >/dev/null 2>&1; then
        addrs=$(ss -lnt 2>/dev/null | awk 'NR>1{print $4}' || true)
    elif command -v netstat >/dev/null 2>&1; then
        addrs=$(netstat -lnt 2>/dev/null | awk '{print $4}' || true)
    fi
    printf '%s\n' "$addrs" | grep -qE "[:.]$p\$" && return 1
    return 0
}
argo_pick_port() {
    local p
    for _ in $(seq 1 300); do
        p=$(shuf -i 20000-60000 -n 1 2>/dev/null || echo $((RANDOM % 40001 + 20000)))
        if argo_port_free "$p"; then printf '%s' "$p"; return 0; fi
    done
    return 1
}

argo_rand_path() {
    local s
    s=$(head -c 64 /dev/urandom 2>/dev/null | tr -dc 'a-z0-9' | head -c 12 || true)
    [ -n "$s" ] || s=$(printf '%s' "$RANDOM$RANDOM$RANDOM" | head -c 12)
    printf '/%s' "$s"
}

argo_bin_ok() { [ -n "${1:-}" ] && [ -x "$1" ] && "$1" --version >/dev/null 2>&1; }

argo_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; armv7*|armv6*|arm) echo arm ;; i?86) echo 386 ;; *) return 1 ;;
    esac
}

# 安装 cloudflared：已有能用的就直接用；Alpine 仓库有就用仓库的；否则从 GitHub 下载官方程序（先运行一次确认能用）
argo_install_bin() {
    local b avail arch
    if argo_bin_ok "$ARGO_BIN"; then return 0; fi
    b=$(command -v cloudflared 2>/dev/null || true)
    if argo_bin_ok "$b"; then
        ARGO_BIN="$b"; ARGO_BIN_OURS="0"
        info "使用本机已有的 cloudflared: $b ($("$b" --version 2>/dev/null | head -n1))"
        return 0
    fi
    avail=$( { df -Pk /usr/local 2>/dev/null || df -Pk / 2>/dev/null; } | awk 'NR==2{print $4}' || true)
    if [[ "$avail" =~ ^[0-9]+$ ]]; then
        avail=$((avail / 1024))
        if [ "$avail" -lt 60 ]; then
            err "磁盘剩余空间只有约 ${avail}MB，cloudflared 需要约 40MB，空间不够，已停止。可先清理: rm -rf /var/cache/apk/* ; apt-get clean ; 删除不用的日志/文件"
            return 1
        fi
        [ "$avail" -lt 150 ] && warn "磁盘剩余空间约 ${avail}MB，cloudflared 约占 40MB"
    fi
    if command -v apk >/dev/null 2>&1 && printf '%s\n' "$(apk --no-cache search -x cloudflared 2>/dev/null || true)" | grep -q '^cloudflared-'; then
        info "使用 Alpine 官方仓库的 cloudflared"
        if apk add --no-cache cloudflared >/dev/null 2>&1 && argo_bin_ok /usr/bin/cloudflared; then
            ARGO_BIN="/usr/bin/cloudflared"; ARGO_BIN_OURS="apk"
            return 0
        fi
        warn "从 Alpine 仓库安装 cloudflared 失败，改从 GitHub 下载"
    fi
    arch=$(argo_arch) || { err "不支持的 CPU 架构: $(uname -m)"; return 1; }
    info "从 GitHub 下载 cloudflared（官方程序 linux-${arch}，约 40MB）..."
    mkdir -p "$(dirname "$ARGO_BIN_DEFAULT")"
    if curl -fsSL --max-time 300 -o "${ARGO_BIN_DEFAULT}.new" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" \
        && chmod 755 "${ARGO_BIN_DEFAULT}.new" && argo_bin_ok "${ARGO_BIN_DEFAULT}.new"; then
        mv -f "${ARGO_BIN_DEFAULT}.new" "$ARGO_BIN_DEFAULT"
        ARGO_BIN="$ARGO_BIN_DEFAULT"; ARGO_BIN_OURS="file"
        info "cloudflared 已安装: $("$ARGO_BIN" --version 2>/dev/null | head -n1)"
        return 0
    fi
    rm -f "${ARGO_BIN_DEFAULT}.new"
    err "下载 cloudflared 失败（或下载的程序在本机无法运行）"
    if [ -z "$(ip -4 route show default 2>/dev/null || true)" ]; then
        warn "本机可能是纯 IPv6，GitHub 不支持 IPv6；可临时改用 NAT64 DNS 后再试"
    fi
    return 1
}

argo_remove_bin() {
    case "$ARGO_BIN_OURS" in
        apk) apk del cloudflared >/dev/null 2>&1 || true ;;
        file) rm -f "$ARGO_BIN" "${ARGO_BIN}.new" ;;
    esac
}

# cloudflared 是 Go 程序：内存 ≤256MiB 时限制约 25%（至少 32MiB）
argo_gomem() {
    local m
    m=$(mem_mib)
    if [ "$m" -gt 0 ] && [ "$m" -le 256 ]; then
        m=$((m * 25 / 100)); [ "$m" -lt 32 ] && m=32
        printf '%sMiB' "$m"
    fi
}

argo_service_text() {
    local gm args
    gm=$(argo_gomem)
    args="tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:${ARGO_PORT}"
    case "$1" in
        openrc)
            echo "#!/sbin/openrc-run"
            if [ -n "$gm" ]; then
                echo "export GOMEMLIMIT=${gm}"
                echo "export GOGC=70"
            fi
            cat <<ARGO_SVC_EOF
name="${ARGO_SVC}"
description="sb Argo 备用入口 (Cloudflare 临时隧道)"
command="${ARGO_BIN}"
command_args="${args}"
pidfile="/run/${ARGO_SVC}.pid"
output_log="${ARGO_LOG}"
error_log="${ARGO_LOG}"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 10${gm:+ --env GOMEMLIMIT=${gm} --env GOGC=70}"

depend() {
    need net
    after firewall sing-box sing-box-relay
}
ARGO_SVC_EOF
            ;;
        systemd)
            cat <<ARGO_SVC_EOF
[Unit]
Description=sb Argo 备用入口 (Cloudflare 临时隧道)
After=network-online.target sing-box.service sing-box-relay.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${ARGO_BIN} ${args}
Restart=on-failure
RestartSec=10s
StandardOutput=append:${ARGO_LOG}
StandardError=append:${ARGO_LOG}
${gm:+Environment=GOMEMLIMIT=${gm}
Environment=GOGC=70
}
[Install]
WantedBy=multi-user.target
ARGO_SVC_EOF
            ;;
    esac
}

argo_svc() {
    # $1 = install | start | stop | restart | active | remove
    local kind
    kind=$(svc_kind)
    case "$kind:$1" in
        openrc:install)
            argo_service_text openrc > "$ARGO_INIT"; chmod +x "$ARGO_INIT"
            rc-update add "$ARGO_SVC" default >/dev/null 2>&1 || warn "添加开机自启失败: rc-update add $ARGO_SVC default" ;;
        systemd:install)
            argo_service_text systemd > "$ARGO_UNIT"
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable "$ARGO_SVC" >/dev/null 2>&1 || warn "设置开机自启失败: systemctl enable $ARGO_SVC" ;;
        openrc:active) rc-service "$ARGO_SVC" status >/dev/null 2>&1 ;;
        systemd:active) systemctl is-active "$ARGO_SVC" >/dev/null 2>&1 ;;
        openrc:stop) rc-service "$ARGO_SVC" stop >/dev/null 2>&1 || true ;;
        systemd:stop) systemctl stop "$ARGO_SVC" >/dev/null 2>&1 || true ;;
        openrc:start|openrc:restart) rc-service "$ARGO_SVC" restart >/dev/null 2>&1 ;;
        systemd:start|systemd:restart) systemctl restart "$ARGO_SVC" >/dev/null 2>&1 ;;
        openrc:disable) rc-update del "$ARGO_SVC" default >/dev/null 2>&1 || true ;;
        systemd:disable) systemctl disable "$ARGO_SVC" >/dev/null 2>&1 || true ;;
        *:remove)
            argo_svc stop; argo_svc disable
            rm -f "$ARGO_INIT" "$ARGO_UNIT"
            [ "$kind" = "systemd" ] && { systemctl daemon-reload >/dev/null 2>&1 || true; }
            return 0 ;;
        *) return 1 ;;
    esac
}

# 日志里最新的临时域名（排除 api.trycloudflare.com）
argo_parse_domain() {
    [ -f "$ARGO_LOG" ] || return 0
    grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | grep -v '^https://api\.' | tail -n 1 | sed 's#^https://##' || true
}

# 当前域名：日志里有就用日志里最新的（并记下来）；日志被清理过时用记下的
argo_domain() {
    local d
    d=$(argo_parse_domain)
    if [ -n "$d" ]; then
        if [ "$d" != "$ARGO_DOMAIN" ]; then ARGO_DOMAIN="$d"; argo_save; fi
        printf '%s' "$d"
    elif argo_svc active; then
        printf '%s' "$ARGO_DOMAIN"
    fi
}

argo_link() {
    local d="$1" pref path name
    pref="$ARGO_PREF"
    [[ "$pref" == *:* ]] && pref="[$pref]"
    path=$(uri_encode "${ARGO_PATH}?ed=2560")
    name=$(uri_encode "Argo-${ARGO_NAME:-$(hostname 2>/dev/null || echo node)}")
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&host=%s&fp=chrome&type=ws&path=%s#%s\n' \
        "$ARGO_UUID" "$pref" "$d" "$d" "$path" "$name"
}

argo_print() {
    local d
    d=$(argo_domain)
    echo ""
    echo "================ Argo 备用入口 (Cloudflare 临时隧道) ================"
    echo "   所在节点: $(argo_host_label)，出口: $(argo_exit_label "$ARGO_EXIT")"
    echo "   优选地址: $ARGO_PREF   本地入站: 127.0.0.1:$ARGO_PORT  路径: $ARGO_PATH"
    if ! argo_svc active; then
        warn "隧道服务 $ARGO_SVC 没有运行。选「重启隧道」重新建立（会换新域名）"
        [ -n "$d" ] || d="$ARGO_DOMAIN"
    fi
    if [ -z "$d" ]; then
        warn "还没有拿到临时域名，稍等几秒再查看，或选「重启隧道」"
        echo "======================================================================"
        return 1
    fi
    echo "   当前临时域名: $d"
    argo_link "$d" | tee "$ARGO_URI_FILE"
    echo "======================================================================"
    echo "   临时隧道域名在重启隧道/重启机器后会变，变了以后这里会显示新链接（需重新导入）。"
    return 0
}

argo_exit_label() {
    local f
    if [ "$1" = "direct-out" ]; then
        if [ "$ARGO_HOST" = "landing" ]; then printf '本机直连'; else printf '本机(线路机)直连'; fi
        return 0
    fi
    list_records
    for f in ${RECORDS[@]+"${RECORDS[@]}"}; do
        load_record "$f"
        if [ "$R_OUT_TAG" = "$1" ]; then printf '落地机「%s」(%s:%s)' "$R_NAME" "$R_SERVER" "$R_SERVER_PORT"; return 0; fi
    done
    printf '%s' "$1"
}

# 等隧道建立：拿到域名且 cloudflared 报告已连上 Cloudflare。失败返回 1 并说明原因
argo_wait() {
    local i d=""
    echo -n "   等待 Cloudflare 临时隧道建立(最多 ${ARGO_WAIT} 秒)"
    for ((i = 0; i < ARGO_WAIT; i++)); do
        sleep 1
        echo -n "."
        d=$(argo_parse_domain)
        if [ -n "$d" ] && grep -q 'Registered tunnel connection' "$ARGO_LOG" 2>/dev/null; then
            echo " 完成"
            ARGO_DOMAIN="$d"; argo_save
            return 0
        fi
        if ! argo_svc active && [ "$i" -ge 3 ]; then break; fi
    done
    echo ""
    if [ -n "$d" ] && ! grep -q 'Registered tunnel connection' "$ARGO_LOG" 2>/dev/null; then
        err "本机连不上 Cloudflare 隧道（常见于出口线路干扰 7844 端口），请在线路机上开启 Argo"
    elif [ -z "$d" ] && grep -qiE 'api\.trycloudflare\.com|quick tunnel|failed to request' "$ARGO_LOG" 2>/dev/null; then
        err "向 Cloudflare 申请临时域名失败（api.trycloudflare.com 连不上或被限流），请稍后再试"
    elif grep -qiE '7844|edge|quic|dial|i/o timeout|connection refused|context deadline' "$ARGO_LOG" 2>/dev/null; then
        err "本机连不上 Cloudflare 隧道（常见于出口线路干扰 7844 端口），请在线路机上开启 Argo"
    else
        err "Cloudflare 临时隧道没有建立成功"
    fi
    echo "   cloudflared 日志最后几行($ARGO_LOG):"
    tail -n 6 "$ARGO_LOG" 2>/dev/null | sed 's/^/     /' || true
    return 1
}

# 启动/重启隧道（清空旧日志，这样日志里的域名一定是新的）
argo_start_tunnel() {
    argo_svc stop
    : > "$ARGO_LOG" 2>/dev/null || true
    ARGO_DOMAIN=""; argo_save
    argo_svc start || true
    if argo_wait; then return 0; fi
    argo_svc stop
    warn "已停止隧道服务 $ARGO_SVC（没有一直卡着重试）。本机其他节点不受影响。"
    return 1
}

# ---- 与 fscarmen/ArgoX 共存 ----
ARGOX_DIR="/etc/argox"
argox_svc_file() {
    local s="$1" f
    for f in "/etc/systemd/system/$s.service" "/lib/systemd/system/$s.service" "/usr/lib/systemd/system/$s.service" "/etc/init.d/$s"; do
        if [ -f "$f" ] && grep -q '/etc/argox' "$f" 2>/dev/null; then printf '%s' "$f"; return 0; fi
    done
    return 1
}
argox_services() {
    local s out=""
    for s in argo xray nginx cloudflared; do
        argox_svc_file "$s" >/dev/null && out="$out $s"
    done
    printf '%s' "${out# }"
}
argox_pids() {
    local d c
    for d in /proc/[0-9]*; do
        [ "${d#/proc/}" = "$$" ] && continue
        c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null || true)
        case "$c" in *"/etc/argox"*) printf '%s\n' "${d#/proc/}" ;; esac
    done
    return 0
}
argox_present() { [ -d "$ARGOX_DIR" ] || [ -n "$(argox_services)" ]; }

argox_rollback_cmd() {
    local svcs="$1" nginx_cmd="$2" cmd
    if [ "$(svc_kind)" = "systemd" ]; then
        cmd="systemctl enable --now $svcs"
    else
        cmd="for s in $svcs; do rc-update add \$s default; rc-service \$s start; done"
    fi
    [ -n "$nginx_cmd" ] && cmd="$cmd; sleep 2; pgrep -f 'nginx.*argox' >/dev/null 2>&1 || $nginx_cmd"
    printf '%s' "$cmd"
}

# 迁移：停止并禁用 ArgoX 的服务（文件全部保留），打印一行恢复命令
argox_migrate() {
    local svcs s pids nginx_cmd="" p
    svcs=$(argox_services)
    for s in $svcs; do
        case "$(svc_kind)" in
            systemd) systemctl disable --now "$s" >/dev/null 2>&1 || true ;;
            openrc) rc-service "$s" stop >/dev/null 2>&1 || true; rc-update del "$s" default >/dev/null 2>&1 || true ;;
        esac
        info "已停止并禁用 ArgoX 服务: $s"
    done
    sleep 1
    pids=$(argox_pids)
    for p in $pids; do
        if [ -z "$nginx_cmd" ] && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q nginx; then
            if [ -f "$ARGOX_DIR/nginx.conf" ]; then
                nginx_cmd="nginx -c $ARGOX_DIR/nginx.conf"
            else
                nginx_cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | sed 's/ *$//; s/^nginx: master process //')
            fi
        fi
        kill "$p" 2>/dev/null || true
    done
    [ -n "$pids" ] && info "已结束仍在运行的 ArgoX 进程(xray/nginx/cloudflared)"
    if [ -n "$svcs" ] || [ -n "$nginx_cmd" ]; then
        ARGOX_ROLLBACK=$(argox_rollback_cmd "${svcs:-argo xray}" "$nginx_cmd")
    else
        ARGOX_ROLLBACK=""
    fi
    info "ArgoX 的文件全部保留在 $ARGOX_DIR，没有删除。"
    [ -n "$ARGOX_ROLLBACK" ] && echo "   想恢复 ArgoX，以 root 执行这一行: $ARGOX_ROLLBACK"
    return 0
}

# 开启前检查 ArgoX：0=继续 1=取消
argox_check() {
    local c svcs
    argox_present || return 0
    svcs=$(argox_services)
    echo ""
    warn "检测到本机装有 fscarmen/ArgoX（目录 $ARGOX_DIR${svcs:+，服务: $svcs}）"
    echo "   它也跑一条 Cloudflare 隧道(xray + nginx + cloudflared，占用 8080/30000/30001 等端口)。"
    echo "   1) 迁移(推荐)：停止并禁用 ArgoX 的服务，文件全部保留，会给出一行恢复命令；省内存，以后只用 sb 管理"
    echo "   2) 共存：两套都保留（本功能会避开它的端口），但会多占约 40~60MB 内存，256MB 小鸡可能吃紧"
    echo "   0) 取消"
    read -r -p "请选择(回车 = 1): " c || c=0
    case "${c:-1}" in
        1) argox_migrate; return 0 ;;
        2) warn "选择共存：两条隧道各自运行，注意内存（free -m 查看）"; return 0 ;;
        *) info "已取消"; return 1 ;;
    esac
}

# 选择出口（线路机：已有的落地机中转出口 / 本机直连；只有一个选项时不问）
argo_choose_exit() {
    local tags=() labels=() f i c
    if [ "$ARGO_HOST" = "landing" ]; then
        # 链接名用落地机安装时填的节点名称（/root/node_names.txt，如 -kr → Argo-kr）
        local nn
        nn=$(sed -n '1{s/^-//;p;}' /root/node_names.txt 2>/dev/null | tr -d '\r' || true)
        ARGO_EXIT="direct-out"; ARGO_NAME="${ARGO_NAME:-${nn:-直连}}"; return 0
    fi
    list_records
    for f in ${RECORDS[@]+"${RECORDS[@]}"}; do
        load_record "$f"
        jq -e --arg t "$R_OUT_TAG" 'any((.outbounds // [])[]; .tag == $t)' "$CONFIG" >/dev/null 2>&1 || continue
        tags+=("$R_OUT_TAG"); labels+=("落地机「$R_NAME」(${R_SERVER}:${R_SERVER_PORT})|$R_NAME")
    done
    tags+=("direct-out"); labels+=("本机(线路机)直连出口|直连")
    if [ "${#tags[@]}" -eq 1 ]; then ARGO_EXIT="direct-out"; ARGO_NAME="直连"; return 0; fi
    echo ""
    echo "Argo 入口的流量从哪里出去?"
    for i in "${!tags[@]}"; do echo "   $((i + 1))) ${labels[$i]%%|*}"; done
    while true; do
        read -r -p "请选择出口(回车 = 1): " c || c=1
        c="${c:-1}"
        if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#tags[@]}" ]; then break; fi
        err "请输入 1-${#tags[@]}"
    done
    ARGO_EXIT="${tags[$((c - 1))]}"
    ARGO_NAME="${labels[$((c - 1))]#*|}"
}

argo_ask_pref() {
    local p cur="${ARGO_PREF:-$ARGO_DEF_PREF}"
    echo "   优选地址 = 客户端实际连接的 Cloudflare 地址（域名或IP）。www.visa.com.sg 在中国移动上实测可用；skk.moe 在移动上不通。"
    while true; do
        read -r -p "优选地址(回车 = $cur): " p || p=""
        p=$(strip_host "${p:-$cur}")
        if valid_host "$p"; then ARGO_PREF="$p"; return 0; fi
        err "地址无效: $p（需为域名或 IP）"
    done
}

argo_enabled() { [ -f "$ARGO_ENV" ] && argo_load && [ -n "$ARGO_PORT" ]; }

argo_enable() {
    local rc=0 ans
    if argo_enabled; then
        info "Argo 备用入口已经开启"
        argo_print || true
        return 0
    fi
    command -v jq >/dev/null 2>&1 || { err "需要 jq"; return 1; }
    argo_load || true
    if [ -f "$RELAY_ENV" ] && [ -f "$CONFIG" ]; then
        ARGO_HOST="relay"
        load_env || return 1
    elif [ -f "$LANDING_CONFIG" ] && [ -f "$LANDING_DIR/.config_cache" ]; then
        ARGO_HOST="landing"
    else
        err "本机还没有 sing-box 节点（落地机或线路机），请先安装节点再开启 Argo"
        return 1
    fi
    echo ""
    info "=== 开启 Argo 备用入口（Cloudflare 临时隧道）==="
    echo "   客户端 → Cloudflare(优选地址:443) → 本机 cloudflared → 本机 127.0.0.1 上的 VLESS-ws 入站 → 出口"
    echo "   不占用商家映射端口，不改动已有节点和链接。临时隧道是 Cloudflare 的测试服务，域名会变，只适合做备用入口。"
    echo "   Argo 入站放在: $(argo_host_label)"
    argox_check || return 0
    argo_choose_exit
    argo_ask_pref
    ARGO_PORT=$(argo_pick_port) || { err "找不到可用的本地端口"; return 1; }
    ARGO_UUID=$(new_uuid)
    ARGO_PATH=$(argo_rand_path)
    argo_install_bin || return 1
    argo_save
    if ! argo_apply_cfg add; then
        argo_remove_bin; rm -rf "$ARGO_DIR"; return 1
    fi
    argo_save
    info "已添加本地入站 127.0.0.1:${ARGO_PORT}（VLESS-ws，路径 ${ARGO_PATH}，出口: $(argo_exit_label "$ARGO_EXIT")）"
    argo_svc install || true
    if argo_start_tunnel; then
        info "✅ Argo 备用入口已开启（服务 $ARGO_SVC，开机自启）"
        argo_print || true
        echo "   以后查看/换新域名: sb argo show / sb argo restart；关闭: sb argo off"
    else
        rc=1
        read -r -p "是否撤销本次开启(删除 Argo 入站、服务和 cloudflared)?(Y/n): " ans || ans=""
        if [[ ! "$ans" =~ ^[Nn]$ ]]; then
            argo_off yes quiet || true
            info "已撤销，本机节点没有任何改动"
        else
            info "已保留设置（隧道服务已停止）。以后可选「重启隧道」重试，或「关闭/卸载 Argo」"
        fi
    fi
    return "$rc"
}

# 关闭/卸载：$1=yes 不再确认；$2=quiet 少输出。只删 Argo 自己的入站/服务/程序/设置
argo_off() {
    local ans
    if ! argo_enabled; then
        [ "${2:-}" = "quiet" ] || info "Argo 备用入口没有开启"
        return 0
    fi
    if [ "${1:-}" != "yes" ]; then
        read -r -p "确认关闭并卸载 Argo 备用入口(其他节点不受影响)?(y/N): " ans || ans=n
        [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return 0; }
    fi
    argo_svc remove
    argo_apply_cfg del || warn "删除 Argo 入站失败，请检查 $(argo_cfg_file)"
    argo_remove_bin
    rm -f "$ARGO_LOG"
    if [ -n "$ARGOX_ROLLBACK" ]; then
        info "如需恢复以前的 ArgoX，以 root 执行: $ARGOX_ROLLBACK"
    fi
    rm -rf "$ARGO_DIR"
    [ "${2:-}" = "quiet" ] || info "✅ Argo 备用入口已关闭并卸载（其他节点和链接没有改动）"
    return 0
}

argo_restart() {
    argo_enabled || { err "Argo 备用入口没有开启"; return 1; }
    [ -f "$ARGO_INIT" ] || [ -f "$ARGO_UNIT" ] || argo_svc install || true
    info "重启隧道（会换一个新的临时域名）..."
    if argo_start_tunnel; then
        argo_print
    else
        return 1
    fi
}

argo_pref() {
    argo_enabled || { err "Argo 备用入口没有开启"; return 1; }
    if [ -n "${1:-}" ]; then
        valid_host "$(strip_host "$1")" || { err "地址无效: $1"; return 1; }
        ARGO_PREF=$(strip_host "$1")
    else
        argo_ask_pref
    fi
    argo_save
    info "优选地址已改为 $ARGO_PREF（只改链接，隧道不用重启）"
    argo_print || true
}

# 节点配置被重写后（重装落地机/全部重新安装线路机）把 Argo 入站补回去
argo_reapply() {
    argo_enabled || return 0
    local f
    f=$(argo_cfg_file)
    [ -f "$f" ] || return 0
    if jq -e --arg tag "$ARGO_TAG" --arg out "$ARGO_EXIT" 'any((.inbounds // [])[]; .tag == $tag) and any((.route.rules // [])[]; .inbound == $tag and .outbound == $out)' "$f" >/dev/null 2>&1; then
        return 0
    fi
    if argo_apply_cfg add; then
        argo_save
        info "已把 Argo 备用入口的本地入站补回 $f（链接不变）"
    fi
}

# 线路机节点被卸载时：本机还有落地机节点就问是否把 Argo 挪过去（链接不变），否则一起卸载
argo_on_relay_uninstall() {
    local ans
    argo_enabled || return 0
    [ "$ARGO_HOST" = "relay" ] || return 0
    if [ -f "$LANDING_CONFIG" ] && [ -f "$LANDING_DIR/.config_cache" ]; then
        read -r -p "Argo 备用入口在线路机节点上。是否改到本机落地机节点上继续使用(出口本机，链接不变)?(y/N): " ans || ans=n
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            ARGO_HOST="landing"; ARGO_EXIT="direct-out"
            if argo_apply_cfg add; then
                argo_save
                info "Argo 备用入口已改到落地机节点（出口本机直连），链接不变"
                return 0
            fi
            ARGO_HOST="relay"
        fi
    fi
    argo_svc remove
    argo_remove_bin
    rm -f "$ARGO_LOG"
    [ -n "$ARGOX_ROLLBACK" ] && info "如需恢复以前的 ArgoX，以 root 执行: $ARGOX_ROLLBACK"
    rm -rf "$ARGO_DIR"
    info "Argo 备用入口已一起卸载"
}

# 落地机节点被卸载时（sb 调用）：Argo 在落地机上就一起卸载
argo_on_landing_uninstall() {
    argo_enabled || return 0
    [ "$ARGO_HOST" = "landing" ] || return 0
    argo_svc remove
    argo_remove_bin
    rm -f "$ARGO_LOG"
    [ -n "$ARGOX_ROLLBACK" ] && info "如需恢复以前的 ArgoX，以 root 执行: $ARGOX_ROLLBACK"
    rm -rf "$ARGO_DIR"
    info "Argo 备用入口(在落地机节点上)已一起卸载"
}

argo_menu() {
    local c
    while true; do
        echo ""
        echo "============ Argo 备用入口 (Cloudflare 临时隧道) ============"
        argo_load || true
        if argo_enabled; then
            if argo_svc active; then echo "   状态: 已开启，隧道运行中"; else echo "   状态: 已开启，隧道未运行"; fi
        else
            echo "   状态: 未开启"
        fi
        echo "1) 开启"
        echo "2) 查看当前域名和链接"
        echo "3) 修改优选地址(当前 ${ARGO_PREF:-$ARGO_DEF_PREF})"
        echo "4) 重启隧道(换新域名并打印新链接)"
        echo "5) 关闭/卸载 Argo(只删 Argo 自己的入站/服务/程序，节点不动)"
        echo "0) 返回"
        echo "============================================================="
        read -r -p "请选择: " c || return 0
        case "$c" in
            1) argo_enable || true ;;
            2) if argo_enabled; then argo_print || true; else info "Argo 备用入口没有开启"; fi ;;
            3) argo_pref || true ;;
            4) argo_restart || true ;;
            5) argo_off || true ;;
            0|"") return 0 ;;
            *) warn "无效选项: $c" ;;
        esac
    done
}

argo_main() {
    case "${1:-menu}" in
        menu) argo_menu ;;
        on|enable|start) argo_enable ;;
        show|link) argo_enabled || { info "Argo 备用入口没有开启（开启: sb argo）"; return 0; }; argo_print ;;
        restart) argo_restart ;;
        pref) argo_pref "${2:-}" ;;
        off|uninstall|remove) argo_off "${2:-}" ;;
        reapply) argo_reapply ;;
        landing-uninstall) argo_on_landing_uninstall ;;
        *) err "用法: sb argo [show|restart|pref [地址]|off]"; return 1 ;;
    esac
}

# ===== 分享提醒（每次运行最多显示一次）=====
share_reminder() {
    [ -n "${SB_REMINDED:-}" ] && return 0
    export SB_REMINDED=1
    echo ""
    warn "⚠️ 链接不要分享给别人，避免连接数异常被商家封机"
}

# ===== 端口连通性提示（itdog tcping）=====
# 输出本机所有对外节点的「标签|端口|tcp/udp/both」（跳过只监听 127.0.0.1 的 Argo 入站）
node_ports() {
    local f
    command -v jq >/dev/null 2>&1 || return 0
    for f in "$LANDING_CONFIG" "$CONFIG"; do
        [ -f "$f" ] || continue
        [ "$f" = "$LANDING_CONFIG" ] && ! landing_log_config && continue
        jq -r --arg side "$([ "$f" = "$CONFIG" ] && echo 线路机 || echo 落地机)" '
          (.inbounds // [])[]
          | select((.listen // "") != "127.0.0.1" and (.listen_port // 0) > 0)
          | [ $side, (.type // "?"), (.tag // ""), (.listen_port | tostring),
              (if .type == "shadowsocks" then "both"
               elif (.type == "hysteria2" or .type == "tuic" or .type == "hysteria") then "udp"
               else "tcp" end) ] | join("|")' "$f" 2>/dev/null || true
    done
}

node_label() {
    # $1=落地机/线路机 $2=type $3=tag
    local t
    case "$2" in
        shadowsocks) t="SS" ;; hysteria2) t="HY2" ;; tuic) t="TUIC" ;; anytls) t="AnyTLS Reality" ;;
        vless) t="VLESS Reality" ;; *) t="$2" ;;
    esac
    if [ "$1" = "线路机" ]; then
        if [ "$3" = "vless-direct-in" ]; then t="直连节点"; else t="中转节点"; fi
        local f
        list_records
        for f in ${RECORDS[@]+"${RECORDS[@]}"}; do
            load_record "$f"
            [ "$R_IN_TAG" = "$3" ] && { t="中转「$R_NAME」"; break; }
        done
    fi
    printf '%s %s' "$1" "$t"
}

# 列出 入口IP:端口，提示用 itdog tcping 从国内测试；$1=short 只输出列表和简短说明
tcp_hint() {
    local ip host lines udp side type tag port net
    ip=$(saved_entry_ip)
    [ -n "$ip" ] || ip="你的入口IP"
    host="$ip"; [[ "$host" == *:* ]] && host="[$host]"
    lines=""; udp=""
    while IFS='|' read -r side type tag port net; do
        [ -n "$port" ] || continue
        case "$net" in
            tcp|both) lines="${lines}     ${host}:${port}    ($(node_label "$side" "$type" "$tag"))"$'\n' ;;
        esac
        case "$net" in
            udp|both) udp="${udp} ${port}($(node_label "$side" "$type" "$tag"))" ;;
        esac
    done < <(node_ports)
    echo ""
    info "💡 从国内测试端口通不通：打开 https://www.itdog.cn/tcping/ ，把下面每一行(入口IP:端口)粘进去测试"
    if [ -n "$lines" ]; then printf '%s' "$lines"; else echo "     (本机还没有 TCP 节点)"; fi
    [ -n "$udp" ] && echo "   UDP 端口无法用 tcping 测试，请直接用客户端连接测试:${udp}"
    nat_load
    if nat_on; then
        echo "   NAT 小鸡：在本机内部测不出商家的端口映射是否生效，必须从外网(itdog)测【入口IP:映射端口】"
    elif looks_nat; then
        echo "   如果是 NAT/LXC 小鸡：在本机内部测不出商家的端口映射是否生效，必须从外网(itdog)测【入口IP:映射端口】"
    fi
    echo "   服务器自己判断不了是否被墙（被墙发生在国内那一端），只能从国内测试"
}

# ===== IP 被墙了？（说明 + 一键开启 Argo 备用入口；不做任何自动检测）=====
blocked_guide() {
    local ans
    echo ""
    info "=== IP 被墙了？==="
    echo "   常见症状：所有节点突然都连不上/超时，但商家控制台显示机器正常，从国外 SSH 也能登录。"
    echo "   服务器自己检测不出是否被墙（墙在国内那一端），本脚本也不会自动检测，请按下面的方法从国内测："
    tcp_hint
    echo ""
    echo "   怎么看结果："
    echo "   - itdog 上全国大部分地区都超时/100% 丢包，而国外(https://ping.pe/ 输入 IP:端口)是通的 → 基本是 IP 被墙"
    echo "   - 只有个别端口不通、其他端口通 → 端口被封，可在 sb 里「重置端口」换一个"
    echo "   - 国内国外都不通 → 不是被墙：检查服务是否在运行(sb 查看状态)、商家防火墙/安全组、NAT 映射端口"
    echo "   - 都能通但客户端连不上 → 不是被墙：检查客户端时间、链接是否最新、SNI 是否可用"
    echo ""
    echo "   被墙后的办法："
    echo "   1) 开启 Argo 备用入口：走 Cloudflare，不依赖本机 IP，被墙时通常还能用（下面可一键开启）"
    echo "   2) 找商家换 IP；换好后在 sb「入口/出口 IP」填新入口IP，链接重新导入即可（节点、密钥不变）"
    if argo_enabled; then
        echo ""
        info "Argo 备用入口已经开启，当前链接："
        argo_print || true
        return 0
    fi
    echo ""
    read -r -p "是否现在一键开启 Argo 备用入口?(y/N): " ans || ans=n
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        argo_enable
        return $?
    fi
    info "未开启。以后可在 sb「Argo 备用入口」或输入 sb argo 开启"
    return 0
}

# ===== 一键备份 / 恢复 =====
BACKUP_INFO="sb-backup.info"
# 备份内容：配置和密钥（不含程序、日志、*.bak 旧配置）
backup_paths() {
    local p
    for p in /etc/sing-box /etc/sing-box-relay /etc/sb-argo; do
        [ -d "$p" ] || continue
        find "$p" -type f ! -name '*.bak' ! -name '*.bak.*' ! -name '*.log' ! -name '*.err' \
            ! -name '*.tmp' ! -path '*/migrated-*' 2>/dev/null || true
    done
    for p in /root/node_names.txt /etc/sb-nat.conf /etc/sb-log.conf; do
        [ -f "$p" ] && printf '%s\n' "$p"
    done
    return 0
}

# $1 = 文件名前缀（默认 sb-backup）。结果路径放在 BACKUP_FILE
sb_backup() {
    local prefix="${1:-sb-backup}" quiet="${2:-}" list stage out n=1 parts=""
    list=$(backup_paths)
    if [ -z "$list" ]; then
        err "本机没有可备份的 sing-box 节点配置"
        return 1
    fi
    out="/root/${prefix}-$(date +%Y%m%d-%H%M).tar.gz"
    while [ -e "$out" ]; do n=$((n + 1)); out="/root/${prefix}-$(date +%Y%m%d-%H%M)-${n}.tar.gz"; done
    stage=$(mktemp -d /tmp/sb-backup.XXXXXX)
    printf '%s\n' "$list" | sed 's|^/||' > "$stage/.list"
    if ! (cd / && tar cf - -T "$stage/.list") | (cd "$stage" && tar xf -); then
        rm -rf "$stage"; err "打包失败"; return 1
    fi
    rm -f "$stage/.list"
    [ -f /etc/sing-box/config.json ] && parts="$parts 落地机节点"
    [ -f /etc/sing-box-relay/relay.env ] && parts="$parts 线路机节点"
    [ -f /etc/sb-argo/argo.env ] && parts="$parts Argo"
    [ -f /etc/sb-nat.conf ] && parts="$parts NAT设置"
    {
        echo "SB_BACKUP_VERSION=1"
        printf 'CREATED=%q\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
        printf 'HOST=%q\n' "$(hostname 2>/dev/null || echo ?)"
        printf 'ENTRY_IP=%q\n' "$(saved_entry_ip)"
        printf 'PARTS=%q\n' "${parts# }"
    } > "$stage/$BACKUP_INFO"
    if ! (umask 077; tar czf "$out" -C "$stage" .); then
        rm -rf "$stage" "$out"; err "打包失败"; return 1
    fi
    chmod 600 "$out"
    rm -rf "$stage"
    BACKUP_FILE="$out"
    [ "$quiet" = "quiet" ] && return 0
    info "✅ 已备份到: $out （权限 600，只有 root 可读）"
    echo "   内容: ${parts# }（配置、密钥、节点名称、NAT/日志设置；不含程序和日志）"
    warn "备份里有节点密钥/密码，等于全部节点链接，不要分享给别人；请下载到自己电脑保存，例如："
    echo "   scp -P SSH端口 root@入口IP:$out ."
    echo "   恢复: 把文件放到新机器 /root/ 下，输入 sb restore（全新机器先用一键脚本: bash install-singbox-yyds.sh restore $out）"
    return 0
}

backup_list() {
    ls -1t /root/sb-backup-*.tar.gz /root/sb-prerestore-*.tar.gz 2>/dev/null || true
}

# 本机落地机 sing-box 服务（恢复到新机器时用；内容和一键脚本安装的一样）
landing_service_install() {
    local bin gm
    bin=$(singbox_bin)
    gm=$(relay_gomem)
    case "$(svc_kind)" in
        openrc)
            [ -f /etc/init.d/sing-box ] && return 0
            {
                echo "#!/sbin/openrc-run"
                echo ""
                if [ -n "$gm" ]; then echo "export GOMEMLIMIT=${gm}"; echo "export GOGC=70"; fi
                cat <<SVC
name="sing-box"
description="Sing-box Proxy Server"
command="${bin}"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
# 自动拉起（程序崩溃、OOM、被 kill 后自动恢复）
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5${gm:+ --env GOMEMLIMIT=${gm} --env GOGC=70}"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
SVC
            } > /etc/init.d/sing-box
            chmod +x /etc/init.d/sing-box
            rc-update add sing-box default >/dev/null 2>&1 || warn "添加开机自启失败: rc-update add sing-box default"
            ;;
        systemd)
            [ -f /etc/systemd/system/sing-box.service ] && return 0
            cat > /etc/systemd/system/sing-box.service <<SVC
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=${bin} run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576
${gm:+Environment=GOMEMLIMIT=${gm}
Environment=GOGC=70
}
[Install]
WantedBy=multi-user.target
SVC
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable sing-box >/dev/null 2>&1 || warn "设置开机自启失败: systemctl enable sing-box"
            ;;
        *) warn "未检测到 systemd / OpenRC，无法创建 sing-box 服务"; return 1 ;;
    esac
    info "已创建落地机服务 sing-box（开机自启）"
}

# 恢复需要的工具和 sing-box（缺什么装什么）
restore_deps() {
    local need="" c
    detect_os
    for c in curl jq tar; do command -v "$c" >/dev/null 2>&1 || need="$need $c"; done
    [ "${1:-}" = "landing" ] && ! command -v openssl >/dev/null 2>&1 && need="$need openssl"
    if [ -n "$need" ]; then
        info "安装依赖:$need"
        case "$OS" in
            alpine) apk add --no-cache $need ca-certificates bash >/dev/null || true ;;
            debian) { apt-get update -y && apt-get install -y $need ca-certificates; } >/dev/null 2>&1 || true ;;
            redhat) yum install -y $need ca-certificates >/dev/null 2>&1 || true ;;
        esac
    fi
    command -v jq >/dev/null 2>&1 || { err "安装 jq 失败"; return 1; }
    if ! command -v sing-box >/dev/null 2>&1; then
        check_disk
        info "本机没有 sing-box，正在安装..."
        case "$OS" in
            alpine) install_singbox_alpine "$SB_MIN_VER" || true ;;
            *) (cd "$(mktemp -d)" && bash <(curl -fsSL https://sing-box.app/install.sh)) || true ;;
        esac
        clean_pkg_cache
        command -v sing-box >/dev/null 2>&1 || { err "sing-box 安装失败"; return 1; }
        info "sing-box 版本: $(sb_version)"
    fi
    return 0
}

# 把目录 $1 里的文件按原路径复制到 /（只复制文件，不改动 /、/etc、/root 等已有目录的权限）
restore_copy_tree() {
    local src="$1" f
    while IFS= read -r f; do
        f="${f#./}"
        [ "$f" = "$BACKUP_INFO" ] && continue
        mkdir -p "/$(dirname "$f")" && cp -p "$src/$f" "/$f" || return 1
    done < <(cd "$src" && find . -type f)
    return 0
}

# 把预恢复备份 $1 还原回去（恢复失败时用）；$2 = 本次要覆盖的目录/文件列表
restore_rollback() {
    local pre="$1" items="$2" p tmpd
    for p in $items; do rm -rf "$p"; done
    if [ -n "$pre" ] && [ -f "$pre" ]; then
        tmpd=$(mktemp -d /tmp/sb-rb.XXXXXX)
        tar xzf "$pre" -C "$tmpd" 2>/dev/null || true
        restore_copy_tree "$tmpd" || true
        rm -rf "$tmpd"
        warn "已还原为恢复前的配置（$pre）"
    fi
    # 把原来在运行的服务拉起来
    if [ -f "$LANDING_CONFIG" ]; then landing_svc restart >/dev/null 2>&1 || true; fi
    if [ -f "$CONFIG" ] && service_installed; then svc_restart >/dev/null 2>&1 || true; fi
    if argo_enabled; then argo_svc start >/dev/null 2>&1 || true; fi
    return 0
}

# 恢复：$1 = 备份文件（可空，空则列出 /root 下的备份让你选）
# 用户取消时：从 sb 面板调用(SB_FROM_PANEL)返回 10，面板据此不再显示链接
sb_restore() {
    local file="${1:-}" files=() i c tmpd items="" pre="" exists=0 ans p has_land=0 has_relay=0 has_argo=0 cur new
    if [ -z "$file" ]; then
        mapfile -t files < <(backup_list)
        if [ "${#files[@]}" -eq 0 ]; then
            err "/root 下没有找到备份文件(sb-backup-*.tar.gz)。请先把备份文件上传到 /root/，或用 sb restore 文件路径"
            return 1
        fi
        echo ""
        echo "找到这些备份（新的在前）："
        for i in "${!files[@]}"; do echo "   $((i + 1))) ${files[$i]}"; done
        read -r -p "请选择要恢复的备份(回车 = 1，0 = 取消): " c || c=0
        c="${c:-1}"
        if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "${#files[@]}" ]; then info "已取消"; [ -n "${SB_FROM_PANEL:-}" ] && return 10; return 0; fi
        file="${files[$((c - 1))]}"
    fi
    [ -f "$file" ] || { err "找不到备份文件: $file"; return 1; }
    command -v tar >/dev/null 2>&1 || { err "需要 tar"; return 1; }
    tmpd=$(mktemp -d /tmp/sb-restore.XXXXXX)
    if ! tar xzf "$file" -C "$tmpd" 2>/dev/null || [ ! -f "$tmpd/$BACKUP_INFO" ]; then
        rm -rf "$tmpd"; err "不是 sb 备份文件(或文件已损坏): $file"; return 1
    fi
    chmod 700 "$tmpd"
    [ -f "$tmpd/etc/sing-box/config.json" ] && has_land=1
    [ -f "$tmpd/etc/sing-box-relay/relay.env" ] && has_relay=1
    [ -f "$tmpd/etc/sb-argo/argo.env" ] && has_argo=1
    echo ""
    info "=== 从备份恢复: $file ==="
    (
        # shellcheck disable=SC1090,SC1091
        . "$tmpd/$BACKUP_INFO" 2>/dev/null || true
        echo "   备份时间: ${CREATED:-?}   原机器: ${HOST:-?}   原入口IP: ${ENTRY_IP:-?}"
        echo "   内容: ${PARTS:-?}"
    )
    # 本次会覆盖的目录/文件（备份里有的才覆盖，备份里没有的部分保持本机原样）
    [ "$has_land" = 1 ] && items="$items /etc/sing-box"
    [ "$has_relay" = 1 ] && items="$items /etc/sing-box-relay"
    [ "$has_argo" = 1 ] && items="$items /etc/sb-argo"
    for p in /root/node_names.txt /etc/sb-nat.conf /etc/sb-log.conf; do
        [ -f "$tmpd$p" ] && items="$items $p"
    done
    for p in $items; do
        case "$p" in
            /etc/sing-box) [ -f /etc/sing-box/config.json ] && exists=1 ;;
            /etc/sing-box-relay) [ -f /etc/sing-box-relay/relay.env ] && exists=1 ;;
            /etc/sb-argo) [ -f /etc/sb-argo/argo.env ] && exists=1 ;;
        esac
    done
    if [ "$exists" = 1 ]; then
        warn "本机已有节点配置，恢复会【覆盖】这些:${items}"
        echo "   覆盖前会先把本机现在的配置备份到 /root/sb-prerestore-*.tar.gz，可以随时恢复回来。"
        read -r -p "确认覆盖本机配置?(y/N): " ans || ans=n
        [[ "$ans" =~ ^[Yy]$ ]] || { rm -rf "$tmpd"; info "已取消，本机没有任何改动"; [ -n "${SB_FROM_PANEL:-}" ] && return 10; return 0; }
        sb_backup sb-prerestore quiet || { rm -rf "$tmpd"; err "恢复前备份失败，已取消"; return 1; }
        pre="$BACKUP_FILE"
        info "恢复前的配置已备份到: $pre"
    else
        read -r -p "确认恢复?(Y/n): " ans || ans=y
        [[ "$ans" =~ ^[Nn]$ ]] && { rm -rf "$tmpd"; info "已取消"; [ -n "${SB_FROM_PANEL:-}" ] && return 10; return 0; }
    fi
    if [ "$has_land" = 1 ]; then restore_deps landing || { rm -rf "$tmpd"; return 1; }
    else restore_deps || { rm -rf "$tmpd"; return 1; }; fi
    # 停服务 → 换文件
    [ "$has_land" = 1 ] && { landing_svc stop >/dev/null 2>&1 || true; }
    [ "$has_relay" = 1 ] && svc_stop
    [ "$has_argo" = 1 ] && { argo_svc stop >/dev/null 2>&1 || true; }
    for p in $items; do rm -rf "$p"; done
    if ! restore_copy_tree "$tmpd"; then
        err "写入文件失败"
        restore_rollback "$pre" "$items"; rm -rf "$tmpd"; return 1
    fi
    rm -rf "$tmpd"
    chmod 600 /root/node_names.txt 2>/dev/null || true
    # 校验
    for p in "$LANDING_CONFIG" "$CONFIG"; do
        { [ "$p" = "$LANDING_CONFIG" ] && [ "$has_land" = 1 ]; } || { [ "$p" = "$CONFIG" ] && [ "$has_relay" = 1 ]; } || continue
        if ! sing-box check -c "$p" >/dev/null 2>&1; then
            err "恢复后的配置 $p 没有通过 sing-box check："
            sing-box check -c "$p" 2>&1 | tail -n 5 | sed 's/^/     /' || true
            err "本机的 sing-box($(sb_version)) 可能比原机器旧，可先在 sb 里「更新 sing-box」再恢复"
            restore_rollback "$pre" "$items"
            [ -z "$pre" ] && warn "本机原来没有这些配置，已清理掉恢复的文件"
            return 1
        fi
    done
    info "配置校验通过(sing-box check)"
    # 服务
    if [ "$has_land" = 1 ]; then
        landing_service_install || true
        landing_svc restart >/dev/null 2>&1 && info "已启动落地机服务 sing-box" || warn "启动 sing-box 失败，请运行 sb 查看状态"
    fi
    if [ "$has_relay" = 1 ]; then
        if service_installed; then refresh_service; else install_service || true; fi
        svc_restart >/dev/null 2>&1 && info "已启动线路机服务 $SVC_NAME" || warn "启动 $SVC_NAME 失败，请运行: bash $SELF_COPY status"
        # 备份里的线路机脚本副本够新就保留（里面可能有落地机参数），太旧才换成当前版本
        if [ ! -f "$SELF_COPY" ] || ! grep -q 'sb_restore()' "$SELF_COPY" 2>/dev/null; then
            save_self_copy
        else
            write_shim; install_shortcut
        fi
    fi
    log_autosetup >/dev/null 2>&1 || true
    # 备份里没有 Argo、本机原来开着 Argo：把它的入站补回被覆盖的配置（Argo 链接不变）
    if [ "$has_argo" = 0 ] && argo_enabled; then argo_reapply || true; fi
    # 入口IP：商家重装/换机后可能变了
    cur=$(saved_entry_ip)
    echo ""
    echo "   入口IP(链接里用的地址)现在是: ${cur:-未设置}。商家重装系统或换了机器后入口IP 可能变了。"
    read -r -p "如需修改，输入新的入口IP/域名(回车保持不变): " new || new=""
    new=$(strip_host "$new")
    if [ -n "$new" ] && [ "$new" != "$cur" ]; then
        entry_ip_menu "$new" >/dev/null || warn "修改入口IP 失败，可稍后在 sb「入口/出口 IP」里修改"
        info "入口IP 已改为 $new（链接里的地址随之改变，节点、端口、密钥不变）"
    fi
    info "✅ 恢复完成（端口、密钥、链接和备份时一样）"
    if [ "$has_relay" = 1 ]; then
        echo ""
        show_link || true
    fi
    if [ "$has_argo" = 1 ] && argo_enabled; then
        echo ""
        info "重新建立 Argo 临时隧道（临时域名会变，需要重新导入 Argo 链接）..."
        if ! argo_bin_ok "$ARGO_BIN"; then ARGO_BIN=""; argo_install_bin || true; fi
        if argo_bin_ok "$ARGO_BIN"; then
            argo_save
            argo_svc install || true
            if argo_start_tunnel; then argo_print || true; else warn "Argo 隧道没有建立，可稍后运行 sb argo restart"; fi
        else
            warn "cloudflared 没装好，Argo 暂不可用，可稍后运行 sb argo restart"
        fi
    fi
    if [ "$has_land" = 1 ] && [ -z "${SB_FROM_PANEL:-}" ]; then
        restore_panel
    fi
    [ -z "${SB_FROM_PANEL:-}" ] && share_reminder
    return 0
}

# 恢复了落地机节点、但本机 sb 还不是完整面板时：装完整面板并显示落地机链接
restore_panel() {
    local src="${SB_INSTALLER_SRC:-}" tmp tmpp
    if [ -f "$SB_CMD" ] && ! is_shortcut "$SB_CMD" && grep -q 'action_view_uri' "$SB_CMD" 2>/dev/null; then
        echo ""; "$SB_CMD" links || true; export SB_REMINDED=1; return 0
    fi
    tmp=$(mktemp /tmp/sb-main.XXXXXX); tmpp=$(mktemp /tmp/sb-panel.XXXXXX)
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        if curl -fsSL "$MAIN_URL" -o "$tmp"; then src="$tmp"; fi
    fi
    if [ -n "$src" ] && awk '/<<.SB_SCRIPT.$/{f=1;next} /^SB_SCRIPT$/{f=0} f' "$src" > "$tmpp" \
        && grep -q pinSHA256 "$tmpp" && bash -n "$tmpp"; then
        mkdir -p "$(dirname "$SB_CMD")"
        cp "$tmpp" "$SB_CMD" && chmod +x "$SB_CMD" && ln -sf "$SB_CMD" /usr/bin/sb 2>/dev/null || true
        info "已安装 sb 管理面板: $SB_CMD"
        echo ""
        "$SB_CMD" links || true
        export SB_REMINDED=1    # 面板显示链接时已经提醒过
    else
        warn "下载 sb 面板失败；落地机节点已恢复并在运行。以后执行一键脚本里的「更新 sb 面板」命令即可，链接用 sb → 1 查看"
    fi
    rm -f "$tmp" "$tmpp"
}

backup_menu() {
    local c
    echo ""
    echo "============ 备份 / 恢复 ============"
    echo "1) 立即备份(生成 /root/sb-backup-日期-时间.tar.gz)"
    echo "2) 从备份恢复(列出 /root 下的备份)"
    echo "0) 返回"
    echo "====================================="
    read -r -p "请选择: " c || return 0
    case "$c" in
        1) sb_backup ;;
        2) sb_restore ;;
        *) return 0 ;;
    esac
}

# ===== 入口 =====
MODE="${1:-}"
case "$MODE" in
    help|-h|--help) usage; exit 0 ;;
    shortcut) install_shortcut; exit 0 ;;
    # 日志相关命令不触发旧版迁移（sb 面板启动时也会调用 logauto）
    logauto|logsetup) log_autosetup; exit 0 ;;
    logclean) log_clean_now; exit 0 ;;
    loglevel) log_level_menu "${2:-}"; exit $? ;;
    logremove) log_remove; exit 0 ;;
    # NAT 模式 / 入口IP / 安装 sing-box（sb 面板也调用这些）
    natpick) nat_load; nat_on || exit 2; nat_collect_used "$LANDING_CONFIG" "$CONFIG"; nat_pick "${2:-tcp}"; exit $? ;;
    natports|nat) nat_menu; exit 0 ;;
    entryip) entry_ip_menu "${2:-}"; exit $? ;;
    sbinstall) check_disk; rc=0; install_singbox_alpine "${2:-$SB_MIN_VER}" || rc=$?; clean_pkg_cache; exit "$rc" ;;
    # Argo 备用入口（sb argo …）
    argo) shift; argo_main "$@"; exit $? ;;
    # IP 被墙了？/ 备份 / 恢复 / 端口测试提示
    blocked|wall) blocked_guide; exit $? ;;
    backup) sb_backup; exit $? ;;
    backupmenu) backup_menu; exit $? ;;
    restore) shift; sb_restore "$@"; exit $? ;;
    tcphint) tcp_hint; exit 0 ;;
    reminder) share_reminder; exit 0 ;;
esac

# 旧版线路机（节点在 /etc/sing-box）先迁移到独立目录/服务；迁移失败就停下，绝不另装一套
maybe_migrate || exit 1

# 日志：清理脚本/定时任务/journald 限制、info→warn（已设置好时什么都不做）
log_autosetup || true

case "$MODE" in
    rename) rename_node; exit $? ;;
    show|link) show_link; exit $? ;;
    direct) manage_direct; exit $? ;;
    append|add) append_node; exit $? ;;
    delete|del|remove) delete_node; exit $? ;;
    upgrade|migrate) do_upgrade; exit $? ;;
    uninstall) uninstall_relay; exit $? ;;
    restart) svc_restart && info "已重启 $SVC_NAME"; svc_status; exit 0 ;;
    status) svc_status; tcp_hint || true; exit 0 ;;
    landing) open_landing; exit $? ;;
    install)
        if [ -f "$RELAY_ENV" ]; then
            confirm_overwrite || { info "已取消"; exit 0; }
        fi
        fresh_install relay; exit $?
        ;;
    menu|"") ;;
    *) err "未知参数: $MODE"; usage; exit 1 ;;
esac

if [ -f "$RELAY_ENV" ]; then
    relay_menu
    exit $?
fi

if landing_valid; then
    fresh_install relay
    exit $?
fi

# 模板脚本（没有落地机参数）且本机还没有线路机节点
echo ""
echo "本机还没有线路机节点，且本脚本没有落地机参数。"
echo "1) 在本机添加一个直连节点(VLESS Reality，出口本机；独立服务，不影响落地机节点)"
echo "0) 退出"
echo "（要中转某台落地机: 在那台落地机上 sb → 生成线路机脚本，再把生成的命令拿到本机运行）"
read -r -p "请选择: " choice || choice=0
case "$choice" in
    1) manage_direct; exit $? ;;
    *) exit 0 ;;
esac
RELAY_EOF
}

# 生成线路机脚本
action_generate_relay() {
    read_config || return 1

    # 缓存说已启用 SS，但 config.json 里其实没有 SS 入站（节点被删过）：按未启用处理，提示重新部署
    if [ "${ENABLE_SS:-false}" = "true" ] && [ -z "$(ss_from_config listen_port)" ]; then
        warn "缓存标记已启用 SS，但 $CONFIG_PATH 中没有 SS 入站(缓存已过期)"
        ENABLE_SS=false
    fi

    # 若本机 config.json 已有 SS 入站（缓存标记缺失/过期），直接使用，避免重复添加 ss-in
    if [ "${ENABLE_SS:-false}" != "true" ] && [ -n "$(ss_from_config listen_port)" ]; then
        info "检测到 config.json 中已有 SS 入站，直接使用"
        ENABLE_SS=true
        cache_set ENABLE_SS true
        kv_set /etc/sing-box/.protocols ENABLE_SS true
    fi

    # 检查是否启用了SS
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        warn "未检测到 SS 协议,需要先部署 SS 作为入站"
        read -r -p "是否现在部署 SS 协议?(y/N): " deploy_ss
        if [[ "$deploy_ss" =~ ^[Yy]$ ]]; then
            info "开始部署 SS 协议..."

            # 让用户选择端口（校验 1-65535）；NAT 模式下默认从剩余映射端口里选
            local nat_def=""
            nat_def=$(nat_suggest_port ss || true)
            while true; do
                if [ -n "$nat_def" ]; then
                    read -r -p "请输入 SS 端口(NAT 模式，回车使用空闲映射端口 ${nat_def}): " USER_SS_PORT
                    SS_PORT="${USER_SS_PORT:-$nat_def}"
                else
                    read -r -p "请输入 SS 端口(NAT 机器请填商家映射的端口，留空则随机 10000-60000): " USER_SS_PORT
                    SS_PORT="${USER_SS_PORT:-$(rand_port)}"
                fi
                if ! validate_port "$SS_PORT"; then
                    err "端口无效: $SS_PORT (需为 1-65535 的数字)"
                elif jq -e --argjson p "$SS_PORT" 'any((.inbounds // [])[]; .listen_port == $p)' "$CONFIG_PATH" >/dev/null 2>&1; then
                    err "端口 $SS_PORT 已被本机其他节点使用，请换一个"
                elif ! check_new_port "$SS_PORT"; then
                    :
                else
                    break
                fi
            done
            SS_PSK=$(rand_pass)
            SS_METHOD="aes-128-gcm"

            info "SS 端口: $SS_PORT | 加密: $SS_METHOD | 密码已自动生成"

            info "正在停止服务..."
            service_stop || warn "停止服务失败"

            cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

            # 添加 SS inbound（method 与 SS_METHOD 变量保持一致）
            if ! jq --argjson port "$SS_PORT" --arg psk "$SS_PSK" --arg method "$SS_METHOD" '
            .inbounds = ((.inbounds // []) + [{
              "type": "shadowsocks",
              "listen": "::",
              "listen_port": $port,
              "method": $method,
              "password": $psk,
              "tag": "ss-in"
            }])
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"; then
                rm -f "${CONFIG_PATH}.tmp"
                err "写入 SS 入站失败，配置未修改"
                service_start || true
                return 1
            fi
            mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

            if command -v sing-box >/dev/null 2>&1 && ! sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
                err "新配置校验失败，已从 ${CONFIG_PATH}.bak 还原"
                cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"
                service_start || true
                return 1
            fi

            # 更新缓存和协议标记（替换已有键，不再重复追加）
            cache_set ENABLE_SS true
            cache_set SS_PORT "$SS_PORT"
            cache_set SS_PSK "$SS_PSK"
            cache_set SS_METHOD "$SS_METHOD"

            # 同步更新协议标记文件
            kv_set /etc/sing-box/.protocols ENABLE_SS true

            # 更新当前会话变量
            ENABLE_SS=true

            info "SS 已部署 - 端口: $SS_PORT"
            service_start || warn "启动服务失败"
            sleep 1

            # 重新读取配置
            read_config
        else
            err "取消生成线路机脚本"
            return 1
        fi
    fi

    # 以 config.json 中实际生效的 SS 入站为准（缓存可能过期）；找不到时才回退到缓存
    local cfg_port cfg_method cfg_psk
    cfg_port=$(ss_from_config listen_port)
    cfg_method=$(ss_from_config method)
    cfg_psk=$(ss_from_config password)
    if [ -n "$cfg_port" ] && [ -n "$cfg_method" ] && [ -n "$cfg_psk" ]; then
        SS_PORT="$cfg_port"
        SS_METHOD="$cfg_method"
        SS_PSK="$cfg_psk"
        # 顺便把缓存同步为真实值
        cache_set SS_PORT "$SS_PORT"
        cache_set SS_METHOD "$SS_METHOD"
        cache_set SS_PSK "$SS_PSK"
    else
        warn "未能从 $CONFIG_PATH 读取 SS 入站，回退使用缓存 $CACHE_FILE 中的值"
    fi
    SS_METHOD="${SS_METHOD:-aes-128-gcm}"

    if [ -z "${SS_PSK:-}" ] || ! validate_port "${SS_PORT:-}"; then
        err "SS 端口或密码无效(端口: ${SS_PORT:-空})，请检查 $CONFIG_PATH"
        return 1
    fi

    # 本机看起来是线路机（已有 relay-out 出站）时提醒：「生成线路机脚本」应在落地机上运行
    if jq -e '[(.outbounds // [])[] | select((.tag // "") | startswith("relay-out"))] | length > 0' "$CONFIG_PATH" >/dev/null 2>&1; then
        warn "本机 config.json 含有 relay-out 出站，看起来是线路机！此功能应在【落地机】上运行。"
    fi

    # 落地机入口地址：NAT/转发机上自动检测到的通常是【出口IP】，客户端/线路机连不上，
    # 因此不再静默使用检测结果，必须由用户确认或输入商家提供的【入口IP/连接地址】
    local INBOUND_IP="" DETECTED_IP confirm input_ip SSH_PORT DETECTED_SSH_PORT input_ssh
    sb_nat_load
    # NAT 模式记录的入口IP 作为默认
    [ -z "${CUSTOM_IP:-}" ] && [ -n "${ENTRY_IP:-}" ] && CUSTOM_IP="$ENTRY_IP"
    detect_public_ip || true
    DETECTED_IP="$(normalize_host "${DETECTED_IP:-YOUR_SERVER_IP}")"
    [ -n "${NAT_REASON:-}" ] && warn "$NAT_REASON"
    echo ""
    info "=== 设置落地机(本机)入口地址 ==="
    echo "   入口IP: 线路机/客户端连接本机用的地址（通常就是你 SSH 登录用的 IP，或商家给的 NAT 入口IP/域名）"
    echo "   出口IP: 本机访问外网时显示的 IP。NAT/转发机上出口IP 与入口IP 往往不同，填出口IP 将无法连接！"
    echo "   参考 - 自动检测到的出口IP: ${DETECTED_IP} （NAT 机器上通常不可用）"
    echo "   注意 - NAT 机器上 SS 端口(${SS_PORT})必须是商家映射给你的端口之一，否则线路机无法连到落地机"
    if sb_nat_on && ! sb_in_words "$SS_PORT" "$NAT_PORTS"; then
        warn "NAT 模式：SS 端口 ${SS_PORT} 不在映射端口(${NAT_PORTS})里，线路机很可能连不上！可先在菜单里重置 SS 端口"
    fi
    if [ -n "${CUSTOM_IP:-}" ]; then
        echo "   已保存的连接地址(CUSTOM_IP): ${CUSTOM_IP}"
    fi
    echo ""

    while [ -z "$INBOUND_IP" ]; do
        if [ -n "${CUSTOM_IP:-}" ]; then
            read -r -p "请输入落地机入口IP/域名(回车使用已保存的 ${CUSTOM_IP}): " input_ip
            input_ip="$(normalize_host "${input_ip:-$CUSTOM_IP}")"
        else
            read -r -p "请输入落地机入口IP/域名(商家提供的连接地址，回车=使用检测到的 ${DETECTED_IP}): " input_ip
            input_ip="$(normalize_host "$input_ip")"
            if [ -z "$input_ip" ]; then
                warn "检测到的 ${DETECTED_IP} 是出口IP，NAT/转发机上通常无法作为入口连接！"
                read -r -p "确定使用 ${DETECTED_IP} 作为落地机地址?(y/N): " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] || continue
                input_ip="$DETECTED_IP"
            fi
        fi
        if ! validate_host "$input_ip"; then
            err "落地机地址无效: '${input_ip}'（需为 IPv4、IPv6 或含字母和点的域名，不能是端口号）"
            continue
        fi
        INBOUND_IP="$input_ip"
    done

    # 落地机 SSH 连接端口（线路机用它从本机拉取脚本）。NAT 机器上 sshd 内部是 22，
    # 但外部要用商家映射的端口，所以必须询问；优先使用缓存，其次自动检测
    DETECTED_SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2;exit}' || true)
    if [ -z "$DETECTED_SSH_PORT" ]; then
        DETECTED_SSH_PORT=$(grep -Ei '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2;exit}' || true)
    fi
    DETECTED_SSH_PORT="${DETECTED_SSH_PORT:-22}"
    SSH_PORT="${LANDING_SSH_PORT:-$DETECTED_SSH_PORT}"
    # NAT 模式：默认用映射端口列表里标记的 SSH 端口
    if sb_nat_on && [ -n "${NAT_SSH_PORT:-}" ]; then SSH_PORT="$NAT_SSH_PORT"; fi
    validate_port "$SSH_PORT" || SSH_PORT="$DETECTED_SSH_PORT"
    while true; do
        read -r -p "请输入落地机的 SSH 连接端口(就是你平时 SSH 登录本机用的端口，NAT 机器填商家映射的端口，回车默认 ${SSH_PORT}): " input_ssh
        input_ssh=$(printf '%s' "${input_ssh:-$SSH_PORT}" | tr -d '[:space:]')
        if validate_port "$input_ssh"; then
            SSH_PORT="$input_ssh"
            break
        fi
        err "SSH 端口无效: '${input_ssh}'（需为 1-65535 的数字）"
    done
    cache_set LANDING_SSH_PORT "$SSH_PORT"

    while true; do
        echo ""
        info "即将生成线路机脚本，出站参数如下(请核对):"
        echo "   落地机入口地址(server): $INBOUND_IP"
        echo "   落地机 SS 端口        : $SS_PORT  (NAT 机器须为商家映射端口)"
        echo "   加密方式              : $SS_METHOD"
        echo "   密码                  : $(mask_secret "$SS_PSK")  (取自 $CONFIG_PATH)"
        echo "   Reality SNI           : ${REALITY_SNI:-addons.mozilla.org}"
        echo "   落地机 SSH 端口       : ${SSH_PORT}  (线路机用它拉取脚本，NAT 机器须为商家映射的 SSH 端口)"
        if [ "$INBOUND_IP" = "$DETECTED_IP" ]; then
            warn "落地机地址与检测到的出口IP 相同；若本机是 NAT/转发机，请改为入口IP"
        fi
        echo ""
        read -r -p "确认生成?(y=确认 / i=输入其他落地IP / N=取消): " confirm
        case "$confirm" in
            [Yy]) break ;;
            [Ii])
                read -r -p "请输入落地机入口IP或域名: " input_ip
                input_ip="$(normalize_host "$input_ip")"
                if validate_host "$input_ip"; then
                    INBOUND_IP="$input_ip"
                else
                    err "落地机地址无效: '${input_ip}'（需为 IPv4、IPv6 或含字母和点的域名，不能是端口号），保持原值"
                fi
                ;;
            *)
                info "已取消"
                return 1
                ;;
        esac
    done

    # 记住确认过的入口地址，下次作为默认值
    # IPv6 保存时带方括号，以便「查看协议链接」生成的 URI 正确（线路机配置里用的是不带括号的值）
    local SAVE_IP="$INBOUND_IP"
    [[ "$SAVE_IP" == *:* ]] && SAVE_IP="[$SAVE_IP]"
    if [ "${CUSTOM_IP:-}" != "$SAVE_IP" ]; then
        cache_set CUSTOM_IP "$SAVE_IP"
        info "已将入口地址 $SAVE_IP 保存为 CUSTOM_IP（下次默认使用，节点链接也会用它）"
    fi

    PUBLIC_IP="$INBOUND_IP"
    RELAY_SCRIPT="/root/relay-install.sh"

    info "正在生成线路机脚本: $RELAY_SCRIPT"

    write_relay_template "$RELAY_SCRIPT"

    # 替换占位符（INBOUND_IP/PORT/METHOD/PASSWORD 同时替换 REALITY_SNI）
    # 值放在单引号里，并转义 sed 特殊字符，避免密码含 / & | ' 等字符时出错
    sed -i "s|__INBOUND_IP__|$(sed_sq_escape "$INBOUND_IP")|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PORT__|$(sed_sq_escape "$SS_PORT")|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_METHOD__|$(sed_sq_escape "$SS_METHOD")|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PASSWORD__|$(sed_sq_escape "$SS_PSK")|g" "$RELAY_SCRIPT"
    sed -i "s|__REALITY_SNI__|$(sed_sq_escape "${REALITY_SNI:-addons.mozilla.org}")|g" "$RELAY_SCRIPT"

    # 脚本内含落地机 SS 密码，仅 root 可读；/tmp 留一份兼容旧用法
    chmod 600 "$RELAY_SCRIPT"
    cp "$RELAY_SCRIPT" /tmp/relay-install.sh 2>/dev/null && chmod 600 /tmp/relay-install.sh || true

    # 检测落地机 SSH 端口（NAT 机器上应为商家映射的 SSH 端口）
    local RELAY_B64 SSH_HOST show_full SSH_FETCH_CMD
    SSH_HOST="$INBOUND_IP"
    # 方法一命令：线路机没有 ssh 客户端时先自动安装（兼容 bash / ash）
    SSH_FETCH_CMD="command -v ssh >/dev/null 2>&1 || { if command -v apk >/dev/null 2>&1; then apk add --no-cache openssh-client; elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y openssh-client; else yum install -y openssh-clients; fi; }; ssh -p ${SSH_PORT} root@${SSH_HOST} \"cat /root/relay-install.sh\" > /root/relay-install.sh && bash /root/relay-install.sh"
    RELAY_B64=$(base64 -w0 "$RELAY_SCRIPT" 2>/dev/null || base64 "$RELAY_SCRIPT" | tr -d '\n')

    echo ""
    info "✅ 线路机脚本已生成并保存到本机(落地机): $RELAY_SCRIPT"
    echo ""
    echo "================ 接下来在【线路机】上操作 ================"
    echo "1. 用 SSH 登录【线路机】(不是本机)，切换到 root。"
    echo "2. 任选下面一种方法，把整行命令复制到线路机执行："
    echo ""
    echo "   【方法一(推荐)】线路机通过 SSH 从落地机拉取脚本并执行(整行复制):"
    echo ""
    echo "$SSH_FETCH_CMD"
    echo ""
    echo "   - 线路机没有 ssh 客户端时，这行命令会先自动安装(openssh-client)"
    echo "   - ${SSH_PORT} 是你刚才填写的落地机 SSH 连接端口"
    echo "   - 首次连接会问 Are you sure you want to continue connecting，输入 yes 回车"
    echo "   - 然后输入【落地机】的 root 密码（输入时屏幕不显示任何字符，属正常），回车"
    echo ""
    echo "   【方法二】不用 SSH，复制下面这一整行（很长，务必完整复制）到线路机执行:"
    echo "   (见本输出最后一行)"
    echo ""
    echo "3. 脚本运行中询问「监听端口」「节点名称」时直接回车使用默认值即可。"
    echo "   【线路机第一次用】会问「是否同时添加一个本机(线路机)直连出口的 VLESS Reality 节点?」，不需要就回车(默认 N)。"
    echo "   【线路机上已经有别的落地机的中转节点】会出现菜单，直接回车选「1) 追加这台落地机为新的中转节点」，"
    echo "   原有节点的端口/链接都不变。不要选「9) 全部重新安装」，那会删掉所有已有节点！"
    echo "   (每多一台落地机，就在那台落地机上生成一次脚本，再到线路机上运行一次、选「追加」)"
    echo "4. 完成后会显示 vless:// 链接（所有节点链接都保存在线路机 /etc/sing-box-relay/relay_uri.txt）："
    echo "   把新节点那一行复制到 Shadowrocket(小火箭) 添加节点即可，不需要设置「代理通过」。"
    echo "5. 在线路机的云厂商安全组/防火墙(如 Oracle 的 Security List)放行新节点的监听端口(TCP)；若添加了直连节点，它的端口也要放行。"
    echo ""
    info "之后在线路机输入 sb（或 bash /etc/sing-box-relay/relay-install.sh）可管理：查看链接 / 改名 / 删除节点 / 直连节点"
    echo "   线路机节点使用独立服务 sing-box-relay（配置 /etc/sing-box-relay），线路机上也可以再装落地机节点，互不覆盖。"
    echo "   线路机如果是旧版(节点在 /etc/sing-box)，运行新脚本时会自动迁移，端口/UUID/链接都不变。"
    echo "=========================================================="
    echo ""

    read -r -p "是否显示完整脚本内容?(y/N): " show_full
    if [[ "$show_full" =~ ^[Yy]$ ]]; then
        echo "----------------------------------------"
        cat "$RELAY_SCRIPT"
        echo "----------------------------------------"
        echo ""
    fi

    info "【方法二】整行复制到线路机执行:"
    echo ""
    echo "echo '${RELAY_B64}' | base64 -d > /root/relay-install.sh && bash /root/relay-install.sh"
    echo ""
}

# 动态生成菜单
show_menu() {
    read_config 2>/dev/null || true
    
    cat <<'MENU'

==========================
 Sing-box 管理面板 (快速指令sb)
==========================
1) 查看协议链接
2) 查看配置文件路径
3) 编辑配置文件
MENU

    # 构建协议重置选项映射
    declare -g -A MENU_MAP
    local option=4
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        echo "$option) 重置 SS 端口"
        MENU_MAP[$option]="reset_ss"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        echo "$option) 重置 HY2 端口"
        MENU_MAP[$option]="reset_hy2"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        echo "$option) 重置 TUIC 端口"
        MENU_MAP[$option]="reset_tuic"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "$option) 重置 Vless Reality 端口"
        MENU_MAP[$option]="reset_reality"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        echo "$option) 重置 AnyTLS Reality 端口"
        MENU_MAP[$option]="reset_anytls"
        option=$((option + 1))
    fi

    # 固定功能选项
    MENU_MAP[$option]="start"
    echo "$option) 启动服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="stop"
    echo "$((option))) 停止服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="restart"
    echo "$((option))) 重启服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="status"
    echo "$((option))) 查看状态"
    option=$((option + 1))
    
    MENU_MAP[$option]="update"
    echo "$((option))) 更新 sing-box"
    option=$((option + 1))
    
    MENU_MAP[$option]="relay"
    echo "$((option))) 生成线路机脚本(出口为本机ss协议)"
    option=$((option + 1))
    
    MENU_MAP[$option]="uninstall"
    echo "$((option))) 卸载 sing-box(落地机节点)"
    option=$((option + 1))

    MENU_MAP[$option]="relay_local"
    if [ -f "$RELAY_HOME/relay.env" ] || [ -f /etc/sing-box/relay.env ]; then
        echo "$((option))) 线路机/直连节点管理(本机已安装，独立服务 sing-box-relay)"
    else
        echo "$((option))) 线路机/直连节点(本机添加直连节点，独立服务 sing-box-relay)"
    fi
    option=$((option + 1))

    MENU_MAP[$option]="log_clean"
    echo "$((option))) 清理日志(立即清空 sing-box 日志)"
    option=$((option + 1))

    MENU_MAP[$option]="log_level"
    echo "$((option))) 日志级别(当前 $(current_log_levels)，切换 warn/info)"
    option=$((option + 1))

    MENU_MAP[$option]="add_protocol"
    echo "$((option))) 添加协议(给本机落地机加一个新协议，已有节点不变)"
    option=$((option + 1))

    MENU_MAP[$option]="entry_ip"
    echo "$((option))) 入口/出口 IP(查看出口IP，修改链接用的入口IP)"
    option=$((option + 1))

    sb_nat_load
    MENU_MAP[$option]="nat_ports"
    if sb_nat_on; then
        echo "$((option))) NAT 映射端口(已开启: ${NAT_PORTS})"
    else
        echo "$((option))) NAT 映射端口(LXC/NAT 小鸡用，当前未开启)"
    fi
    option=$((option + 1))

    MENU_MAP[$option]="argo"
    if [ -f /etc/sb-argo/argo.env ]; then
        echo "$((option))) Argo 备用入口(已开启，Cloudflare 临时隧道)"
    else
        echo "$((option))) Argo 备用入口(Cloudflare 临时隧道，不占映射端口)"
    fi
    option=$((option + 1))

    MENU_MAP[$option]="blocked"
    echo "$((option))) IP 被墙了？(怎么从国内测试 + 一键开启 Argo 备用入口)"
    option=$((option + 1))

    MENU_MAP[$option]="backup"
    echo "$((option))) 备份/恢复(节点配置和密钥打包到 /root，换机/重装后一键恢复)"
    
    cat <<MENU2
0) 退出
==========================
MENU2
}

# sing-box 版本 >= $1 (x.y.z) ?
sb_ver_at_least() {
    local v
    v=$(sing-box version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    [ -n "$v" ] || return 1
    [ "$(printf '%s\n%s\n' "$1" "$v" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$1" ]
}

# 添加协议：给已安装的落地机加一个还没启用的协议（不改动已有节点的端口/密码/链接）
action_add_protocol() {
    read_config || return 1
    local keys=() names=() i c key mode nets port in ans nat_def inbound pk="" sid="" pub="" sni
    [ "${ENABLE_SS:-false}" = "true" ]      || { keys+=(ss);      names+=("Shadowsocks (SS，TCP+UDP，可作为线路机的出口)"); }
    [ "${ENABLE_HY2:-false}" = "true" ]     || { keys+=(hy2);     names+=("Hysteria2 (HY2，UDP)"); }
    [ "${ENABLE_TUIC:-false}" = "true" ]    || { keys+=(tuic);    names+=("TUIC (UDP)"); }
    [ "${ENABLE_REALITY:-false}" = "true" ] || { keys+=(reality); names+=("VLESS Reality (TCP)"); }
    [ "${ENABLE_ANYTLS:-false}" = "true" ]  || { keys+=(anytls);  names+=("AnyTLS Reality (TCP)"); }
    if [ "${#keys[@]}" -eq 0 ]; then
        info "所有协议都已启用，没有可添加的协议"
        return 0
    fi
    echo ""
    echo "可添加的协议（已有节点不会改动）:"
    for i in "${!keys[@]}"; do echo "$((i + 1))) ${names[$i]}"; done
    echo "0) 返回"
    read -r -p "请选择: " c || c=0
    [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#keys[@]}" ] || return 0
    key="${keys[$((c - 1))]}"
    case "$key" in
        ss) mode=ss; nets="tcp udp" ;;
        hy2|tuic) mode=udp; nets="udp" ;;
        *) mode=tcp; nets="tcp" ;;
    esac
    if [ "$key" = "anytls" ] && ! sb_ver_at_least 1.12.0; then
        err "AnyTLS 需要 sing-box 1.12 或更新版本，当前: $(sing-box version 2>/dev/null | head -n1)。请先在菜单里「更新 sing-box」"
        return 1
    fi

    # 端口：NAT 模式从剩余映射端口里自动选（HY2/TUIC 只用映射了 UDP 的端口）
    sb_nat_load
    nat_def=""
    if sb_nat_on; then
        nat_def=$(nat_suggest_port "$mode" || true)
        if [ -z "$nat_def" ]; then
            if [ "$mode" = "udp" ]; then
                warn "NAT 模式：没有空闲的映射了 UDP 的端口(UDP 端口: ${NAT_UDP_PORTS:-无})，$key 外网连不上。可在「NAT 映射端口」里补充"
            else
                warn "NAT 模式：映射端口($NAT_PORTS)已经用完"
            fi
        fi
    fi
    while true; do
        if [ -n "$nat_def" ]; then
            read -r -p "端口(回车使用空闲映射端口 ${nat_def}): " in || in=""
        else
            read -r -p "端口(回车随机 10000-60000): " in || in=""
        fi
        in=$(printf '%s' "$in" | tr -d '[:space:]')
        port="${in:-${nat_def:-$(rand_port)}}"
        validate_port "$port" || { err "端口无效: $port"; continue; }
        port=$((10#$port))
        if port_nets_overlap "$CONFIG_PATH" "$port" "$nets"; then
            err "端口 $port 已被本机落地机的其他协议使用，请换一个"; continue
        fi
        check_new_port "$port" "$nets" || continue
        if sb_nat_on && [ "$mode" = "udp" ] && sb_in_words "$port" "$NAT_PORTS" && ! sb_in_words "$port" "$NAT_UDP_PORTS"; then
            warn "端口 $port 没有映射 UDP，$key 外网连不上"
            read -r -p "仍然使用 $port ?(y/N): " ans || ans=""
            [[ "$ans" =~ ^[Yy]$ ]] || continue
        fi
        break
    done

    # 证书 / Reality 密钥（Reality 与 AnyTLS 共用一套）
    sni="${REALITY_SNI:-addons.mozilla.org}"
    if [ "$key" = "hy2" ] || [ "$key" = "tuic" ]; then
        if [ ! -f /etc/sing-box/certs/fullchain.pem ] || [ ! -f /etc/sing-box/certs/privkey.pem ]; then
            ensure_openssl || { err "需要 openssl 生成自签证书"; return 1; }
            mkdir -p /etc/sing-box/certs
            openssl req -x509 -newkey rsa:2048 -nodes -keyout /etc/sing-box/certs/privkey.pem \
                -out /etc/sing-box/certs/fullchain.pem -days 3650 -subj "/CN=www.bing.com" >/dev/null 2>&1 \
                || { err "证书生成失败"; return 1; }
        fi
    fi
    if [ "$key" = "reality" ] || [ "$key" = "anytls" ]; then
        pk=$(jq -r 'first((.inbounds // [])[] | select(.tls.reality.enabled == true) | .tls.reality.private_key) // empty' "$CONFIG_PATH" 2>/dev/null || true)
        sid=$(jq -r 'first((.inbounds // [])[] | select(.tls.reality.enabled == true) | .tls.reality.short_id[0]) // empty' "$CONFIG_PATH" 2>/dev/null || true)
        local esni
        esni=$(jq -r 'first((.inbounds // [])[] | select(.tls.reality.enabled == true) | .tls.server_name) // empty' "$CONFIG_PATH" 2>/dev/null || true)
        [ -n "$esni" ] && sni="$esni"
        pub=$(cat /etc/sing-box/.reality_pub 2>/dev/null || true)
        if [ -z "$pk" ] || [ -z "$pub" ] || [ -z "$sid" ]; then
            local kp
            kp=$(sing-box generate reality-keypair 2>/dev/null || true)
            pk=$(printf '%s\n' "$kp" | awk '/PrivateKey/{print $NF}' | tr -d '\r')
            pub=$(printf '%s\n' "$kp" | awk '/PublicKey/{print $NF}' | tr -d '\r')
            sid=$(sing-box generate rand 8 --hex 2>/dev/null || true)
            [ -n "$pk" ] && [ -n "$pub" ] && [ -n "$sid" ] || { err "生成 Reality 密钥失败"; return 1; }
        fi
    fi

    local p1="" p2="" bw=false
    case "$key" in
        ss)
            p1=$(rand_pass)
            inbound=$(jq -n --argjson port "$port" --arg psk "$p1" '{type:"shadowsocks",listen:"::",listen_port:$port,method:"aes-128-gcm",password:$psk,tag:"ss-in"}')
            ;;
        hy2)
            p1=$(rand_pass)
            sb_ver_at_least 1.11.0 && bw=true
            inbound=$(jq -n --argjson port "$port" --arg psk "$p1" --argjson bw "$bw" '{type:"hysteria2",tag:"hy2-in",listen:"::",listen_port:$port,users:[{password:$psk}]}
                + (if $bw then {ignore_client_bandwidth:true} else {} end)
                + {tls:{enabled:true,alpn:["h3"],certificate_path:"/etc/sing-box/certs/fullchain.pem",key_path:"/etc/sing-box/certs/privkey.pem"}}')
            ;;
        tuic)
            p1=$(rand_uuid); p2=$(rand_pass)
            inbound=$(jq -n --argjson port "$port" --arg u "$p1" --arg psk "$p2" '{type:"tuic",tag:"tuic-in",listen:"::",listen_port:$port,users:[{uuid:$u,password:$psk}],congestion_control:"bbr",
                tls:{enabled:true,alpn:["h3"],certificate_path:"/etc/sing-box/certs/fullchain.pem",key_path:"/etc/sing-box/certs/privkey.pem"}}')
            ;;
        reality)
            p1=$(rand_uuid)
            inbound=$(jq -n --argjson port "$port" --arg u "$p1" --arg sni "$sni" --arg pk "$pk" --arg sid "$sid" '{type:"vless",tag:"vless-in",listen:"::",listen_port:$port,users:[{uuid:$u,flow:"xtls-rprx-vision"}],
                tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$pk,short_id:[$sid]}}}')
            ;;
        anytls)
            p1=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n'); p2=$(rand_pass)
            inbound=$(jq -n --argjson port "$port" --arg u "$p1" --arg psk "$p2" --arg sni "$sni" --arg pk "$pk" --arg sid "$sid" '{type:"anytls",tag:"anytls-in",listen:"::",listen_port:$port,users:[{name:$u,password:$psk}],padding_scheme:[],
                tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$pk,short_id:[$sid]}}}')
            ;;
    esac

    local bak="${CONFIG_PATH}.bak.addproto" out
    cp "$CONFIG_PATH" "$bak"
    if ! jq --argjson ib "$inbound" '.inbounds = ((.inbounds // []) + [$ib])' "$bak" > "${CONFIG_PATH}.tmp"; then
        rm -f "${CONFIG_PATH}.tmp"; err "写入配置失败，未改动"; return 1
    fi
    mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    if ! out=$(sing-box check -c "$CONFIG_PATH" 2>&1); then
        cp "$bak" "$CONFIG_PATH"
        err "配置校验失败，已还原，节点未改动:"
        printf '%s\n' "$out" | tail -n 10 >&2
        return 1
    fi
    if ! service_restart; then
        cp "$bak" "$CONFIG_PATH"
        service_restart || true
        err "重启失败，已还原配置"
        return 1
    fi

    local K
    K=$(printf '%s' "$key" | tr 'a-z' 'A-Z')
    kv_set /etc/sing-box/.protocols "ENABLE_$K" true
    cache_set "ENABLE_$K" true
    case "$key" in
        ss) cache_set SS_PORT "$port"; cache_set SS_PSK "$p1"; cache_set SS_METHOD aes-128-gcm ;;
        hy2) cache_set HY2_PORT "$port"; cache_set HY2_PSK "$p1" ;;
        tuic) cache_set TUIC_PORT "$port"; cache_set TUIC_UUID "$p1"; cache_set TUIC_PSK "$p2" ;;
        reality) cache_set REALITY_PORT "$port"; cache_set REALITY_UUID "$p1" ;;
        anytls) cache_set ANYTLS_PORT "$port"; cache_set ANYTLS_USER "$p1"; cache_set ANYTLS_PSK "$p2" ;;
    esac
    if [ "$key" = "reality" ] || [ "$key" = "anytls" ]; then
        cache_set REALITY_PK "$pk"; cache_set REALITY_SID "$sid"; cache_set REALITY_PUB "$pub"; cache_set REALITY_SNI "$sni"
        printf '%s' "$pub" > /etc/sing-box/.reality_pub
    fi
    rm -f "$bak"
    info "已添加 $key，端口 $port（其他节点未改动）"
    if [ "$mode" != "tcp" ] && ! sb_nat_on; then
        warn "$key 使用 UDP 端口 $port：如果有云防火墙/安全组，记得放行 UDP $port"
    fi
    action_view_uri || true
}

# 入口/出口 IP：入口IP 用于所有链接；只重新生成链接，不重启服务
action_entry_ip() {
    run_relay_template entryip "${1:-}" || true
    CUSTOM_IP=""
    if [ -f "$CONFIG_PATH" ]; then
        echo ""
        action_view_uri || true
    fi
}

# NAT 映射端口（查看端口→协议表 / 修改映射端口列表 / 开关 NAT 模式）
action_nat_ports() { run_relay_template natports || true; }

# 分享提醒：每次运行 sb 最多显示一次
sb_share_reminder() {
    [ -n "${SB_REMINDED:-}" ] && return 0
    SB_REMINDED=1
    echo ""
    warn "⚠️ 链接不要分享给别人，避免连接数异常被商家封机"
}

# 从备份恢复（具体实现在线路机脚本模板里）；恢复了落地机节点就显示落地机链接
action_restore() {
    local rc=0
    SB_FROM_PANEL=1 SB_REMINDED=1 run_relay_template restore "$@" || rc=$?
    [ "$rc" -eq 10 ] && return 0
    [ "$rc" -eq 0 ] || return "$rc"
    if [ -f /etc/sing-box/config.json ] && [ -f /etc/sing-box/.config_cache ]; then
        echo ""
        info "落地机节点链接："
        action_view_uri || true
    else
        sb_share_reminder
    fi
    return 0
}

action_backup_menu() {
    local c
    echo ""
    echo "============ 备份 / 恢复 ============"
    echo "1) 立即备份(生成 /root/sb-backup-日期-时间.tar.gz)"
    echo "2) 从备份恢复(列出 /root 下的备份)"
    echo "0) 返回"
    echo "====================================="
    read -r -p "请选择: " c || return 0
    case "$c" in
        1) run_relay_template backup || true ;;
        2) action_restore || true ;;
    esac
    return 0
}

# 日志：首次运行新版 sb 时自动设置（清理脚本 + 每小时定时清理 + info→warn）；已设置好时跳过
if [ "${1:-}" != "logsetup" ] && log_setup_needed; then
    run_relay_template logauto || true
fi

# 命令行快捷方式: sb relay = 线路机/直连节点管理；sb logclean / sb loglevel [warn|info]
# sb addproto = 添加协议；sb entryip [IP] = 入口/出口 IP；sb natports = NAT 映射端口
# sb argo [show|restart|pref|off] = Argo 备用入口
# sb blocked = IP 被墙了？；sb backup / sb restore [文件] = 备份/恢复；sb links = 显示落地机链接
case "${1:-}" in
    relay) action_relay_local; exit $? ;;
    logsetup) run_relay_template logauto; exit $? ;;
    logclean) action_log_clean; exit 0 ;;
    loglevel) run_relay_template loglevel "${2:-}"; exit $? ;;
    addproto) action_add_protocol; exit $? ;;
    entryip) action_entry_ip "${2:-}"; exit 0 ;;
    natports|nat) action_nat_ports; exit 0 ;;
    argo) shift; run_relay_template argo "$@"; exit $? ;;
    blocked|wall) run_relay_template blocked; exit $? ;;
    backup) run_relay_template backup; exit $? ;;
    restore) shift; action_restore "$@"; exit $? ;;
    links) action_view_uri; exit $? ;;
esac

# 主循环
while true; do
    show_menu
    read -p "请输入选项: " opt
    
    # 处理退出
    if [ "$opt" = "0" ]; then
        exit 0
    fi
    
    # 处理固定选项
    case "$opt" in
        1) action_view_uri ;;
        2) action_view_config ;;
        3) action_edit_config ;;
        *)
            # 处理动态选项
            action="${MENU_MAP[$opt]:-}"
            case "$action" in
                reset_ss) action_reset_ss ;;
                reset_hy2) action_reset_hy2 ;;
                reset_tuic) action_reset_tuic ;;
                reset_reality) action_reset_reality ;;
                reset_anytls) action_reset_anytls ;;
                start) service_start && info "已启动" ;;
                stop) service_stop && info "已停止" ;;
                restart) service_restart && info "已重启" ;;
                status) service_status; run_relay_template tcphint || true ;;
                update) action_update || true ;;
                relay) action_generate_relay || true ;;
                uninstall) action_uninstall; exit 0 ;;
                relay_local) action_relay_local || true ;;
                log_clean) action_log_clean ;;
                log_level) action_log_level ;;
                add_protocol) action_add_protocol || true ;;
                entry_ip) action_entry_ip ;;
                nat_ports) action_nat_ports ;;
                argo) run_relay_template argo || true ;;
                blocked) run_relay_template blocked || true ;;
                backup) action_backup_menu || true ;;
                *) warn "无效选项: $opt" ;;
            esac
            ;;
    esac
    
    echo ""
done
SB_SCRIPT

chmod +x "$SB_PATH"
ln -sf /usr/local/bin/sb /usr/bin/sb
info "✅ 管理面板已创建,可输入 sb 打开管理面板"
# 日志：安装每小时自动清理脚本 /usr/local/bin/sb-logrotate（单个日志超过 50MB 只保留最后 1MB），systemd 限制 journald 50MB
"$SB_PATH" logsetup || warn "设置日志自动清理失败，可稍后再运行一次 sb"
if [ -f /etc/sing-box-relay/relay.env ]; then
    info "本机的线路机(中转/直连)节点由独立服务 sing-box-relay 运行，未受影响；在 sb 菜单「线路机/直连节点管理」里管理"
fi
# 重装落地机后：Argo 备用入口在落地机节点上时把它的本地入站补回新配置（链接不变）
if [ -f /etc/sb-argo/argo.env ]; then
    "$SB_PATH" argo reapply || warn "恢复 Argo 备用入口失败，可运行 sb argo 查看"
fi
# 清理 apk/apt 下载缓存（小硬盘）
clean_pkg_cache
