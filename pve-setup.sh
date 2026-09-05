#!/bin/sh
# shellcheck shell=dash
# shellcheck disable=SC3043

# 本脚本在 debian installer 的 late_command 中运行
# 将已安装到 /target 的 Debian 变成 Proxmox VE
# 步骤跟官方文档一致，只是全部在 chroot 内完成，最后只需重启一次
# https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_12_Bookworm
# https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie

# 注意 debian installer 环境是 busybox，可能没有 awk xargs
# 因此复杂的操作放到 chroot 里面运行

set -e

target=/target
hostname=pve
domain=localdomain

info() {
    echo
    echo "***** $* *****"
}

error_and_exit() {
    echo "Error: $*" >&2
    exit 1
}

# 提取 cmdline 里的 extra_ 变量，例如 pve pve_mirror
for str in $(grep -wo "extra_[^ ]*" /proc/cmdline | sed 's/^extra_//'); do
    eval "$str"
done

[ -n "$pve" ] || error_and_exit "Proxmox VE version not set."
pve_mirror=${pve_mirror:-download.proxmox.com/debian/pve}

# debian 版本代号
codename=$(. $target/etc/os-release && echo "$VERSION_CODENAME")
[ -n "$codename" ] || error_and_exit "Can't get debian codename."

# 获取本机 ip，用于 /etc/hosts
# pmxcfs 要求主机名能解析到非 127.x 的 ip，否则 pve-cluster 无法启动
get_ip() {
    local type file addr

    # 优先使用 initrd-network.sh 保存的网络配置
    for type in ipv4 ipv6; do
        for file in /dev/netconf/*/${type}_addr; do
            if [ -f "$file" ] && addr=$(cut -d/ -f1 "$file" | grep -m1 .); then
                echo "$addr"
                return
            fi
        done
    done

    # 兜底，读取当前 ip
    if addr=$(ip -4 -o addr show scope global | grep -o 'inet [0-9.]*' | cut -d' ' -f2 | grep -m1 .); then
        echo "$addr"
        return
    fi
    if addr=$(ip -6 -o addr show scope global | grep -o 'inet6 [0-9a-fA-F:]*' | cut -d' ' -f2 | grep -m1 .); then
        echo "$addr"
        return
    fi
    return 1
}

download() {
    local url=$1 file=$2 i ret

    for i in 1 2 3 4 5; do
        ret=0
        wget -O "$file" "$url" || ret=$?
        # 防止把错误页面当成 keyring
        if [ "$ret" -eq 0 ] && [ -s "$file" ] && ! grep -iq '<html' "$file"; then
            return 0
        fi
        rm -f "$file"
        # 8 是 http 错误，例如 404，不用重试
        if [ "$ret" -eq 8 ]; then
            return 1
        fi
        sleep 5
    done
    return 1
}

# 国内镜像可能没有同步 keyring，因此再从官方源下载
download_keyring() {
    local name=$1 file=$2 url

    for url in \
        "http://${pve_mirror%/pve}/$name" \
        "https://enterprise.proxmox.com/debian/$name"; do
        if download "$url" "$file"; then
            return
        fi
    done
    error_and_exit "Can't download $name."
}

# 主机名
ip=$(get_ip) || error_and_exit "Can't get ip address."
info "Set hostname $hostname.$domain ($ip)"
echo "$hostname" >$target/etc/hostname
# chroot 里 hostname 命令读的是内核主机名，而安装器环境没有设置主机名
# ssl-cert 等软件包的 postinst 需要 hostname -f 能解析出 FQDN，否则安装失败
# 因此安装器环境也要设置主机名，配合 /target/etc/hosts 才能解析
hostname "$hostname"
cat >$target/etc/hosts <<EOF
127.0.0.1 localhost.localdomain localhost
$ip $hostname.$domain $hostname

::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
EOF

# 添加源
info "Add Proxmox VE repo $pve_mirror"
case "$codename" in
bookworm)
    # https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_12_Bookworm
    download_keyring proxmox-release-bookworm.gpg \
        $target/etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
    echo "deb [arch=amd64] http://$pve_mirror $codename pve-no-subscription" \
        >$target/etc/apt/sources.list.d/pve-install-repo.list
    ;;
*)
    # https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie
    mkdir -p $target/usr/share/keyrings
    download_keyring proxmox-archive-keyring-$codename.gpg \
        $target/usr/share/keyrings/proxmox-archive-keyring.gpg
    cat >$target/etc/apt/sources.list.d/pve-install-repo.sources <<EOF
Types: deb
URIs: http://$pve_mirror
Suites: $codename
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    ;;
esac

# 预设 postfix 配置，避免安装时询问
cat >$target/tmp/pve-debconf.txt <<EOF
postfix postfix/main_mailer_type select Local only
postfix postfix/mailname string $hostname.$domain
EOF
chroot $target debconf-set-selections /tmp/pve-debconf.txt
rm -f $target/tmp/pve-debconf.txt

# 安装
# 官方 iso 安装器安装软件包时也会创建 /proxmox_install_mode
# 有此文件时 pve 软件包的 postinst 不会尝试启动服务
# 证书会在首次开机时由 pveproxy.service 的 ExecStartPre 生成
info "Install Proxmox VE"
touch $target/proxmox_install_mode

# ifupdown2: pve 网页端管理网络需要，安装后会自动删除 ifupdown
# isc-dhcp-client: ifupdown2 不依赖 dhcp 客户端，但 dhcp 机器需要
in-target apt-get update
in-target apt-get install -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    proxmox-default-kernel proxmox-ve ifupdown2 isc-dhcp-client postfix open-iscsi chrony

# 删除 debian 内核，只保留 pve 内核
info "Remove Debian kernel"
kernels=$(chroot $target dpkg -l 'linux-image-*' 2>/dev/null | grep '^ii' | tr -s ' ' | cut -d' ' -f2 | tr '\n' ' ')
if [ -n "$kernels" ]; then
    # shellcheck disable=SC2086
    in-target apt-get purge -y $kernels
fi

# 官方文档建议删除 os-prober
if chroot $target dpkg -s os-prober >/dev/null 2>&1; then
    in-target apt-get purge -y os-prober
fi

# 在 chroot 里安装 pve 内核时，initramfs 的生成被推迟到 dpkg 触发器
# 但触发器只会更新已有的 initrd，导致新内核没有 initrd，也导致 grub 不使用 UUID
# 官方 iso 安装器也是手动生成 initrd，这里同样补上
info "Generate initramfs"
for f in $target/boot/vmlinuz-*; do
    ver=${f##*/vmlinuz-}
    if [ -f "$f" ] && ! [ -e "$target/boot/initrd.img-$ver" ]; then
        in-target update-initramfs -c -k "$ver"
    fi
done

in-target update-grub
in-target apt-get clean

rm -f $target/proxmox_install_mode
info "Proxmox VE installed"
