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
        GO_MEMLIMIT="$((MEM_MIB * 75 / 100))MiB"
        warn "检测到本机可用内存只有约 ${MEM_MIB} MiB（≤256 MiB），已启用低内存模式："
        warn "   sing-box 服务将设置 GOMEMLIMIT=${GO_MEMLIMIT} GOGC=70，减少被系统 OOM 杀掉的概率"
        warn "   建议下面只选 1~2 个协议（例如只选 VLESS Reality，或 Reality + SS）"
    elif [ "$MEM_MIB" -gt 0 ]; then
        info "内存: 约 ${MEM_MIB} MiB"
    fi
}

detect_mem

# -----------------------
# 安装依赖
install_deps() {
    info "安装系统依赖..."
    
    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; exit 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl jq || {
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
    local nets="$1" p r lo hi
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
    if [ "${#NAT_RANGES[@]}" -gt 0 ]; then
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
            if [ "${#NAT_RANGES[@]}" -gt 0 ] && ! port_in_ranges "$p"; then
                warn "端口 $p 不在你填写的商家端口范围(${NAT_PORT_RANGE})内，NAT 机器上外网很可能连不上"
                read -r -p "仍然使用 $p ?(y/N): " ans || ans=""
                [[ "$ans" =~ ^[Yy]$ ]] || continue
            fi
            if port_busy_os "$p" "$nets"; then
                warn "端口 $p 已被本机程序占用（如果是旧的 sing-box 占用，重装后会自动释放，可以继续）"
                read -r -p "仍然使用 $p ?(y/N): " ans || ans=""
                [[ "$ans" =~ ^[Yy]$ ]] || continue
            fi
        fi
        break
    done
    for n in $nets; do
        if [ "$n" = "tcp" ]; then USED_TCP[$p]="$label"; else USED_UDP[$p]="$label"; fi
    done
    CHOSEN_PORT="$p"
}

udp_reminder() {
    warn "$1 使用 UDP 端口 $2：NAT 机器必须确认商家把这个端口的【UDP】也映射了（很多 NAT 只映射 TCP），"
    warn "   云厂商安全组/防火墙也要放行 UDP $2，否则 $1 连不上。"
}

# -----------------------
# 配置端口和密码
get_config() {
    info "开始配置端口和密码..."

    # NAT 模式：商家只给了一段端口时，随机端口只在这段范围里挑
    NAT_PORT_RANGE="${SINGBOX_NAT_PORTS:-}"
    if [ -z "$NAT_PORT_RANGE" ]; then
        echo ""
        echo "如果这是 NAT 机器(商家只给了部分端口，例如 56566-56586)，请输入商家给的端口范围，脚本只在其中随机选端口。"
        echo "多个范围/端口用逗号分隔，例如: 56566-56586 或 20001,20002,20003 。普通 VPS 直接回车跳过。"
        read -r -p "商家端口范围(回车跳过): " NAT_PORT_RANGE || NAT_PORT_RANGE=""
    fi
    while [ -n "$NAT_PORT_RANGE" ] && ! parse_port_ranges "$NAT_PORT_RANGE"; do
        err "端口范围格式不对: '$NAT_PORT_RANGE'（例: 56566-56586 或 20001,20002）"
        read -r -p "商家端口范围(回车跳过): " NAT_PORT_RANGE || NAT_PORT_RANGE=""
    done
    if [ -n "$NAT_PORT_RANGE" ]; then
        info "NAT 模式：随机端口只从 ${NAT_PORT_RANGE} 中选择"
        info "提示：Reality/AnyTLS(TCP) 和 HY2/TUIC(UDP) 可以使用同一个端口号；SS 同时占用该端口的 TCP 和 UDP"
    fi

    if $ENABLE_SS; then
        info "=== 配置 Shadowsocks (SS) ==="
        ask_proto_port "SS" "${SINGBOX_PORT_SS:-}" "tcp udp"
        PORT_SS="$CHOSEN_PORT"
        PSK_SS=$(rand_pass)
        info "SS 端口: $PORT_SS (TCP+UDP)"
        info "SS 加密方式: $SS_METHOD"
        info "SS 密码已自动生成"
    fi

    if $ENABLE_HY2; then
        info "=== 配置 Hysteria2 (HY2) ==="
        ask_proto_port "HY2" "${SINGBOX_PORT_HY2:-}" "udp"
        PORT_HY2="$CHOSEN_PORT"
        PSK_HY2=$(rand_pass)
        info "HY2 端口: $PORT_HY2 (UDP)"
        info "HY2 密码已自动生成"
        udp_reminder "HY2" "$PORT_HY2"
    fi

    if $ENABLE_TUIC; then
        info "=== 配置 TUIC ==="
        ask_proto_port "TUIC" "${SINGBOX_PORT_TUIC:-}" "udp"
        PORT_TUIC="$CHOSEN_PORT"
        PSK_TUIC=$(rand_pass)
        UUID_TUIC=$(rand_uuid)
        info "TUIC 端口: $PORT_TUIC (UDP)"
        info "TUIC UUID 和密码已自动生成"
        udp_reminder "TUIC" "$PORT_TUIC"
    fi

    if $ENABLE_REALITY; then
        info "=== 配置 VLESS Reality ==="
        ask_proto_port "VLESS Reality" "${SINGBOX_PORT_REALITY:-}" "tcp"
        PORT_REALITY="$CHOSEN_PORT"
        UUID=$(rand_uuid)
        info "VLESS Reality 端口: $PORT_REALITY (TCP)"
        info "VLESS Reality UUID 已自动生成"
    fi

    if $ENABLE_ANYTLS; then
        info "=== 配置 AnyTLS Reality ==="
        ask_proto_port "AnyTLS Reality" "${SINGBOX_PORT_ANYTLS:-}" "tcp"
        PORT_ANYTLS="$CHOSEN_PORT"
        ANYTLS_USER=$(openssl rand -hex 4)
        ANYTLS_PSK=$(openssl rand -base64 16)
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
        read -p "是否重新安装?(y/N): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "跳过 sing-box 安装"
            return 0
        fi
    fi

    case "$OS" in
        alpine)
            info "使用 Edge 仓库安装 sing-box"
            apk update || { err "apk update 失败"; exit 1; }
            apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        debian|redhat)
            bash <(curl -fsSL https://sing-box.app/install.sh) || {
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
    "level": "info",
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
    echo ""
    info "💡 从外网测试 TCP 端口是否通: 打开 https://www.itdog.cn/tcping/ 或 https://ping.pe/ ，输入 你的IP:端口"
    info "💡 UDP 端口(HY2/TUIC)无法用 tcping 测试，请直接用客户端连接测试"
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
info "🔧 管理命令:"
if [ "$OS" = "alpine" ]; then
    echo "   启动: rc-service sing-box start"
    echo "   停止: rc-service sing-box stop"
    echo "   重启: rc-service sing-box restart"
    echo "   状态: rc-service sing-box status"
    echo "   日志: tail -f /var/log/sing-box.log"
else
    echo "   启动: systemctl start sing-box"
    echo "   停止: systemctl stop sing-box"
    echo "   重启: systemctl restart sing-box"
    echo "   状态: systemctl status sing-box"
    echo "   日志: journalctl -u sing-box -f"
fi
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
relay_port_taken() {
    [ -f "$RELAY_HOME/config.json" ] && jq -e --argjson p "$1" 'any((.inbounds // [])[]; .listen_port == $p)' "$RELAY_HOME/config.json" >/dev/null 2>&1
}

# 新端口校验：数字 1-65535，且不能和本机线路机节点冲突
check_new_port() {
    if ! validate_port "$1"; then
        err "端口无效: $1（需为 1-65535 的数字）"
        return 1
    fi
    if relay_port_taken "$1"; then
        err "端口 $1 已被本机的线路机节点(sing-box-relay，$RELAY_HOME/config.json)使用，请换一个"
        return 1
    fi
    return 0
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
        apk update && apk upgrade sing-box || bash <(curl -fsSL https://sing-box.app/install.sh)
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
        rm -f /usr/bin/sing-box 2>/dev/null || true
        if [ -L /usr/bin/sb ] && [ ! -e /usr/bin/sb ]; then rm -f /usr/bin/sb; fi
    fi
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
    if [ -f "$RELAY_HOME/relay.env" ] && { [ ! -f "$RELAY_SELF" ] || ! grep -q 'SVC_NAME="sing-box-relay"' "$RELAY_SELF" 2>/dev/null; }; then
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
    local addrs=""
    if command -v ss >/dev/null 2>&1; then
        addrs=$(ss -lntu 2>/dev/null | awk 'NR>1{print $5}' || true)
    elif command -v netstat >/dev/null 2>&1; then
        addrs=$(netstat -lntu 2>/dev/null | awk '{print $4}' || true)
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
    local prompt="$1" avoid=" ${2:-} " strict="${3:-}" p
    while true; do
        read -r -p "$prompt" p || { err "没有读到输入，已取消"; return 1; }
        p=$(printf '%s' "$p" | tr -d '[:space:]')
        if [ -z "$p" ]; then
            p=$(rand_free_port "${2:-}" "$strict") || { err "没找到空闲端口，请手动输入"; continue; }
            info "随机端口: $p"
        fi
        if ! valid_port "$p"; then err "端口无效: $p（需为 1-65535 的数字）"; continue; fi
        p=$((10#$p))
        if [[ "$avoid" == *" $p "* ]]; then err "端口 $p 已被本机其他节点使用，请换一个"; continue; fi
        if landing_port "$p"; then err "端口 $p 已被本机的落地机节点($LANDING_CONFIG)使用，请换一个"; continue; fi
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
    elif [ -f "$RELAY_URI_FILE" ]; then
        echo "=============== 中转节点 Reality 链接 ==============="
        cat "$RELAY_URI_FILE"
        echo "===================================================="
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

# 写入服务文件并设置开机自启（不启动）
install_service() {
    local bin
    bin=$(singbox_bin)
    case "$(svc_kind)" in
        openrc)
            cat > "$OPENRC_INIT" <<SVC
#!/sbin/openrc-run
name="${SVC_NAME}"
description="sing-box relay (线路机中转/直连节点)"
command="${bin}"
command_args="run -c ${CONFIG}"
command_background="yes"
pidfile="/run/${SVC_NAME}.pid"
output_log="/var/log/${SVC_NAME}.log"
error_log="/var/log/${SVC_NAME}.err"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}
SVC
            chmod +x "$OPENRC_INIT"
            rc-update add "$SVC_NAME" default >/dev/null 2>&1 || warn "添加开机自启失败: rc-update add $SVC_NAME default"
            ;;
        systemd)
            cat > "$SYSTEMD_UNIT" <<SVC
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

[Install]
WantedBy=multi-user.target
SVC
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
    if ! service_installed; then install_service || true; fi
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
    remove_service
    rm -rf "$SB_DIR"
    rm -f "/var/log/${SVC_NAME}.log" "/var/log/${SVC_NAME}.err"
    if is_shim "$SHIM"; then rm -f "$SHIM"; fi
    if is_shortcut "$SB_CMD"; then
        rm -f "$SB_CMD"
        if [ -L /usr/bin/sb ] && [ ! -e /usr/bin/sb ]; then rm -f /usr/bin/sb; fi
    fi
    info "✅ 线路机节点已卸载"
    if [ ! -f "$LANDING_CONFIG" ]; then
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
    echo "0) 退出"
    echo "===================================================="
    read -r -p "请选择(直接回车 = 1): " choice || choice=0
    case "${choice:-1}" in
        1) append_node; return $? ;;
        2) show_link; return $? ;;
        3) rename_node; return $? ;;
        4) delete_node; return $? ;;
        5) manage_direct; return $? ;;
        6) svc_restart && info "已重启 $SVC_NAME"; svc_status; return 0 ;;
        7) open_landing; return $? ;;
        8) uninstall_relay; return $? ;;
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
            alpine) apk update; apk add --no-cache curl jq bash openssl ca-certificates ;;
            debian) apt-get update -y; apt-get install -y curl jq bash openssl ca-certificates ;;
            redhat) yum install -y curl jq bash openssl ca-certificates ;;
        esac
    fi

    if command -v sing-box >/dev/null 2>&1; then
        info "本机已安装 sing-box: $(sing-box version 2>/dev/null | head -n1)（与落地机节点共用同一个程序）"
    else
        info "安装 sing-box..."
        case "$OS" in
            alpine) apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box ;;
            *) bash <(curl -fsSL https://sing-box.app/install.sh) ;;
        esac
    fi
    command -v sing-box >/dev/null 2>&1 || { err "sing-box 安装失败"; return 1; }

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

    PUB_IP=""
    for ip_url in https://api.ipify.org https://api64.ipify.org https://icanhazip.com; do
        PUB_IP=$(curl -s --max-time 5 "$ip_url" 2>/dev/null | tr -d '[:space:]' || true)
        # 只接受像 IP 的结果（防止把错误页面写进链接）
        if [[ "$PUB_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ "$PUB_IP" =~ ^[0-9A-Fa-f:]+$ && "$PUB_IP" == *:*:* ]]; then
            break
        fi
        PUB_IP=""
    done
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
  "log": { "level": "info", "timestamp": true },
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
  "log": { "level": "info", "timestamp": true },
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
    return 0
}

# ===== 入口 =====
MODE="${1:-}"
case "$MODE" in
    help|-h|--help) usage; exit 0 ;;
    shortcut) install_shortcut; exit 0 ;;
