#!/bin/sh
# debian installer 分区前调用，清理目标盘上残留的 LVM（含 LVM-thin）和分区表
# 否则在重装 PVE 等使用 LVM-thin 的系统时，d-i 缺少 thin_check 无法拆除精简池，
# 磁盘腾不干净，partman 会报 No root file system。
# 仅处理传入的目标盘，避免误擦其它硬盘。

xda=$1
[ -n "$xda" ] || exit 0
[ -b "/dev/$xda" ] || exit 0

# 拆除目标盘各分区上的卷组和 PV
for pv in /dev/${xda}[0-9]*; do
    [ -b "$pv" ] || continue
    vg=$(pvs --noheadings -o vg_name "$pv" 2>/dev/null | tr -d ' ')
    if [ -n "$vg" ]; then
        vgchange -an "$vg" 2>/dev/null
        vgremove -ff "$vg" 2>/dev/null
    fi
    pvremove -ff -y "$pv" 2>/dev/null
done

# 清理残留的 device-mapper 映射（thin pool 等）
dmsetup remove_all 2>/dev/null

# 擦除各分区头部的文件系统/LVM 签名，以及主/备份 GPT，让 partman 从干净的盘开始
for p in /dev/${xda}[0-9]*; do
    [ -b "$p" ] && dd if=/dev/zero of="$p" bs=1M count=1 conv=fsync 2>/dev/null
done
dd if=/dev/zero of="/dev/$xda" bs=1M count=10 conv=fsync 2>/dev/null
end=$(blockdev --getsz "/dev/$xda" 2>/dev/null)
if [ -n "$end" ]; then
    end=$((end / 2048 - 5))
    [ "$end" -gt 0 ] && dd if=/dev/zero of="/dev/$xda" bs=1M seek="$end" count=5 conv=fsync 2>/dev/null
fi
partprobe "/dev/$xda" 2>/dev/null || blockdev --rereadpt "/dev/$xda" 2>/dev/null

exit 0
