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
command -v curl >/dev/null || missing_packages+=(curl)
command -v modprobe >/dev/null || missing_packages+=(kmod)

if ((${#missing_packages[@]} > 0)); then
  echo "安装缺少的依赖: ${missing_packages[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"
fi

for command in git ip systemctl go gcc curl modprobe; do
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
HE_SERVER_IPV6="${HE_SERVER_IPV6%%/*}"
: "${HE_SERVER_IPV4:?HE_SERVER_IPV4 is required}"
: "${LOCAL_IPV4:?LOCAL_IPV4 is required}"
: "${HE_SERVER_IPV6:?HE_SERVER_IPV6 is required}"
: "${LOCAL_IPV6:?LOCAL_IPV6 is required}"
: "${HE_ROUTED_PREFIX:?HE_ROUTED_PREFIX is required}"
: "${HE_TUNNEL_NAME:?HE_TUNNEL_NAME is required}"

if ! modprobe sit 2>&1; then
  echo "无法加载 Linux sit/6in4 隧道模块。确认内核启用 SIT，并确认云平台允许 IPv4 协议 41。" >&2
  exit 1
fi

TUNNEL_CREATED=0
cleanup() {
  local status=$?
  trap - ERR
  if [[ "$TUNNEL_CREATED" -eq 1 ]]; then
    ip link set "$HE_TUNNEL_NAME" down 2>/dev/null || true
    ip tunnel del "$HE_TUNNEL_NAME" 2>/dev/null || true
  fi
  return "$status"
}
trap cleanup ERR
if ip tunnel show "$HE_TUNNEL_NAME" >/dev/null 2>&1; then
  ip link set "$HE_TUNNEL_NAME" down 2>/dev/null || true
  ip tunnel del "$HE_TUNNEL_NAME" 2>/dev/null || true
fi
if ! add_output=$(ip tunnel add "$HE_TUNNEL_NAME" mode sit remote "$HE_SERVER_IPV4" local "$LOCAL_IPV4" ttl 255 2>&1); then
  echo "创建 6in4 tunnel 失败: $add_output" >&2
  echo "检查本机 IPv4 是否配置在网卡上，并确认云平台允许 IPv4 协议号 41。" >&2
  exit 1
fi
TUNNEL_CREATED=1
ip link set "$HE_TUNNEL_NAME" mtu "${HE_MTU:-1480}"
ip link set "$HE_TUNNEL_NAME" up
ip -6 addr add "$LOCAL_IPV6" dev "$HE_TUNNEL_NAME"
ip -6 route replace "$HE_SERVER_IPV6/128" dev "$HE_TUNNEL_NAME" metric 50
ip -6 route replace "$HE_ROUTED_PREFIX" dev "$HE_TUNNEL_NAME" metric 50
ip -6 route replace default via "$HE_SERVER_IPV6" dev "$HE_TUNNEL_NAME" onlink metric 50
TUNNEL_CREATED=0
trap - ERR
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

get_public_ipv4s() {
  ip -4 -o addr show scope global | awk '{split($4, a, "/"); print a[1]}' | while read -r address; do
    case "$address" in
      10.*|192.168.*|127.*|169.254.*|172.16.*|172.17.*|172.18.*|172.19.*|172.2[0-9].*|172.3[0-1].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) ;;
      *) printf '%s\n' "$address" ;;
    esac
  done
}

select_local_ipv4() {
  local candidates choice count=0
  mapfile -t candidates < <(get_public_ipv4s)
  for address in "${candidates[@]}"; do
    [[ -n "$address" ]] && printf '  %d) %s\n' "$((++count))" "$address" >&2
  done
  if ((count == 0)); then
    echo "未检测到公网 IPv4，请检查网卡后重试。" >&2
    exit 1
  elif ((count == 1)); then
    LOCAL_IPV4="${candidates[0]}"
    echo "自动选择本机 IPv4: $LOCAL_IPV4" >&2
    return
  fi
  while true; do
    printf '请选择本机 IPv4 序号 [1-%d]: ' "$count" >&2
    IFS= read -r choice < /dev/tty || exit 1
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= count)); then
      LOCAL_IPV4="${candidates[$((choice - 1))]}"
      return
    fi
    echo "请输入有效序号。" >&2
  done
}

