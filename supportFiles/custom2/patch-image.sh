#!/bin/bash
# patch-image.sh —— wukongdaily 系 x86 固件镜像预处理器
#
# 做两件事（都可单独关闭）：
#   [1] 幂等化 /etc/uci-defaults/99-custom.sh
#       —— 已有配置（含升级后恢复的配置）时不再覆盖用户设置
#       标记文件 /etc/config/.99_custom_done 会随 sysupgrade 配置备份一起保存/恢复
#   [2] 烘焙 /etc/config/fstab 的 extroot 项
#       —— 让固件启动时优先把「独立数据分区」挂成 /overlay
#          标签固定为 IMMO_OVERLAY / ext4；分区不存在时自动回落到内部 overlay（安全）
#
# 不改分区表、不改 p1(kernel/FAT)、不改镜像 UUID；只重写 p2 里的 squashfs 内容。
#
# 用法：
#   patch-image.sh <img> [out.img]           # 原地或另存
#   BAKE_EXTROOT=0 patch-image.sh <img>      # 只做 [1]，不烘焙 extroot
#   EXTROOT_LABEL=MY_LABEL patch-image.sh …  # 换标签
#
# 需要 root（unsquashfs 要还原 /dev 节点）与 parted / squashfs-tools。

set -Eeuo pipefail

IN="${1:?用法: patch-image.sh <img> [out.img]}"
OUT="${2:-$IN}"
BAKE_EXTROOT="${BAKE_EXTROOT:-1}"
EXTROOT_LABEL="${EXTROOT_LABEL:-IMMO_OVERLAY}"

WORK="$(mktemp -d /tmp/patchimg.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

CHANGED=0

echo "[1/6] 读取 p2 几何信息 ..."
LINE="$(parted -ms "$IN" unit s print 2>/dev/null | awk -F: '$1==2 {print; exit}' || true)"
if [ -z "$LINE" ]; then
	echo "[跳过] 没有 GPT/MBR 第 2 分区（例如 ISO 载荷），原样输出。"
	if [ "$IN" != "$OUT" ]; then cp -f "$IN" "$OUT"; fi
	exit 0
fi
P2START="$(echo "$LINE" | cut -d: -f2 | tr -d 's')"
P2END="$(echo "$LINE" | cut -d: -f3 | tr -d 's')"
P2SEC=$((P2END - P2START + 1))
echo "    p2 起始扇区=$P2START 结束扇区=$P2END 共 $((P2SEC * 512 / 1024 / 1024)) MB"

echo "[2/6] 取出 squashfs ..."
dd if="$IN" of="$WORK/root.sq" bs=512 skip="$P2START" count="$P2SEC" status=none
if ! unsquashfs -s "$WORK/root.sq" >/dev/null 2>&1; then
	echo "[跳过] p2 不是 squashfs（可能是 ext4 等），原样输出。"
	if [ "$IN" != "$OUT" ]; then cp -f "$IN" "$OUT"; fi
	exit 0
fi

echo "[3/6] 解包 rootfs ..."
unsquashfs -q -d "$WORK/root" "$WORK/root.sq" >/dev/null

# ---------------------------------------------------------------- 补丁 1：99-custom.sh 幂等
TARGET="$WORK/root/etc/uci-defaults/99-custom.sh"
if [ ! -f "$TARGET" ]; then
	echo "[1/2] 镜像内没有 /etc/uci-defaults/99-custom.sh，跳过幂等补丁。"
elif grep -q 'loticc-custom-guard' "$TARGET" 2>/dev/null; then
	echo "[1/2] 99-custom.sh 已幂等，跳过。"
else
	echo "[1/2] 给 99-custom.sh 插守卫 + 打标记 ..."
	awk '
	{ lines[++n] = $0 }
	END {
		for (i = 1; i <= n; i++) {
			if (i == 1 && lines[1] ~ /^#!/) {
				print lines[1]
				print ""
				print "# loticc-custom-guard: 已有配置（含升级后恢复的配置）时不再覆盖用户设置"
				print "[ -f /etc/config/.99_custom_done ] && exit 0"
			} else if (i == n && lines[i] ~ /^[[:space:]]*exit[[:space:]]+0[[:space:]]*$/) {
				print "mkdir -p /etc/config"
				print "touch /etc/config/.99_custom_done"
				print "exit 0"
			} else {
				print lines[i]
			}
		}
	}' "$TARGET" > "$WORK/99-custom.sh.new"
	if ! grep -q '.99_custom_done' "$WORK/99-custom.sh.new"; then
		{
			echo ""
			echo "# loticc-custom-guard: 打标记，下次升级/恢复配置后不再覆盖"
			echo "mkdir -p /etc/config"
			echo "touch /etc/config/.99_custom_done"
		} >> "$WORK/99-custom.sh.new"
	fi
	chmod 755 "$WORK/99-custom.sh.new"
	mv -f "$WORK/99-custom.sh.new" "$TARGET"
	CHANGED=1
fi

# ---------------------------------------------------------------- 补丁 2：烘焙 extroot fstab
FSTAB="$WORK/root/etc/config/fstab"
if [ "$BAKE_EXTROOT" != "1" ]; then
	echo "[2/2] 按 BAKE_EXTROOT=$BAKE_EXTROOT 跳过 extroot 烘焙。"
elif [ -f "$FSTAB" ] && grep -q "option target '/overlay'" "$FSTAB"; then
	echo "[2/2] fstab 里已有 /overlay extroot 项，跳过。"
else
	echo "[2/2] 烘焙 /etc/config/fstab：label=$EXTROOT_LABEL 的分区挂为 /overlay ..."
	mkdir -p "$WORK/root/etc/config"
	if [ -f "$FSTAB" ]; then
		# 原文件末尾若无换行，补一个，避免新 section 粘在上一行
		[ -n "$(tail -c 1 "$FSTAB")" ] && echo >> "$FSTAB"
		echo >> "$FSTAB"
	fi
	cat >> "$FSTAB" <<EOF
config mount 'auto_overlay'
	option target '/overlay'
	option label '$EXTROOT_LABEL'
	option fstype 'ext4'
	option options 'rw,noatime'
	option enabled '1'
EOF
	chmod 644 "$FSTAB"
	CHANGED=1
fi

if [ "$CHANGED" = "0" ]; then
	echo "没有需要修改的内容，原样输出。"
	if [ "$IN" != "$OUT" ]; then cp -f "$IN" "$OUT"; fi
	exit 0
fi

echo "[4/6] 重新打包 squashfs（xz / 256K，与原镜像一致）..."
mksquashfs "$WORK/root" "$WORK/new.sq" -comp xz -b 256K -noappend -quiet -processors "$(nproc)" >/dev/null
NEWBYTES=$(stat -c %s "$WORK/new.sq")
echo "    新 squashfs: $((NEWBYTES / 1024 / 1024)) MB / p2 可用 $((P2SEC * 512 / 1024 / 1024)) MB"
if [ "$NEWBYTES" -gt $((P2SEC * 512)) ]; then
	echo "错误：新 squashfs 超过 p2 容量，放弃修改"
	exit 1
fi

echo "[5/6] 回写镜像 ..."
cp -f "$IN" "$WORK/out.img"
dd if="$WORK/new.sq" of="$WORK/out.img" bs=512 seek="$P2START" conv=notrunc status=none
sync
mv -f "$WORK/out.img" "$OUT"

echo "[6/6] 完成：$(stat -c %s "$OUT") 字节 → $OUT"
echo "    p1/GPT 未变；rootfs 内已应用：99-custom 幂等 + extroot fstab"
