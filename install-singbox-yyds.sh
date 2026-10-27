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
        err "请使用: sudo bash -c \"\$(curl -fsSL ...)\" 或切换到 root 用户"
        exit 1
    fi
}

check_root

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
echo ""
echo "请输入节点连接 IP 或 DDNS域名(留空默认出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"

# 如果用户选择了 Reality 协议，询问 server_name(SNI)
REALITY_SNI=""
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    echo ""
    echo "请输入 Reality 的 SNI(留空默认 addons.mozilla.org):"
    read -r REALITY_SNI
    REALITY_SNI="$(echo "${REALITY_SNI:-addons.mozilla.org}" | tr -d '[:space:]')"
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
# 配置端口和密码
get_config() {
    info "开始配置端口和密码..."
    
    if $ENABLE_SS; then
        info "=== 配置 Shadowsocks (SS) ==="
        if [ -n "${SINGBOX_PORT_SS:-}" ]; then
            PORT_SS="$SINGBOX_PORT_SS"
        else
            read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_PORT_SS
            PORT_SS="${USER_PORT_SS:-$(rand_port)}"
        fi
        PSK_SS=$(rand_pass)
        info "SS 端口: $PORT_SS"
        info "SS 加密方式: $SS_METHOD"
        info "SS 密码已自动生成"
    fi

    if $ENABLE_HY2; then
        info "=== 配置 Hysteria2 (HY2) ==="
        if [ -n "${SINGBOX_PORT_HY2:-}" ]; then
            PORT_HY2="$SINGBOX_PORT_HY2"
        else
            read -p "请输入 HY2 端口(留空则随机 10000-60000): " USER_PORT_HY2
            PORT_HY2="${USER_PORT_HY2:-$(rand_port)}"
        fi
        PSK_HY2=$(rand_pass)
        info "HY2 端口: $PORT_HY2"
        info "HY2 密码已自动生成"
    fi

    if $ENABLE_TUIC; then
        info "=== 配置 TUIC ==="
        if [ -n "${SINGBOX_PORT_TUIC:-}" ]; then
            PORT_TUIC="$SINGBOX_PORT_TUIC"
        else
            read -p "请输入 TUIC 端口(留空则随机 10000-60000): " USER_PORT_TUIC
            PORT_TUIC="${USER_PORT_TUIC:-$(rand_port)}"
        fi
        PSK_TUIC=$(rand_pass)
        UUID_TUIC=$(rand_uuid)
        info "TUIC 端口: $PORT_TUIC"
        info "TUIC UUID 和密码已自动生成"
    fi

    if $ENABLE_REALITY; then
        info "=== 配置 VLESS Reality ==="
        if [ -n "${SINGBOX_PORT_REALITY:-}" ]; then
            PORT_REALITY="$SINGBOX_PORT_REALITY"
        else
            read -p "请输入 VLESS Reality 端口(留空则随机 10000-60000): " USER_PORT_REALITY
            PORT_REALITY="${USER_PORT_REALITY:-$(rand_port)}"
        fi
        UUID=$(rand_uuid)
        info "VLESS Reality 端口: $PORT_REALITY"
        info "VLESS Reality UUID 已自动生成"
    fi
    
    if $ENABLE_ANYTLS; then
    info "=== 配置 AnyTLS Reality ==="
    if [ -n "${SINGBOX_PORT_ANYTLS:-}" ]; then
        PORT_ANYTLS="$SINGBOX_PORT_ANYTLS"
    else
        read -p "请输入 AnyTLS Reality 端口(留空则随机 10000-60000): " USER_PORT_ANYTLS
        PORT_ANYTLS="${USER_PORT_ANYTLS:-$(rand_port)}"
    fi

    ANYTLS_USER=$(openssl rand -hex 4)
    ANYTLS_PSK=$(openssl rand -base64 16)

    info "AnyTLS Reality 端口: $PORT_ANYTLS"
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

install_singbox

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
# 生成配置文件
CONFIG_PATH="/etc/sing-box/config.json"

create_config() {
    info "生成配置文件: $CONFIG_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"

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

    sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1 \
       && info "配置文件验证通过" \
       || warn "配置文件验证失败,但继续执行"

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
        
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || {
            err "服务启动失败"
            journalctl -u sing-box -n 30 --no-pager
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
# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://ipecho.net/plain"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 如果用户提供了 CUSTOM_IP，则优先使用；否则自动检测出口 IP
if [ -n "${CUSTOM_IP:-}" ]; then
    PUB_IP="$CUSTOM_IP"
    info "使用用户提供的连接IP或ddns域名 : $PUB_IP"
else
    PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
    if [ "$PUB_IP" = "YOUR_SERVER_IP" ]; then
        warn "无法获取公网 IP,请手动替换"
    else
        info "检测到公网 IP: $PUB_IP"
    fi
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
    local host="$PUB_IP"
    
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

# 获取公网IP（原始方法；仅接受合法 IP，避免把错误页面当成 IP）
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && validate_host "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    echo "YOUR_SERVER_IP"
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

    # 优先使用用户自定义入口 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        PUBLIC_IP="$CUSTOM_IP"
    else
        PUBLIC_IP=$(get_public_ip)
    fi

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

# 重置SS端口
action_reset_ss() {
    read_config || return 1
    
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        err "SS 协议未启用"
        return 1
    fi
    
    read -p "输入新的 SS 端口(回车保持 $SS_PORT): " new_port
    new_port="${new_port:-$SS_PORT}"
    
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
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi
    
    info "更新完成,已重启服务..."
    if command -v sing-box >/dev/null 2>&1; then
        NEW_VER=$(sing-box version 2>/dev/null | head -n1)
        info "当前版本: $NEW_VER"
        service_restart || warn "重启失败"
    fi
}

# 卸载
action_uninstall() {
    read -p "确认卸载 sing-box?(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && info "已取消" && return 0
    
    info "正在卸载..."
    service_stop || true
    if [ "$OS" = "alpine" ]; then
        rc-update del sing-box default 2>/dev/null || true
        rm -f /etc/init.d/sing-box
        apk del sing-box 2>/dev/null || true
    else
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        apt purge -y sing-box >/dev/null 2>&1 || true
    fi
    rm -rf /etc/sing-box /var/log/sing-box* /usr/local/bin/sb /usr/bin/sing-box /root/node_names.txt 2>/dev/null || true
    info "卸载完成"
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
    if jq -e '[(.outbounds // [])[] | select(.tag=="relay-out")] | length > 0' "$CONFIG_PATH" >/dev/null 2>&1; then
        warn "本机 config.json 含有 relay-out 出站，看起来是线路机！此功能应在【落地机】上运行。"
    fi

    # 落地机入口地址：NAT/转发机上自动检测到的通常是【出口IP】，客户端/线路机连不上，
    # 因此不再静默使用检测结果，必须由用户确认或输入商家提供的【入口IP/连接地址】
    local INBOUND_IP="" DETECTED_IP confirm input_ip SSH_PORT DETECTED_SSH_PORT input_ssh
    DETECTED_IP="$(normalize_host "$(get_public_ip)")"
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

    cat > "$RELAY_SCRIPT" <<'RELAY_EOF'
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

CONFIG="/etc/sing-box/config.json"
RELAY_ENV="/etc/sing-box/relay.env"
RELAY_URI_FILE="/etc/sing-box/relay_uri.txt"
SELF_COPY="/etc/sing-box/relay-install.sh"

# 直连节点默认关闭（旧版 relay.env 里没有这些字段）
DIRECT_ENABLED=false
DIRECT_PORT=""
DIRECT_UUID=""
DIRECT_NAME=""

# 节点名称 URL 编码（支持中文/空格）
uri_encode() { jq -rn --arg v "$1" '$v|@uri'; }

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# 端口是否已被占用（检测不到工具时视为未占用）
port_in_use() {
    local addrs=""
    if command -v ss >/dev/null 2>&1; then
        addrs=$(ss -lntu 2>/dev/null | awk 'NR>1{print $5}' || true)
    elif command -v netstat >/dev/null 2>&1; then
        addrs=$(netstat -lntu 2>/dev/null | awk '{print $4}' || true)
    fi
    printf '%s\n' "$addrs" | grep -qE "[:.]$1\$"
}

# 端口是否属于本机现有 sing-box 配置（重新安装/改配置时允许沿用自己的端口）
own_port() {
    [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1 \
        && jq -e --argjson p "$1" 'any((.inbounds // [])[]; .listen_port == $p)' "$CONFIG" >/dev/null 2>&1
}

# 询问端口：$1=提示 $2=需避开的端口(可空)；结果放在 ASKED_PORT
ask_port() {
    local prompt="$1" avoid="${2:-}" p
    while true; do
        read -r -p "$prompt" p
        if [ -z "$p" ]; then
            p=$(shuf -i 20000-65000 -n 1 2>/dev/null || echo $(( (RANDOM % 45000) + 20000 )))
            if [ "$p" = "$avoid" ] || port_in_use "$p"; then continue; fi
        fi
        if ! valid_port "$p"; then err "端口无效: $p（需为 1-65535 的数字）"; continue; fi
        if [ -n "$avoid" ] && [ "$p" = "$avoid" ]; then err "不能与中转节点端口 $avoid 相同"; continue; fi
        if port_in_use "$p" && ! own_port "$p"; then err "端口 $p 已被占用，请换一个"; continue; fi
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

# 根据 relay.env 生成链接并写入 relay_uri.txt（不改动运行中的配置）
build_link() {
    set_pub_ip_uri
    RELAY_URI=$(make_link "$UUID" "$LISTEN_PORT" "$NODE_NAME")
    mkdir -p /etc/sing-box
    echo "$RELAY_URI" > "$RELAY_URI_FILE"
    if [ "$DIRECT_ENABLED" = "true" ]; then
        DIRECT_URI=$(make_link "$DIRECT_UUID" "$DIRECT_PORT" "$DIRECT_NAME")
        echo "$DIRECT_URI" >> "$RELAY_URI_FILE"
    fi
}

save_env() {
    mkdir -p /etc/sing-box
    {
        printf 'UUID=%q\n' "$UUID"
        printf 'PUB_IP=%q\n' "$PUB_IP"
        printf 'LISTEN_PORT=%q\n' "$LISTEN_PORT"
        printf 'REALITY_PUB=%q\n' "$REALITY_PUB"
        printf 'REALITY_SID=%q\n' "$REALITY_SID"
        printf 'RELAY_SNI=%q\n' "$RELAY_SNI"
        printf 'NODE_NAME=%q\n' "$NODE_NAME"
        printf 'DIRECT_ENABLED=%q\n' "$DIRECT_ENABLED"
        printf 'DIRECT_PORT=%q\n' "$DIRECT_PORT"
        printf 'DIRECT_UUID=%q\n' "$DIRECT_UUID"
        printf 'DIRECT_NAME=%q\n' "$DIRECT_NAME"
    } > "$RELAY_ENV"
    chmod 600 "$RELAY_ENV"
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
}

show_link() {
    if [ -f "$RELAY_ENV" ] && command -v jq >/dev/null 2>&1; then
        load_env
        build_link
        echo "=============== 中转节点(出口落地机) ==============="
        echo "$RELAY_URI"
        if [ "$DIRECT_ENABLED" = "true" ]; then
            echo "=============== 直连节点(出口本机) ================="
            echo "$DIRECT_URI"
        fi
        echo "===================================================="
    elif [ -f "$RELAY_URI_FILE" ]; then
        echo "=============== 中转节点 Reality 链接 ==============="
        cat "$RELAY_URI_FILE"
        echo "===================================================="
    else
        err "未找到 $RELAY_URI_FILE"
        return 1
    fi
}

# 修改节点名称：只重新生成链接和 relay_uri.txt，不动 config.json / 服务
rename_node() {
    load_env || return 1
    local which="1" new_name
    if [ "$DIRECT_ENABLED" = "true" ]; then
        echo "要修改哪个节点的名称?"
        echo "1) 中转节点(出口落地机): $NODE_NAME"
        echo "2) 直连节点(出口本机)  : $DIRECT_NAME"
        read -r -p "请选择(回车默认 1): " which
        which="${which:-1}"
    fi
    if [ "$which" = "2" ] && [ "$DIRECT_ENABLED" = "true" ]; then
        read -r -p "请输入新的直连节点名称(回车保持「$DIRECT_NAME」): " new_name
        DIRECT_NAME="${new_name:-$DIRECT_NAME}"
        info "✅ 直连节点名称: $DIRECT_NAME（未改动运行中的配置）"
    else
        read -r -p "请输入新的中转节点名称(回车保持「$NODE_NAME」): " new_name
        NODE_NAME="${new_name:-$NODE_NAME}"
        info "✅ 中转节点名称: $NODE_NAME（未改动运行中的配置）"
    fi
    save_env
    build_link
    show_link
}

svc_restart() {
    if command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box restart
    else
        systemctl restart sing-box
    fi
}

check_config() {
    if command -v sing-box >/dev/null 2>&1 && ! sing-box check -c "$CONFIG"; then
        return 1
    fi
    return 0
}

# 向 config.json 加入直连 inbound（复用中转节点的 Reality 密钥/SNI/short_id）和路由规则
apply_direct_config() {
    local tmp="${CONFIG}.tmp"
    jq --argjson port "$DIRECT_PORT" --arg uuid "$DIRECT_UUID" '
      ((.inbounds // []) | map(select(.tag=="vless-in")) | .[0].tls) as $tls
      | .inbounds = ([(.inbounds // [])[] | select(.tag != "vless-direct-in")] + [{
          "type": "vless",
          "listen": "::",
          "listen_port": $port,
          "users": [{ "uuid": $uuid, "flow": "xtls-rprx-vision" }],
          "tls": $tls,
          "tag": "vless-direct-in"
        }])
      | .outbounds = ((.outbounds // []) | if any(.[]; .tag=="direct-out") then . else . + [{"type":"direct","tag":"direct-out"}] end)
      | .route.rules = ([(.route.rules // [])[] | select(.inbound != "vless-direct-in")] + [{ "inbound": "vless-direct-in", "outbound": "direct-out" }])
    ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

remove_direct_config() {
    local tmp="${CONFIG}.tmp"
    jq '
      .inbounds = [(.inbounds // [])[] | select(.tag != "vless-direct-in")]
      | .route.rules = [(.route.rules // [])[] | select(.inbound != "vless-direct-in")]
    ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

# 询问直连节点端口/名称（结果写入 DIRECT_* 变量）
ask_direct() {
    ask_port "请输入直连节点监听端口(回车随机 20000-65000，不能与中转端口 $LISTEN_PORT 相同): " "$LISTEN_PORT"
    DIRECT_PORT="$ASKED_PORT"
    DIRECT_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || sing-box generate uuid)
    local def="直连-$PUB_IP" n
    read -r -p "请输入直连节点名称/备注(回车默认「$def」): " n
    DIRECT_NAME="${n:-$def}"
    DIRECT_ENABLED=true
}

# 已安装后：添加/删除直连节点（会修改 config.json 并重启服务，修改前自动备份）
manage_direct() {
    load_env || return 1
    local bak ans
    bak="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    if [ "$DIRECT_ENABLED" = "true" ]; then
        echo "当前已有直连节点(出口本机)，端口: $DIRECT_PORT，名称: $DIRECT_NAME"
        read -r -p "是否删除该直连节点?(y/N): " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return 0; }
        cp "$CONFIG" "$bak"
        remove_direct_config
        DIRECT_ENABLED=false; DIRECT_PORT=""; DIRECT_UUID=""; DIRECT_NAME=""
    else
        ask_direct
        cp "$CONFIG" "$bak"
        apply_direct_config
    fi
    if ! check_config; then
        err "新配置校验失败，已还原: $bak"
        cp "$bak" "$CONFIG"
        return 1
    fi
    info "配置已备份到: $bak，正在重启 sing-box..."
    svc_restart || warn "重启失败，请检查: sing-box check -c $CONFIG"
    save_env
    build_link
    show_link
    [ "$DIRECT_ENABLED" = "true" ] && warn "记得在云厂商安全组/防火墙放行直连端口 $DIRECT_PORT (TCP)"
    return 0
}

# ===== 入口：参数 / 已安装时的菜单 =====
MODE="${1:-}"
case "$MODE" in
    rename) rename_node; exit $? ;;
    show|link) show_link; exit $? ;;
    direct) manage_direct; exit $? ;;
    install|"") ;;
    *) err "未知参数: $MODE（可用: install | rename | show | direct）"; exit 1 ;;
esac

if [ -z "$MODE" ] && [ -f "$RELAY_ENV" ]; then
    echo "检测到本机已安装线路机配置:"
    echo "1) 重新安装（会覆盖 /etc/sing-box/config.json，旧文件自动备份）"
    echo "2) 修改节点名称"
    echo "3) 查看链接"
    echo "4) 添加/删除直连节点(出口本机)"
    echo "0) 退出"
    read -r -p "请选择: " choice
    case "$choice" in
        1) ;;
        2) rename_node; exit $? ;;
        3) show_link; exit $? ;;
        4) manage_direct; exit $? ;;
        *) exit 0 ;;
    esac
fi

detect_os(){
    . /etc/os-release 2>/dev/null || true
    case "${ID:-}" in
        alpine) OS=alpine ;;
        debian|ubuntu) OS=debian ;;
        centos|rhel|fedora) OS=redhat ;;
        *) OS=unknown ;;
    esac
}
detect_os

info "安装依赖..."
case "$OS" in
    alpine) apk update; apk add --no-cache curl jq bash openssl ca-certificates ;;
    debian) apt-get update -y; apt-get install -y curl jq bash openssl ca-certificates ;;
    redhat) yum install -y curl jq bash openssl ca-certificates ;;