esac

# 旧版线路机（节点在 /etc/sing-box）先迁移到独立目录/服务；迁移失败就停下，绝不另装一套
maybe_migrate || exit 1

case "$MODE" in
    rename) rename_node; exit $? ;;
    show|link) show_link; exit $? ;;
    direct) manage_direct; exit $? ;;
    append|add) append_node; exit $? ;;
    delete|del|remove) delete_node; exit $? ;;
    upgrade|migrate) do_upgrade; exit $? ;;
    uninstall) uninstall_relay; exit $? ;;
    restart) svc_restart && info "已重启 $SVC_NAME"; svc_status; exit 0 ;;
    status) svc_status; exit 0 ;;
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

            # 让用户选择端口（校验 1-65535）
            while true; do
                read -r -p "请输入 SS 端口(NAT 机器请填商家映射的端口，留空则随机 10000-60000): " USER_SS_PORT
                SS_PORT="${USER_SS_PORT:-$(rand_port)}"
                if ! validate_port "$SS_PORT"; then
                    err "端口无效: $SS_PORT (需为 1-65535 的数字)"
                elif jq -e --argjson p "$SS_PORT" 'any((.inbounds // [])[]; .listen_port == $p)' "$CONFIG_PATH" >/dev/null 2>&1; then
                    err "端口 $SS_PORT 已被本机其他节点使用，请换一个"
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
    detect_public_ip || true
    DETECTED_IP="$(normalize_host "${DETECTED_IP:-YOUR_SERVER_IP}")"
    [ -n "${NAT_REASON:-}" ] && warn "$NAT_REASON"
    echo ""
    info "=== 设置落地机(本机)入口地址 ==="
    echo "   入口IP: 线路机/客户端连接本机用的地址（通常就是你 SSH 登录用的 IP，或商家给的 NAT 入口IP/域名）"
    echo "   出口IP: 本机访问外网时显示的 IP。NAT/转发机上出口IP 与入口IP 往往不同，填出口IP 将无法连接！"
    echo "   参考 - 自动检测到的出口IP: ${DETECTED_IP} （NAT 机器上通常不可用）"
    echo "   注意 - NAT 机器上 SS 端口(${SS_PORT})必须是商家映射给你的端口之一，否则线路机无法连到落地机"
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
    
    cat <<MENU2
0) 退出
==========================
MENU2
}

# 命令行快捷方式: sb relay = 线路机/直连节点管理
case "${1:-}" in
    relay) action_relay_local; exit $? ;;
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
                status) service_status ;;
                update) action_update || true ;;
                relay) action_generate_relay || true ;;
                uninstall) action_uninstall; exit 0 ;;
                relay_local) action_relay_local || true ;;
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
if [ -f /etc/sing-box-relay/relay.env ]; then
    info "本机的线路机(中转/直连)节点由独立服务 sing-box-relay 运行，未受影响；在 sb 菜单最后一项「线路机/直连节点管理」里管理"
fi