derive_local_ipv6() {
  local gateway="$1"
  gateway="${gateway%%/*}"
  if [[ "$gateway" =~ ::1$ ]]; then
    printf '%s/64\n' "${gateway%::1}::2"
  else
    echo "HE 服务端 IPv6 网关不是常见的 ::1 格式，无法安全自动生成本机地址。" >&2
    echo "请使用 HE 控制台提供的本机隧道地址重新执行。" >&2
    exit 1
  fi
}

echo
echo "=== HE 6in4 隧道配置 ==="
 echo "HE Tunnelbroker 参数：只需输入三项；本机 IPv4 和隧道 IPv6 自动生成，MTU 固定为 1480。"
prompt_required HE_SERVER_IPV4 "Server IPv4 Address"
prompt_required HE_SERVER_IPV6 "Server IPv6 Address（例如 2001:470:23:5d0::1/64）"
select_local_ipv4
LOCAL_IPV6="$(derive_local_ipv6 "$HE_SERVER_IPV6")"
echo "自动生成本机隧道 IPv6: $LOCAL_IPV6" >&2
prompt_required HE_ROUTED_PREFIX "Routed IPv6 Prefix（/64 或 /48）"
HE_MTU=1480

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
echo "代理自动使用 Routed 前缀和已选择的本机 IPv4。"
IPV6_PROXY_CIDR="$HE_ROUTED_PREFIX"
IPV6_PROXY_REAL_IPV4="$LOCAL_IPV4"
prompt_optional IPV6_PROXY_RANDOM_PORT "随机 IPv6 代理端口" "100"
while true; do
  prompt_optional IPV6_PROXY_REAL_PORT "IPv4 代理端口" "101"
  [[ "$IPV6_PROXY_REAL_PORT" != "$IPV6_PROXY_RANDOM_PORT" ]] && break
  echo "两个代理端口不能相同，请重新输入。" >&2
done

cat > "$PROXY_ENV_FILE" <<EOF
IPV6_PROXY_CIDR=$IPV6_PROXY_CIDR
IPV6_PROXY_REAL_IPV4=$IPV6_PROXY_REAL_IPV4
IPV6_PROXY_RANDOM_PORT=$IPV6_PROXY_RANDOM_PORT
IPV6_PROXY_REAL_PORT=$IPV6_PROXY_REAL_PORT
IPV6_PROXY_ALLOW_ANONYMOUS=false
IPV6_PROXY_MAX_CONCURRENT=256
EOF
if ! grep -q '^IPV6_PROXY_PHP_ENABLED=' "$PROXY_ENV_FILE" 2>/dev/null; then
  printf 'IPV6_PROXY_PHP_ENABLED=false\n' >> "$PROXY_ENV_FILE"
fi
if ! grep -q '^IPV6_PROXY_ALLOW_ANONYMOUS=' "$PROXY_ENV_FILE" 2>/dev/null; then
  printf 'IPV6_PROXY_ALLOW_ANONYMOUS=false\n' >> "$PROXY_ENV_FILE"
fi
if ! grep -q '^IPV6_PROXY_MAX_CONCURRENT=' "$PROXY_ENV_FILE" 2>/dev/null; then
  printf 'IPV6_PROXY_MAX_CONCURRENT=256\n' >> "$PROXY_ENV_FILE"
fi

cat > "$PROXY_SERVICE" <<EOF
[Unit]
Description=IPv6 egress proxy
Requires=he-ipv6.service
After=he-ipv6.service network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/ipv6proxy-start
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