esac

info "安装 sing-box..."
case "$OS" in
    alpine) apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box ;;
    *) bash <(curl -fsSL https://sing-box.app/install.sh) ;;
esac

UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")

info "生成 Reality 密钥对"
REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null || echo "")
REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_SID=$(sing-box generate rand 8 --hex 2>/dev/null || echo "0123456789abcdef")
if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ]; then
    err "生成 Reality 密钥失败，请检查 sing-box 是否安装成功"
    exit 1
fi

ask_port "请输入线路机(中转节点)监听端口(留空随机 20000-65000): " ""
LISTEN_PORT="$ASKED_PORT"

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

DEFAULT_NAME="中转-$PUB_IP"
read -r -p "请输入中转节点名称/备注(显示在链接 # 后，回车默认「$DEFAULT_NAME」): " NODE_NAME
NODE_NAME="${NODE_NAME:-$DEFAULT_NAME}"

echo ""
read -r -p "是否同时添加一个本机(线路机)直连出口的 VLESS Reality 节点? (y/N): " ADD_DIRECT
if [[ "$ADD_DIRECT" =~ ^[Yy]$ ]]; then
    ask_direct
fi

mkdir -p /etc/sing-box

if [ -f "$CONFIG" ]; then
    BAK="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    warn "将覆盖已有的 $CONFIG，旧配置已备份到: $BAK"
    cp "$CONFIG" "$BAK"
