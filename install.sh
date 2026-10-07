#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/surfmore/v6.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/ipv6proxy}"
SERVICE_FILE="/etc/systemd/system/ipv6proxy.service"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 运行: sudo ./install.sh" >&2
  exit 1
fi
for command in apt-get git systemctl; do
  command -v "$command" >/dev/null || { echo "缺少依赖: $command" >&2; exit 1; }
done

if ! command -v go >/dev/null; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends golang-go
fi

mkdir -p "$INSTALL_DIR"
if [[ -d "$INSTALL_DIR/src/.git" ]]; then
  git -C "$INSTALL_DIR/src" fetch --depth 1 origin main
  git -C "$INSTALL_DIR/src" reset --hard origin/main
else
  rm -rf "$INSTALL_DIR/src"
  git clone --depth 1 --branch main "$REPO_URL" "$INSTALL_DIR/src"
fi

mkdir -p "$INSTALL_DIR/bin"
(
  cd "$INSTALL_DIR/src"
  go mod download
  go build -trimpath -ldflags='-s -w' -o "$INSTALL_DIR/bin/ipv6proxy" ./cmd/ipv6proxy
)

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=IPv6 egress proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/bin/ipv6proxy -cidr \\${IPV6_PROXY_CIDR} -real-ipv4 \\${IPV6_PROXY_REAL_IPV4} -random-ipv6-port \\${IPV6_PROXY_RANDOM_PORT:-100} -real-ipv4-port \\${IPV6_PROXY_REAL_PORT:-101}
EnvironmentFile=-/etc/default/ipv6proxy
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

cat > /etc/default/ipv6proxy <<'EOF'
# Required values. Edit before starting the service.
IPV6_PROXY_CIDR=
IPV6_PROXY_REAL_IPV4=
IPV6_PROXY_RANDOM_PORT=100
IPV6_PROXY_REAL_PORT=101
EOF

systemctl daemon-reload
echo "安装完成。编辑 /etc/default/ipv6proxy 后执行:"
echo "  systemctl enable --now ipv6proxy"
