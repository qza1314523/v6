# IPv6 Egress Proxy

## 中文

### 一键部署

```sh
curl -fsSL https://raw.githubusercontent.com/qza1314523/v6/main/install.sh | sudo bash
```

安装程序会自动安装依赖、编译程序、创建 HE 6in4 隧道和代理服务，并询问 HE 参数与代理端口。公网 IPv4 自动检测，多地址时选择序号；隧道 IPv6 自动生成，MTU 固定为 `1480`。启动后会通过两个代理端口请求 `https://api.ipify.org`，显示出口 IP 和测试结果。

### 管理菜单

```sh
sudo ipv6proxyctl
```

菜单支持修改配置、启动、停止、重启、设置或取消开机自启动、更新程序、测试代理出口 IP、查看 systemd 状态和退出。

配置文件：

```text
/etc/default/he-ipv6
/etc/default/ipv6proxy
```

常用命令：

```sh
systemctl status he-ipv6 ipv6proxy
journalctl -u he-ipv6 -u ipv6proxy -f
ip tunnel show he-ipv6
ip -6 addr show dev he-ipv6
ip -6 route
```

云服务器必须允许 IPv4 协议号 `41`，Linux 内核必须支持 `sit` 隧道。

## English

### One-command deployment

```sh
curl -fsSL https://raw.githubusercontent.com/qza1314523/v6/main/install.sh | sudo bash
```

The installer installs dependencies, builds the binary, creates the HE 6in4 tunnel and proxy services, and asks for the HE parameters and proxy ports. The public IPv4 is detected automatically; multiple addresses are shown as a numbered list. The tunnel IPv6 is derived automatically and MTU is fixed at `1480`. After startup, both proxy ports are tested through `https://api.ipify.org` and their egress IPs are printed.

### Management menu

```sh
sudo ipv6proxyctl
```

The menu supports editing configuration, starting, stopping and restarting services, enabling or disabling boot startup, updating the program, testing proxy egress IPs, viewing systemd status and exiting.

Configuration files:

```text
/etc/default/he-ipv6
/etc/default/ipv6proxy
```

Useful commands:

```sh
systemctl status he-ipv6 ipv6proxy
journalctl -u he-ipv6 -u ipv6proxy -f
ip tunnel show he-ipv6
ip -6 addr show dev he-ipv6
ip -6 route
```

The cloud firewall must allow IPv4 protocol 41, and the Linux kernel must support `sit` tunnels.

## Development

```sh
git clone https://github.com/qza1314523/v6.git
cd v6
go test ./...
go vet ./...
go build -o ipv6proxy ./cmd/ipv6proxy
```

CI runs tests and `go vet` for pushes and pull requests.
