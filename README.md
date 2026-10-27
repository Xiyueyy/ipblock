# ipblock

按端口控制入站来源的一键脚本（nftables），两种功能可以同时用：

- **大陆屏蔽**：指定端口丢弃中国大陆 IP 主动发起的连接，可以给大陆中转机等加例外；
- **端口白名单**：指定端口只接受名单内 IP 的连接，每个端口一份名单。

特点：

- 只拦"连进来"的新连接（按 conntrack 方向判断），本机访问大陆网站、其他端口都不受影响；
- 在 prerouting（DNAT 之前）匹配，裸机监听和 Docker 映射端口都能拦；
- 支持 TCP / UDP、IPv4 / IPv6、端口区间；
- 整份规则原子替换，更新时不会出现空窗；开机自动恢复，大陆 IP 库每周自动更新；
- 拒绝对 SSH 端口操作，防止把自己锁在外面。

> 需要 KVM / 独服 / 宿主机；LXC、OpenVZ 容器通常没有 nftables 权限。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Xiyueyy/ipblock/main/install.sh)
```

安装到 `/usr/local/sbin/ipblock` 后进入交互菜单。之后直接执行 `ipblock` 打开菜单，或者用下面的命令。

也可以安装时直接带命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Xiyueyy/ipblock/main/install.sh) cn add 25084
```

## 命令

端口写法：`443`、`443/tcp`、`20000-20010/udp`（不写协议 = TCP+UDP）
IP 写法：`1.2.3.4`、`1.2.3.0/24`、`2001:db8::/32`

### 大陆屏蔽

```bash
ipblock cn add 25084 30000/tcp      # 屏蔽大陆 IP 连这些端口
ipblock cn del 30000/tcp            # 取消
ipblock cn allow 1.2.3.4            # 例外放行（如大陆中转机），只对大陆屏蔽生效
ipblock cn disallow 1.2.3.4         # 移除例外
```

### 端口白名单

```bash
ipblock wl add 3321 1.2.3.4 5.6.7.8 # 3321 只放行这两个 IP（可多次执行追加）
ipblock wl rm 3321 5.6.7.8          # 从名单移除 IP
ipblock wl del 3321                 # 取消 3321 的白名单
```

### 其他

```bash
ipblock status       # 查看端口、名单、IP 库和拦截计数
ipblock update       # 立即更新大陆 IP 库
ipblock off          # 临时关闭（配置保留）
ipblock on           # 按配置恢复
ipblock import       # 导入并替换旧的 cn-port-block / port-allowlist
ipblock uninstall    # 删除全部规则、定时任务、配置和脚本
```

同一个端口可以同时开大陆屏蔽和白名单，两条规则各自生效，任意一条拦下就会被丢弃。

## IP 库

- 主来源：[sapics/ip-location-db](https://github.com/sapics/ip-location-db) 的 GeoLite2 国家库（按实际地理位置划分）；
- 备用：[APNIC 官方分配表](https://ftp.apnic.net/stats/apnic/delegated-apnic-latest)；
- 下载失败时继续使用本地缓存。

不用 chnroute 这类按运营商归属整理的列表：它们会把阿里云美国、新加坡、香港等海外机房（`47.88.x`、`8.209.x` 等）也算成大陆。

## 实现

- nftables 表 `inet ipblock`，在 prerouting（priority -160）按目标端口跳到检查链：`cn` 链查大陆 IP 集合，`wl_<端口>` 链查该端口名单；
- 配置在 `/etc/ipblock/`：`cn.ports`、`cn.allow`、`wl.ports`、`wl/<端口>`，IP 库缓存 `cn4.txt` / `cn6.txt`；
- systemd：`ipblock.service`（开机恢复规则）、`ipblock-update.timer`（每周更新 IP 库）。

## 从旧版升级

- **旧版 ipblock（iptables + ipset）**：新脚本首次运行时自动把已封禁的端口迁移成大陆屏蔽，并清理旧的 iptables 规则、ipset 和 `ipblock-<端口>.service/.timer`；
- **cn-port-block / port-allowlist**：执行 `ipblock import`，配置会导入进来，新规则生效后再删除旧规则和脚本。