cat > /usr/local/sbin/ipv6proxy-start <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source "$PROXY_ENV_FILE"
if [[ -f "$HE_ENV_FILE" ]]; then
  source "$HE_ENV_FILE"
  IPV6_PROXY_CIDR="${HE_ROUTED_PREFIX:-$IPV6_PROXY_CIDR}"
  IPV6_PROXY_REAL_IPV4="${LOCAL_IPV4:-$IPV6_PROXY_REAL_IPV4}"
fi
args=(-cidr "\$IPV6_PROXY_CIDR" -real-ipv4 "\$IPV6_PROXY_REAL_IPV4" -random-ipv6-port "\$IPV6_PROXY_RANDOM_PORT" -real-ipv4-port "\$IPV6_PROXY_REAL_PORT" -php-proxy="\${IPV6_PROXY_PHP_ENABLED:-false}" -allow-anonymous="\${IPV6_PROXY_ALLOW_ANONYMOUS:-false}" -max-concurrent="\${IPV6_PROXY_MAX_CONCURRENT:-256}")
if [[ "\${IPV6_PROXY_PHP_ENABLED:-false}" == true ]]; then
  args+=(-tls-cert /etc/letsencrypt/live/ipv6proxy-ip/fullchain.pem -tls-key /etc/letsencrypt/live/ipv6proxy-ip/privkey.pem)
fi
exec "$INSTALL_DIR/bin/ipv6proxy" "\${args[@]}"
EOF
chmod 0755 /usr/local/sbin/ipv6proxy-start

cat > /usr/local/sbin/ipv6proxyctl <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
HE_ENV_FILE="$HE_ENV_FILE"
PROXY_ENV_FILE="$PROXY_ENV_FILE"
SRC_DIR="$INSTALL_DIR/src"
BIN="$INSTALL_DIR/bin/ipv6proxy"

pause() { read -r -p "按 Enter 返回菜单..." _ < /dev/tty || true; }

service_state() {
  local unit="\$1"
  printf '%-22s active=%-10s enabled=%s\n' "\$unit" "\$(systemctl is-active "\$unit" 2>/dev/null || true)" "\$(systemctl is-enabled "\$unit" 2>/dev/null || true)"
}

show_status() {
  service_state he-ipv6.service
  service_state ipv6proxy.service
  echo "监听端口:"
  ss -lntup | grep -E ':(\${IPV6_PROXY_RANDOM_PORT:-100}|\${IPV6_PROXY_REAL_PORT:-101})([[:space:]]|$)' || echo "  未发现代理监听"
  echo "IPv6 路由:"
  ip -6 route show default || true
  echo "有效代理 CIDR: \$(sed -n 's/^HE_ROUTED_PREFIX=//p' "\$HE_ENV_FILE")"
  echo "运行参数: \$(tr '\0' ' ' < /proc/\$(systemctl show -p MainPID --value ipv6proxy.service)/cmdline)"
}

diagnose() {
  echo "== 服务状态 =="
  show_status
  echo "== 隧道 =="
  ip tunnel show "\$(awk -F= '/^HE_TUNNEL_NAME=/{print \$2}' "\$HE_ENV_FILE")" 2>/dev/null || true
  echo "== 最近日志 =="
  journalctl -u he-ipv6.service -u ipv6proxy.service -n 30 --no-pager
}

test_proxy() {
  source "\$PROXY_ENV_FILE"
  local failed=0 ipaddr scheme="http"
  [[ "\${IPV6_PROXY_PHP_ENABLED:-false}" == true ]] && scheme="https"
  for spec in "\$IPV6_PROXY_RANDOM_PORT https://api64.ipify.org IPv6" "\$IPV6_PROXY_REAL_PORT https://api.ipify.org IPv4"; do
    read -r port url label <<< "\$spec"
    if ipaddr=\$(curl --silent --show-error --fail --insecure --max-time 20 --proxy "\${scheme}://127.0.0.1:\$port" "\$url"); then
      printf '%s 端口 %s 成功，出口 IP: %s\n' "\$label" "\$port" "\$ipaddr"
    else
      printf '%s 端口 %s 失败\n' "\$label" "\$port" >&2
      failed=1
    fi
  done
  return "\$failed"
}