fi

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

check_config || warn "sing-box 配置校验未通过，请检查: sing-box check -c $CONFIG"

if [ "$OS" = "alpine" ]; then
    cat > /etc/init.d/sing-box <<'SVC'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() { need net; }
SVC
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box restart
else
    cat > /etc/systemd/system/sing-box.service <<'SYSTEMD'
[Unit]
Description=Sing-box Relay
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
fi

# 保存参数并生成链接
save_env
build_link

# 保存一份脚本副本，方便以后改名: bash /etc/sing-box/relay-install.sh rename
if [ -f "$0" ] && [ "$(readlink -f "$0")" != "$SELF_COPY" ]; then
    cp "$0" "$SELF_COPY" 2>/dev/null && chmod +x "$SELF_COPY" || true
fi

echo ""
info "✅ 安装完成"
show_link
echo ""
info "💡 链接已保存到: $RELAY_URI_FILE"
info "💡 查看链接: bash $SELF_COPY show    修改节点名称: bash $SELF_COPY rename"
info "💡 添加/删除直连节点: bash $SELF_COPY direct"
if [ "$DIRECT_ENABLED" = "true" ]; then
    warn "请在云厂商安全组/防火墙(如 Oracle Security List)放行两个端口(TCP): 中转 $LISTEN_PORT 和 直连 $DIRECT_PORT"
