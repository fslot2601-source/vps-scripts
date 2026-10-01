# VPS 脚本

## Snell 一键安装

固定安装 Surge 官方 **Snell Server 5.0.1**，不自动升级。

### GitHub 一键下载安装

在 VPS 终端执行（下载成功后才启动安装）：

```bash
curl -fL --retry 2 https://raw.githubusercontent.com/fslot2601-source/vps-scripts/main/install-snell.sh -o install-snell.sh && sudo bash install-snell.sh
```

输入 `yes` 或 `on` 即可。命令会将脚本保存到当前目录；请勿在有同名重要文件的目录运行。使用 root 且系统没有 sudo 时，将末尾的 `sudo bash` 改为 `bash`。

GitHub 仓库：https://github.com/fslot2601-source/vps-scripts

### 手动上传使用

1. 将 `install-snell.sh` 上传到 VPS。
2. 在 VPS 上执行：

   ```bash
   sudo bash install-snell.sh
   ```

   已用 root 登录时，可以执行 `bash install-snell.sh`。
3. 输入 `yes`（也接受 `y` 或 `on`）。其他输入或直接回车会取消。
4. 将最后输出的节点行加入 Surge 配置的 `[Proxy]` 段，然后在 Surge 中测试。

不需要手填端口、密码或 IP，也不需要域名和证书。端口从 20000–49999 中随机选择并检查 TCP/UDP 占用；密钥为随机生成的 32 位十六进制字符串。

### 安装完成后的显示

结果面板会单独列出 **服务器 IP、连接端口、完整密钥、协议版本和服务状态**，并在醒目的分隔线之间输出一整行可复制的 Surge 节点配置。

- 成功状态绿色，IP 与端口青色，节点行加粗，安全组提醒黄色。
- 复制节点行到 Surge 的 `[Proxy]` 段，不要复制标题或边框。
- 输出重定向到文件时自动禁用颜色；也支持 `NO_COLOR=1`。
- `/etc/snell/surge-proxy.txt` 始终保存不含颜色或边框的纯节点行。

Gitea 镜像：[PI/vps-scripts](http://10.0.0.98:3000/PI/vps-scripts)（内网访问，每 8 小时从 GitHub 同步）。后续修改以 GitHub 为主，不直接编辑镜像。

### 支持范围

- Debian 11+、Ubuntu 22.04+，使用 systemd。
- x86_64 / ARM64。
- 能通过 HTTPS 下载官方安装包、有公网 IPv4 的 VPS。
- 不支持纯 IPv6 VPS、Alpine、普通 Docker 容器。
- NAT VPS 需要另行设置端口映射并调整输出中的端口，不能保证全自动连接。

### 自动处理的内容

- 通过 apt 安装 curl、unzip、openssl 等所需工具。
- 仅从 `https://dl.nssurge.com/` 下载固定版本安装包。
- 创建独立低权限账户 `snell-auto`，使用 systemd 管理服务、开机启动、失败重启。
- 检查本机 TCP 监听；开启中的 UFW/firewalld 放行所选端口的 TCP 和 UDP。
- 保留已有 Snell：检测到相关文件、服务或进程时停止，不覆盖。
- 安装失败且服务尚未通过检查时，撤回本次创建的服务、配置、二进制和账户；apt 安装的工具保留。

**云厂商安全组仍需放行输出的端口（TCP 和 UDP）。** 脚本不能从 VPS 内修改云平台安全组，也不会关闭防火墙或修改自定义 nftables/iptables 规则。v5 的 QUIC 代理模式需要 UDP。

“本机启动成功”不代表公网已连通；必须在 Surge 中做实际连接测试。公网 IP 查询会访问 api.ipify.org，失败时尝试 ipv4.icanhazip.com。

### 文件与日常查看

| 内容 | 路径 |
| --- | --- |
| 服务程序 | `/usr/local/bin/snell-server` |
| 服务端配置 | `/etc/snell/snell-server.conf` |
| Surge 节点行（含密钥，仅 root 可读） | `/etc/snell/surge-proxy.txt` |
| systemd 服务 | `/etc/systemd/system/snell.service` |

```bash
# 查看服务状态
sudo systemctl status snell --no-pager

# 查看最近日志
sudo journalctl -u snell -n 50 --no-pager

# 重启
sudo systemctl restart snell

# 查看生成的 Surge 节点行
sudo cat /etc/snell/surge-proxy.txt
```

节点行包含密钥，请勿公开。脚本没有配置自动升级；后续维护时再更新版本。

### 验证边界

已通过 Bash 语法、IPv4 地址校验、随机端口范围、TCP/UDP 占用匹配、macOS 误运行保护、模拟 Debian/Ubuntu 系统变量加载、防覆盖创建、回滚保留无关文件，以及防火墙查询失败后继续输出配置的检查；也实际下载检查了官方 amd64 / aarch64 安装包中的 Linux 程序。macOS 不能验证 Linux 二进制运行、systemd 和真实防火墙行为，尚未在真实 VPS 上完成安装及 Surge 端到端连接测试。

官方参考：[Snell 发布说明](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell) · [Surge 配置格式](https://manual.nssurge.com/policies/snell.html)
