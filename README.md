# IPv6 Egress Proxy

基于 HE IPv6 前缀提供两种 HTTP/HTTPS 正向代理入口：端口 `100` 使用前缀内随机 IPv6 源地址，端口 `101` 使用指定的本机 IPv4 源地址。项目只负责代理，不会代替你建立 HE 隧道或自动配置云服务商网络。

> 使用前确认你拥有该 IPv6 前缀，且已按系统/云平台要求完成路由、NDP/邻居发现和防火墙配置。代理默认监听 `0.0.0.0`，生产环境请限制来源 IP，并启用认证。

## Requirements

- Linux，Go 1.21 或更新版本
- HE Tunnelbroker 账号提供的 6in4 参数，或已经建立好的 IPv6 网络
- 对随机 IPv6 源地址进行非本地绑定时，需要 root/capability 和 `net.ipv6.ip_nonlocal_bind=1`
- Linux 内核启用 `sit`/6in4 支持；云主机还必须允许协议号 41（IPv6-in-IPv4）

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

## Install HE 6in4 tunnel and proxy

The installer creates two systemd units:

- `he-ipv6.service`: creates and removes the Linux `sit` tunnel
- `ipv6proxy.service`: starts after the tunnel is active

Run on Debian/Ubuntu:

```sh
sudo ./install.sh
sudoedit /etc/default/he-ipv6
```

Fill the values from HE Tunnelbroker. Example:

```ini
HE_SERVER_IPV4=198.51.100.1
LOCAL_IPV4=203.0.113.10
HE_SERVER_IPV6=2001:db8:1::1
LOCAL_IPV6=2001:db8:1::2/64
HE_ROUTED_PREFIX=2001:db8:2::/64
HE_TUNNEL_NAME=he-ipv6
HE_MTU=1480
```

`HE_SERVER_IPV4` is the HE endpoint, `LOCAL_IPV4` is an IPv4 address assigned to this host, `HE_SERVER_IPV6` is the tunnel peer gateway, `LOCAL_IPV6` is the local tunnel address, and `HE_ROUTED_PREFIX` is the routed prefix used by the proxy. Replace all documentation addresses with the real values from HE; the example uses documentation-only ranges.

Then configure the proxy:

```sh
sudoedit /etc/default/ipv6proxy
sudo systemctl enable --now he-ipv6
ping -6 -c 3 2606:4700:4700::1111
sudo systemctl enable --now ipv6proxy
sudo systemctl status he-ipv6 ipv6proxy
sudo journalctl -u he-ipv6 -u ipv6proxy -f
```

The host or cloud firewall must allow IPv4 protocol 41 between this machine and the HE endpoint. If the tunnel fails, check `ip tunnel show he-ipv6`, `ip -6 addr show dev he-ipv6`, and `ip -6 route`. The installer does not alter `/etc/network/interfaces` or open firewall ports.

## Development

```sh
gofmt -w ./cmd ./internal
go test ./...
go vet ./...
```

CI runs tests and vet for pushes and pull requests.
