# ipblock

交互式大陆端口封禁脚本。使用 [mayaxcn/china-ip-list](https://github.com/mayaxcn/china-ip-list) 的中国大陆 IP 段，通过 `ipset + iptables` 屏蔽中国大陆来源访问指定端口。

适合用于：

- 只想屏蔽某个代理/服务端口的大陆来源访问；
- 服务直接监听宿主机端口；
- 服务通过 Docker 端口映射暴露。

> ⚠️ 不要随便对 SSH 端口使用，尤其你自己在大陆网络时，可能会把自己锁在服务器外面。

## 一键交互安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Xiyueyy/ipblock/main/install.sh)
```

或者：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiyueyy/ipblock/main/install.sh | bash
```

安装完成后会进入交互菜单。

## 一键命令模式

屏蔽大陆访问 `25084` 的 TCP 和 UDP：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Xiyueyy/ipblock/main/install.sh) install 25084 both
```

只屏蔽 TCP：

```bash
ipblock install 25084 tcp
```

只屏蔽 UDP：

```bash
ipblock install 25084 udp
```

## 常用命令

```bash
# 交互菜单
ipblock

# 安装/更新某端口规则，并创建开机自启和每日更新
ipblock install 25084 both

# 查看某端口状态
ipblock status 25084

# 列出已安装端口
ipblock list

# 更新所有已安装端口的 IP 库和规则
ipblock update-all

# 删除某端口封禁
ipblock uninstall 25084
```

## IP 库

使用：

- IPv4: `https://raw.githubusercontent.com/mayaxcn/china-ip-list/master/chnroute.txt`
- IPv6: `https://raw.githubusercontent.com/mayaxcn/china-ip-list/master/chnroute_v6.txt`

本地缓存：

```text
/etc/ipblock/chnroute.txt
/etc/ipblock/chnroute_v6.txt
```

## 实现方式

脚本会为每个端口创建独立的 `ipset`：

```text
ipblock_<端口>_v4
ipblock_<端口>_v6
```

然后写入规则：

- `INPUT`：拦截直接监听宿主机的服务；
- `DOCKER-USER`：拦截 Docker 映射端口的流量。

规则只影响指定端口，不会全机屏蔽大陆 IP。

## 自动更新

安装端口规则后，会创建 systemd timer：

```text
ipblock-<端口>.service
ipblock-<端口>.timer
```

默认每天 `04:20` 左右更新一次 IP 库和规则。

可以查看：

```bash
systemctl list-timers 'ipblock-*'
```

## 卸载

删除某端口规则：

```bash
ipblock uninstall 25084
```

如需完全删除脚本：

```bash
rm -f /usr/local/sbin/ipblock
rm -rf /etc/ipblock
```