else
    warn "请在云厂商安全组/防火墙(如 Oracle Security List)放行端口(TCP): $LISTEN_PORT"
fi
RELAY_EOF

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
    echo "   运行中会问「是否同时添加一个本机(线路机)直连出口的 VLESS Reality 节点?」，不需要就回车(默认 N)。"
    echo "4. 完成后会显示 vless:// 链接（也保存在线路机 /etc/sing-box/relay_uri.txt）："
    echo "   复制到 Shadowrocket(小火箭) 添加节点即可，不需要设置「代理通过」。"
    echo "5. 在线路机的云厂商安全组/防火墙(如 Oracle 的 Security List)放行监听端口(TCP)；若添加了直连节点，两个端口都要放行。"
    echo ""
    warn "线路机脚本会覆盖线路机上已有的 /etc/sing-box/config.json（自动备份为 config.json.bak.时间戳）"
    info "之后在线路机: 修改名称 bash /root/relay-install.sh rename | 查看链接 … show | 添加/删除直连节点 … direct"
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
    echo "$((option))) 卸载 sing-box"
    
    cat <<MENU2
0) 退出
==========================
MENU2
}

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
                update) action_update ;;
                relay) action_generate_relay || true ;;
                uninstall) action_uninstall; exit 0 ;;
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
