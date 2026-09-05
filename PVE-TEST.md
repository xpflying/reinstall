# Proxmox VE 在线重装测试说明

本文件是 fork 的测试记录，记录如何用本脚本把一台机器在线重装成 Proxmox VE。
> 提上游 PR 时应删除本文件，并把 `reinstall.sh` 顶部的 `confhome` / `confhome_cn` 改回上游地址。

## 前置条件

- 架构 x86_64（PVE 官方不支持 ARM）
- 内存至少 1 GB（建议 2 GB 以上），硬盘至少 8 GB
- KVM/独服/普通虚拟机均可；**不支持** OpenVZ、LXC 容器虚拟化
- 虚拟机里跑 PVE 需在宿主机开启嵌套虚拟化，否则虚拟机无法用硬件加速
- 当前系统是任意 Linux（Debian、Ubuntu、CentOS 等都行）

## 一、获取脚本

在要重装的机器上执行其一：

```bash
# 已经 clone 过，直接更新
cd ~/reinstall && git pull

# 或重新下载（走国内 jsDelivr）
curl -O https://cdn.jsdelivr.net/gh/xpflying/reinstall@main/reinstall.sh
```

## 二、执行重装

```bash
# 默认装 proxmox 9（基于 Debian 13）
bash reinstall.sh proxmox --password '你的密码'

# 指定版本：8 基于 Debian 12，9 基于 Debian 13
bash reinstall.sh proxmox 8 --password '你的密码'
```

密码含 `@ # % $` 等特殊字符时用**单引号**包起来。

常用可选参数：

| 参数 | 说明 |
| --- | --- |
| `--password PASS` | 设置 root 密码（Web UI 和 SSH 都用它） |
| `--ssh-key KEY` | 用公钥登录，此时 root 无密码，需登录后 `passwd` 设置 |
| `--ssh-port PORT` | 修改 SSH 端口 |
| `--web-port PORT` | 修改安装期间看日志的 Web 端口（默认 80） |
| `--force-cn` | 强制走国内源（自动识别失灵时用） |
| `--static` | 强制静态 IP，沿用重装前的 IP/网关，避免被判成 DHCP |
| `--hold 2` | 安装完不重启，便于 SSH 进 `/target` 检查 |

只支持 x86_64 和 `root` 用户，传别的用户名会报错。

## 三、国内源

脚本会自动判断地区（curl `www.qualcomm.cn` 的 trace），在国内时自动使用：

- 脚本文件：jsDelivr（`cdn.jsdelivr.net/gh/xpflying/reinstall@main`）
- Debian 源：`mirror.nju.edu.cn/debian`
- Proxmox VE 源：`mirror.nju.edu.cn/proxmox/debian/pve`

一般无需干预。若自动识别成国外导致拉源很慢，加 `--force-cn`。

## 四、观察进度

重启进入安装环境后，PVE 那段要下载约 1.3 GB 软件包，视网速 10~20 分钟。可通过：

- 浏览器打开 `http://机器IP`（安装期间的日志页）
- SSH 登录该机器看 `/var/log/syslog`
- 商家后台 VNC 或串行控制台

## 五、安装完成后

自动重启后进入 PVE：

- 网页端：`https://机器IP:8006`
- 用户名 `root@pam`，密码为上面设置的密码（用 `--ssh-key` 时先 SSH `passwd` 设一个）

## 六、注意事项

- **分区**：单个系统分区，存储为 `local` 目录类型，虚拟机磁盘（qcow2）、容器、ISO、备份都放在 `/var/lib/vz`。没有 `local-lvm`，容器不支持快照；需要的话加第二块硬盘后在网页端建 LVM-Thin 或 ZFS。
- **内核**：用的是 Proxmox 提供的 `pve` 内核，Debian 内核已删除。
- **网络**：脚本保留的是重装前的 **IP 地址**，不是「静态/DHCP 的方式」。安装环境里先跑 DHCP，若 DHCP 能拿到与原来相同的 IP 就用 DHCP，否则回退静态并沿用旧 IP。因此在有 DHCP 保留、能发出同一个 IP 的网络里，原本静态也可能变成 DHCP。这是上游既有逻辑，所有发行版一致。想固定成静态可加 `--static`，它会沿用重装前的 IP 和网关。
- **jsDelivr 缓存**：分支地址有缓存，推新提交后可能拉到旧脚本，用 `curl https://purge.jsdelivr.net/gh/xpflying/reinstall@main/<文件名>` 清缓存后再重装。

## 取消重装

重启前想取消：

```bash
bash reinstall.sh reset
```