start_services() {
  systemctl start he-ipv6.service
  ip -6 route show default | grep -q 'dev he-ipv6' || { echo "HE 默认 IPv6 路由未建立" >&2; journalctl -u he-ipv6.service -n 50 --no-pager >&2; return 1; }
  systemctl start ipv6proxy.service
  systemctl is-active --quiet ipv6proxy.service
}

update_binary() {
  git -C "\$SRC_DIR" fetch --depth 1 origin main
  git -C "\$SRC_DIR" reset --hard origin/main
  (cd "\$SRC_DIR" && go test ./... && go vet ./... && go build -trimpath -ldflags='-s -w' -o "\$BIN" ./cmd/ipv6proxy)
  systemctl restart ipv6proxy.service
}

toggle_php_proxy() {
  source /etc/default/ipv6proxy
  CERTBOT_VENV="/opt/ipv6proxy/certbot-venv"
  CERTBOT="\$CERTBOT_VENV/bin/certbot"
  if [[ "\${IPV6_PROXY_PHP_ENABLED:-false}" == true ]]; then
    sed -i 's/^IPV6_PROXY_PHP_ENABLED=.*/IPV6_PROXY_PHP_ENABLED=false/' "\$PROXY_ENV_FILE"
    echo "PHP 代理已关闭。"
  else
    if [[ ! -x "\$CERTBOT" ]]; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-venv python3-pip
      python3 -m venv "\$CERTBOT_VENV"
      "\$CERTBOT_VENV/bin/pip" install --upgrade pip certbot
    fi
    public_ipv4="\$(curl -4fsS --max-time 10 https://api.ipify.org)" || { echo "无法检测公网 IPv4，PHP 代理保持关闭。" >&2; return 1; }
    [[ "\$public_ipv4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "公网 IPv4 无效，PHP 代理保持关闭。" >&2; return 1; }
    if [[ ! -s /etc/letsencrypt/live/ipv6proxy-ip/fullchain.pem || ! -s /etc/letsencrypt/live/ipv6proxy-ip/privkey.pem ]]; then
      "\$CERTBOT" --version
      "\$CERTBOT" certonly --standalone --preferred-profile shortlived --ip-address "\$public_ipv4" --http-01-port 80 --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring --cert-name ipv6proxy-ip || { echo "公网 IP 证书申请失败，PHP 代理保持关闭。" >&2; return 1; }
    fi
    cat > /etc/systemd/system/ipv6proxy-cert-renew.service <<'UNIT'
[Unit]
Description=Renew IPv6 Proxy public IP certificate

[Service]
Type=oneshot
ExecStart=/opt/ipv6proxy/certbot-venv/bin/certbot renew --deploy-hook "systemctl try-restart ipv6proxy.service"
UNIT
    cat > /etc/systemd/system/ipv6proxy-cert-renew.timer <<'UNIT'
[Unit]
Description=Renew IPv6 Proxy certificate twice daily

[Timer]
OnCalendar=*-*-* 03,15:00:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    sed -i 's/^IPV6_PROXY_PHP_ENABLED=.*/IPV6_PROXY_PHP_ENABLED=true/' "\$PROXY_ENV_FILE"
    if ! grep -q ' -tls-cert ' /etc/systemd/system/ipv6proxy.service; then
      sed -i "s#^ExecStart=.*#ExecStart=\$BIN -cidr \$IPV6_PROXY_CIDR -real-ipv4 \$IPV6_PROXY_REAL_IPV4 -random-ipv6-port \$IPV6_PROXY_RANDOM_PORT -real-ipv4-port \$IPV6_PROXY_REAL_PORT -php-proxy \$IPV6_PROXY_PHP_ENABLED -tls-cert /etc/letsencrypt/live/ipv6proxy-ip/fullchain.pem -tls-key /etc/letsencrypt/live/ipv6proxy-ip/privkey.pem#" /etc/systemd/system/ipv6proxy.service
    fi
    systemctl enable --now ipv6proxy-cert-renew.timer
    echo "PHP 代理已开启。"
  fi
  systemctl daemon-reload
  systemctl restart ipv6proxy.service
  systemctl is-active --quiet ipv6proxy.service
}

while true; do
  echo
  echo "IPv6 Proxy 管理菜单"
  echo "1) 查看运行状态"
  echo "2) 运行完整诊断"
  echo "3) 测试 IPv4/IPv6 代理出口"
  echo "4) 启动服务"
  echo "5) 重启服务"
  echo "6) 停止服务"
  echo "7) 设置开机自启动"
  echo "8) 取消开机自启动"
  echo "9) 编辑配置"
  echo "10) 更新程序并重建"
  echo "11) PHP 代理: \$(awk -F= '/^IPV6_PROXY_PHP_ENABLED=/{print \$2}' "\$PROXY_ENV_FILE") (切换开/关)"
  echo "0) 退出"
  read -r -p "请选择 [0-11]: " choice < /dev/tty
  case "\$choice" in
    1) show_status; pause ;;
    2) diagnose; pause ;;
    3) test_proxy; pause ;;
    4) start_services; pause ;;
    5) systemctl restart he-ipv6.service && start_services; pause ;;
    6) systemctl stop ipv6proxy.service he-ipv6.service; pause ;;
    7) systemctl enable he-ipv6.service ipv6proxy.service; pause ;;
    8) systemctl disable he-ipv6.service ipv6proxy.service; pause ;;
    9) "\${EDITOR:-nano}" "\$HE_ENV_FILE"; "\${EDITOR:-nano}" "\$PROXY_ENV_FILE"; systemctl daemon-reload; pause ;;
    10) update_binary; pause ;;
    11) toggle_php_proxy; pause ;;
    0) exit 0 ;;
    *) echo "无效选项，请输入 0-11" ;;
  esac
