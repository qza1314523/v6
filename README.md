# IPv6 Egress Proxy

基于 HE IPv6 前缀提供两种 HTTP/HTTPS 正向代理入口：端口 `100` 使用前缀内随机 IPv6 源地址，端口 `101` 使用指定的本机 IPv4 源地址。项目只负责代理，不会代替你建立 HE 隧道或自动配置云服务商网络。

> 使用前确认你拥有该 IPv6 前缀，且已按系统/云平台要求完成路由、NDP/邻居发现和防火墙配置。代理默认监听 `0.0.0.0`，生产环境请限制来源 IP，并启用认证。

## Requirements

- Linux，Go 1.21 或更新版本
- 可用的 IPv6 前缀及 IPv6 出站路由
- 对随机 IPv6 源地址进行非本地绑定时，需要 root/capability 和 `net.ipv6.ip_nonlocal_bind=1`

## Build and run

```sh
git clone https://github.com/surfmore/v6.git
cd v6
go test ./...
go build -o ipv6proxy ./cmd/ipv6proxy
sudo ./ipv6proxy \
  -cidr 2001:db8:1234::/48 \
  -real-ipv4 192.0.2.10 \
  -bind 0.0.0.0 \
  -username proxyuser \
  -password 'replace-with-a-strong-password'
```

代理地址：

- `http://<server-ip>:100`：每次新建上游连接时从配置的 IPv6 前缀生成源地址
- `http://<server-ip>:101`：从 `-real-ipv4` 地址发起上游连接

客户端需支持 HTTP CONNECT。Basic 认证通过 `-username` 和 `-password` 同时启用；未配置时代理不做认证，不要将其暴露到公网。

## Options

| Flag | Default | Description |
| --- | --- | --- |
| `-cidr` | required | IPv6 network used as random egress source |
| `-real-ipv4` | required | Local IPv4 source address |
| `-random-ipv6-port` | `100` | Random IPv6 proxy listen port |
| `-real-ipv4-port` | `101` | IPv4 proxy listen port |
| `-bind` | `0.0.0.0` | Listen address; restrict with firewall or bind to a private interface |
| `-username` / `-password` | empty | Enable Basic proxy authentication by supplying both |
| `-auto-route` | `true` | Add a local route for the configured IPv6 CIDR |
| `-auto-forwarding` | `true` | Enable IPv6 forwarding using sysctl |
| `-auto-ip-nonlocal-bind` | `true` | Enable non-local IPv6 binding using sysctl |
| `-verbose` | `false` | Enable goproxy request logging |

Automatic route/sysctl changes need root privileges. Pass `-auto-route=false -auto-forwarding=false -auto-ip-nonlocal-bind=false` when managing networking separately. These system-level changes are not automatically reverted at shutdown.

## Install as a service

On Debian/Ubuntu, run from the cloned repository:

```sh
sudo ./install.sh
sudoedit /etc/default/ipv6proxy
```

Set `IPV6_PROXY_CIDR` and `IPV6_PROXY_REAL_IPV4`, then start the service:

```sh
sudo systemctl enable --now ipv6proxy
sudo systemctl status ipv6proxy
sudo journalctl -u ipv6proxy -f
```

The installer builds `/opt/ipv6proxy/bin/ipv6proxy`. It does not create an HE tunnel, alter `/etc/network/interfaces`, or open firewall ports. Configure those for your environment before enabling the service.

## Development

```sh
gofmt -w ./cmd ./internal
go test ./...
go vet ./...
```

CI runs tests and vet for pushes and pull requests.
