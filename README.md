# IPv6 Egress Proxy

IPv4/IPv6 双端口 HTTP 正向代理，支持 HE 6in4 隧道、随机 IPv6 源地址、IPv4 固定出口、HTTPS、Basic 认证和可选的 `/Proxy.php` 请求转发。

## 功能

- `:100`：随机 IPv6 源地址出口；`目标`必须支持 IPv6
- `:101`：服务器真实 IPv4 出口
- HTTP forward proxy、HTTPS `CONNECT`、Basic Proxy Authentication
- 可选 `/Proxy.php?url=...`，保留方法、请求头、查询、请求体和响应
- PHP 目标限制为 HTTP/HTTPS，并拒绝本机、私网、链路本地、组播和未指定地址
- 默认并发连接上限 256
- HE 6in4 隧道、Routed IPv6 前缀、systemd 和 `ipv6proxyctl` 管理

## 前置条件

- Debian/Ubuntu、root 权限、内核支持 `sit`
- 云平台允许 IPv4 协议号 `41`
- HE Tunnelbroker 的 Server IPv4、Server IPv6、Routed IPv6 Prefix
- 启用公网 IP HTTPS 时，TCP 80 必须允许 Let’s Encrypt HTTP-01 验证

## 安装

```sh
curl -fsSL https://raw.githubusercontent.com/qza1314523/v6/main/install.sh | sudo bash
```

安装器交互式配置 HE 隧道和端口，随后启动并验证服务。该命令会以 root 执行远程脚本；生产环境建议先下载、审查并固定 commit：

```sh
curl -fsSLo install.sh https://raw.githubusercontent.com/qza1314523/v6/<COMMIT>/install.sh
less install.sh
sudo bash install.sh
```

安装目录为 `/opt/ipv6proxy`，二进制为 `/opt/ipv6proxy/bin/ipv6proxy`。

## 配置

`/etc/default/he-ipv6`：

```text
HE_SERVER_IPV4=74.82.46.6
LOCAL_IPV4=203.0.113.10
HE_SERVER_IPV6=2001:470:23:5d0::1/64
LOCAL_IPV6=2001:470:23:5d0::2/64
HE_ROUTED_PREFIX=2001:470:fe45::/48
HE_TUNNEL_NAME=he-ipv6
HE_MTU=1480
```

`HE_ROUTED_PREFIX` 是 IPv6 代理前缀的唯一来源。修改后选择菜单“重启服务”。

`/etc/default/ipv6proxy`：

```text
IPV6_PROXY_CIDR=2001:470:fe45::/48
IPV6_PROXY_REAL_IPV4=203.0.113.10
IPV6_PROXY_RANDOM_PORT=100
IPV6_PROXY_REAL_PORT=101
IPV6_PROXY_PHP_ENABLED=false
IPV6_PROXY_ALLOW_ANONYMOUS=false
IPV6_PROXY_MAX_CONCURRENT=256
```

程序默认拒绝匿名访问。生产环境配置账号密码，并保持配置文件为 root 私有：

```sh
chmod 600 /etc/default/he-ipv6 /etc/default/ipv6proxy
chown root:root /etc/default/he-ipv6 /etc/default/ipv6proxy
```

匿名模式必须显式设置 `IPV6_PROXY_ALLOW_ANONYMOUS=true`，不建议公网使用。HTTP Basic 认证不是加密传输，应配合 HTTPS 或防火墙来源限制。

主要命令行参数：`-bind`、`-username`、`-password`、`-allow-anonymous`、`-max-concurrent`、`-php-proxy`、`-tls-cert`、`-tls-key`、`-auto-route`、`-auto-forwarding`、`-auto-ip-nonlocal-bind`、`-verbose`。`-use-doh` 是历史配置项，目前不会改变实际代理解析行为。

## 代理用法

```sh
curl --proxy http://USER:PASSWORD@156.246.95.73:101 https://api.ipify.org
curl --proxy https://USER:PASSWORD@156.246.95.73:101 https://api.ipify.org
```

证书为公网 IP 证书时，代理主机应使用 `156.246.95.73`。仅本机诊断使用 `--proxy-insecure`，生产环境不要关闭证书验证。

## PHP 转发和 HTTPS

菜单选择 `11) PHP 代理` 会安装 Certbot、申请 Let’s Encrypt 公网 IP 证书、将两个端口切换为 HTTPS，并创建 `ipv6proxy-cert-renew.timer` 自动续期：

```sh
curl --proxy-insecure 'https://156.246.95.73:101/Proxy.php?url=https%3A%2F%2Fapi.ipify.org'
curl --proxy-insecure 'https://156.246.95.73:100/Proxy.php?url=https%3A%2F%2Fapi64.ipify.org'
```

`Proxy.php` 不是开放 SSRF 服务；目标域名解析到本机、私网或链路本地地址时会返回错误。仍建议启用认证、防火墙或目标白名单。

## 管理和排障

```sh
sudo ipv6proxyctl
```

菜单支持状态、完整诊断、IPv4/IPv6 出口测试、启动/重启/停止、开机自启、编辑配置、更新重建和 PHP 开关。HTTPS 测试会使用公网 IP 连接并仅为本机诊断忽略证书校验。

```sh
systemctl status he-ipv6.service ipv6proxy.service
journalctl -u he-ipv6.service -u ipv6proxy.service -n 100 --no-pager
systemctl status ipv6proxy-cert-renew.timer
ss -lntp | grep -E ':100|:101'
ip -6 route
ip tunnel show he-ipv6
```

检查 Routed 前缀是否真正生效：

```sh
grep HE_ROUTED_PREFIX /etc/default/he-ipv6
systemctl restart he-ipv6.service ipv6proxy.service
pid=$(systemctl show -p MainPID --value ipv6proxy.service)
tr '\0' ' ' < /proc/$pid/cmdline
```

进程的 `-cidr` 必须与 `HE_ROUTED_PREFIX` 一致。协议 41 被拦截、TCP 80 未开放、IPv6 访问 IPv4-only 目标、端口被占用，是最常见的故障原因。

## 更新与开发

菜单更新会拉取代码、运行 `go test ./...` 和 `go vet ./...`，构建成功后才替换二进制并重启。生产环境先记录 commit 以便回滚：

```sh
git -C /opt/ipv6proxy/src rev-parse HEAD
cd v6
```

systemd 文件位于 `/etc/systemd/system/`，管理脚本位于 `/usr/local/sbin/`。公网部署至少启用 HTTPS、Basic 认证、防火墙来源限制和合理并发上限。