done
EOF
chmod 0755 /usr/local/sbin/ipv6proxyctl

systemctl daemon-reload
printf "现在启动 HE 隧道和代理服务？[Y/n]: " >&2
IFS= read -r START_NOW < /dev/tty || exit 1
if [[ ! "$START_NOW" =~ ^[Nn]$ ]]; then
  systemctl enable he-ipv6.service ipv6proxy.service
  if ! systemctl start he-ipv6.service; then
    echo "HE 隧道启动失败，最近日志：" >&2
    journalctl -u he-ipv6.service -n 80 --no-pager >&2
    echo "当前 IPv6 路由：" >&2
    ip -6 route >&2 || true
    exit 1
  fi
  if ! ip -6 route show default | grep -q 'default via .* dev he-ipv6'; then
    echo "HE 隧道默认 IPv6 路由未建立，最近日志：" >&2
    ip -6 route >&2 || true
    systemctl stop he-ipv6.service
    exit 1
  fi
  systemctl start ipv6proxy.service
  sleep 1
  if ! systemctl is-active --quiet ipv6proxy.service; then
    echo "代理服务启动失败，最近日志：" >&2
    journalctl -u ipv6proxy.service -n 50 --no-pager >&2
    exit 1
  fi
  echo "HE 隧道和代理已启动。"
  echo "开始测试代理出口 IP..."
  for proxy_spec in "$IPV6_PROXY_RANDOM_PORT https://api64.ipify.org IPv6" "$IPV6_PROXY_REAL_PORT https://api.ipify.org IPv4"; do
    read -r proxy_port proxy_url proxy_family <<< "$proxy_spec"
    if proxy_ip=$(curl --silent --show-error --fail --max-time 20 --proxy "http://127.0.0.1:$proxy_port" "$proxy_url"); then
      echo "$proxy_family 端口 $proxy_port 测试成功，出口 IP: $proxy_ip"
    else
      echo "$proxy_family 端口 $proxy_port 测试失败，请检查: journalctl -u ipv6proxy -n 50 --no-pager" >&2
    fi
  done
else
  echo "已跳过启动。稍后执行: systemctl enable --now ipv6proxy"
fi
