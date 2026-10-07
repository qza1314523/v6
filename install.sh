#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/qza1314523/v6.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/ipv6proxy}"
HE_ENV_FILE="/etc/default/he-ipv6"
PROXY_ENV_FILE="/etc/default/ipv6proxy"
HE_SERVICE="/etc/systemd/system/he-ipv6.service"
PROXY_SERVICE="/etc/systemd/system/ipv6proxy.service"

[[ "${EUID}" -eq 0 ]] || { echo "请使用 root 运行: sudo ./install.sh" >&2; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu 系统" >&2; exit 1; }

missing_packages=()
command -v git >/dev/null || missing_packages+=(git)
command -v ip >/dev/null || missing_packages+=(iproute2)
command -v systemctl >/dev/null || missing_packages+=(systemd)
command -v go >/dev/null || missing_packages+=(golang-go)
command -v gcc >/dev/null || missing_packages+=(build-essential)

if ((${#missing_packages[@]} > 0)); then
  echo "安装缺少的依赖: ${missing_packages[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"
fi

for command in git ip systemctl go gcc; do
  command -v "$command" >/dev/null || { echo "依赖安装失败: $command" >&2; exit 1; }
done

mkdir -p "$INSTALL_DIR"
if [[ -d "$INSTALL_DIR/src/.git" ]]; then
  git -C "$INSTALL_DIR/src" fetch --depth 1 origin main
  git -C "$INSTALL_DIR/src" reset --hard origin/main
else
  rm -rf "$INSTALL_DIR/src"
  git clone --depth 1 --branch main "$REPO_URL" "$INSTALL_DIR/src"
fi

mkdir -p "$INSTALL_DIR/bin"
(cd "$INSTALL_DIR/src" && go mod download && go build -trimpath -ldflags='-s -w' -o "$INSTALL_DIR/bin/ipv6proxy" ./cmd/ipv6proxy)

cat > "$HE_SERVICE" <<'EOF'
[Unit]
Description=Hurricane Electric 6in4 IPv6 tunnel
After=network-online.target
Wants=network-online.target
Before=ipv6proxy.service

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/default/he-ipv6
ExecStart=/usr/local/sbin/he-ipv6-up
ExecStop=/usr/local/sbin/he-ipv6-down

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/sbin/he-ipv6-up <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/default/he-ipv6
: "${HE_SERVER_IPV4:?HE_SERVER_IPV4 is required}"
: "${LOCAL_IPV4:?LOCAL_IPV4 is required}"
: "${HE_SERVER_IPV6:?HE_SERVER_IPV6 is required}"
: "${LOCAL_IPV6:?LOCAL_IPV6 is required}"
: "${HE_ROUTED_PREFIX:?HE_ROUTED_PREFIX is required}"
: "${HE_TUNNEL_NAME:?HE_TUNNEL_NAME is required}"

ip tunnel show "$HE_TUNNEL_NAME" >/dev/null 2>&1 && exit 0
ip tunnel add "$HE_TUNNEL_NAME" mode sit remote "$HE_SERVER_IPV4" local "$LOCAL_IPV4" ttl 255
ip link set "$HE_TUNNEL_NAME" mtu "${HE_MTU:-1480}"
ip link set "$HE_TUNNEL_NAME" up
ip -6 addr add "$LOCAL_IPV6" dev "$HE_TUNNEL_NAME"
ip -6 route replace "$HE_ROUTED_PREFIX" dev "$HE_TUNNEL_NAME"
ip -6 route replace ::/0 via "$HE_SERVER_IPV6" dev "$HE_TUNNEL_NAME"
EOF

cat > /usr/local/sbin/he-ipv6-down <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/default/he-ipv6
ip link set "$HE_TUNNEL_NAME" down 2>/dev/null || true
ip tunnel del "$HE_TUNNEL_NAME" 2>/dev/null || true
EOF
chmod 0755 /usr/local/sbin/he-ipv6-up /usr/local/sbin/he-ipv6-down

prompt_required() {
  local name="$1" label="$2" default="${3:-}" value
  while true; do
    if [[ -n "$default" ]]; then printf "%s [%s]: " "$label" "$default" >&2; else printf "%s: " "$label" >&2; fi
    IFS= read -r value < /dev/tty || { echo "无法读取终端输入" >&2; exit 1; }
    value="${value:-$default}"
    if [[ -n "$value" ]]; then printf -v "$name" '%s' "$value"; return; fi
    echo "该项不能为空" >&2
  done
}

prompt_optional() {
  local name="$1" label="$2" default="$3" value
  printf "%s [%s]: " "$label" "$default" >&2
  IFS= read -r value < /dev/tty || { echo "无法读取终端输入" >&2; exit 1; }
  printf -v "$name" '%s' "${value:-$default}"
}

echo
 echo "=== HE 6in4 隧道配置 ==="
 echo "请填写 HE Tunnelbroker 控制台显示的参数。"
prompt_required HE_SERVER_IPV4 "HE 服务端 IPv4"
prompt_required LOCAL_IPV4 "本机 IPv4"
prompt_required HE_SERVER_IPV6 "HE 服务端 IPv6 网关"
prompt_required LOCAL_IPV6 "本机隧道 IPv6（含前缀，例如 2001:db8:1::2/64）"
prompt_required HE_ROUTED_PREFIX "HE 路由前缀（例如 2001:db8:2::/64）"
prompt_optional HE_MTU "隧道 MTU" "1480"

cat > "$HE_ENV_FILE" <<EOF
HE_SERVER_IPV4=$HE_SERVER_IPV4
LOCAL_IPV4=$LOCAL_IPV4
HE_SERVER_IPV6=$HE_SERVER_IPV6
LOCAL_IPV6=$LOCAL_IPV6
HE_ROUTED_PREFIX=$HE_ROUTED_PREFIX
HE_TUNNEL_NAME=he-ipv6
HE_MTU=$HE_MTU
EOF

echo
 echo "=== 代理配置 ==="
prompt_optional IPV6_PROXY_CIDR "随机 IPv6 源地址前缀" "$HE_ROUTED_PREFIX"
prompt_required IPV6_PROXY_REAL_IPV4 "IPv4 出站地址" "$LOCAL_IPV4"
prompt_optional IPV6_PROXY_RANDOM_PORT "随机 IPv6 代理端口" "100"
prompt_optional IPV6_PROXY_REAL_PORT "IPv4 代理端口" "101"

cat > "$PROXY_ENV_FILE" <<EOF
IPV6_PROXY_CIDR=$IPV6_PROXY_CIDR
IPV6_PROXY_REAL_IPV4=$IPV6_PROXY_REAL_IPV4
IPV6_PROXY_RANDOM_PORT=$IPV6_PROXY_RANDOM_PORT
IPV6_PROXY_REAL_PORT=$IPV6_PROXY_REAL_PORT
EOF

cat > "$PROXY_SERVICE" <<EOF
[Unit]
Description=IPv6 egress proxy
Requires=he-ipv6.service
After=he-ipv6.service network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/bin/ipv6proxy -cidr \\${IPV6_PROXY_CIDR} -real-ipv4 \\${IPV6_PROXY_REAL_IPV4} -random-ipv6-port \\${IPV6_PROXY_RANDOM_PORT:-100} -real-ipv4-port \\${IPV6_PROXY_REAL_PORT:-101}
EnvironmentFile=-$PROXY_ENV_FILE
WorkingDirectory=$INSTALL_DIR
Restart=on-failure
RestartSec=3
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo
echo "配置已写入 $HE_ENV_FILE 和 $PROXY_ENV_FILE"
printf "现在启动 HE 隧道和代理服务？[Y/n]: " >&2
IFS= read -r START_NOW < /dev/tty || exit 1
if [[ ! "$START_NOW" =~ ^[Nn]$ ]]; then
  systemctl enable he-ipv6.service ipv6proxy.service
  systemctl start he-ipv6.service
  systemctl start ipv6proxy.service
  echo "HE 隧道和代理已启动。"
else
  echo "已跳过启动。稍后执行: systemctl enable --now ipv6proxy"
fi