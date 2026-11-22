#!/bin/sh
# ==========================================================================
#  openwrt-extroot.sh  ——  OpenWrt 系一键独立 overlay（扩容 + 插件持久化）
#
#  适用：ImmortalWrt / OpenWrt / iStoreOS 等 x86 或其它 块设备启动 的系统
#
#  它解决的问题
#    1) 官方镜像的 overlay 藏在内核分区 p2 内部，只有几百 MB，
#       装插件必须手动扩容；
#    2) 固件升级时 p2 被整块重写，overlay 归零 → 插件和设置全丢。
#
#  它怎么做
#    把磁盘剩余空间做成独立分区（默认 p3，ext4，label IMMO_OVERLAY），
#    把当前 overlay 的 upper 层（也就是你装的插件本体）复制过去，
#    再写 /etc/config/fstab 让它开机直接挂成 /overlay。
#    这样：
#      · 插件/配置拿到整盘空间，以后不用再手动扩容
#      · 只要磁盘分区表和将来刷的镜像一致，升级只重写 p1/p2，p3 原样保留
#
#  用法
#    sh openwrt-extroot.sh               自动：没迁移就迁移，已迁移就扩容
#    sh openwrt-extroot.sh check         只体检，不动任何东西
#    sh openwrt-extroot.sh migrate       强制迁移（当前 overlay 还在 p2 里）
#    sh openwrt-extroot.sh grow          只扩容（磁盘加大后用）
#    sh openwrt-extroot.sh verify <固件>  升级前体检：这次升级会不会全盘重写
#
#  可调参数（环境变量）
#    LABEL=IMMO_OVERLAY   数据分区标签，默认 IMMO_OVERLAY
#    PARTNUM=3            分区号，默认 3
#    KEEP=1               迁移时保留旧 upper（默认保留，只是复制不删除）
#
#  注意
#    · 需要 root
#    · migrate 会新建分区 + 格式化这个新分区，但绝不碰 p1/p2
#    · migrate 完成后要重启才生效（reboot）
# ==========================================================================

set -u

LABEL="${LABEL:-IMMO_OVERLAY}"
PARTNUM="${PARTNUM:-3}"
MNT="/mnt/extroot-new"

say() { printf '%s\n' "$*"; }
die() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
warn() { printf '[警告] %s\n' "$*"; }
ok() { printf '  [OK] %s\n' "$*"; }

[ "$(id -u)" = "0" ] || die "请用 root 运行（ssh 登录后 sudo -i 或直接 root）"

# ---------------------------------------------------------------- 基础探测

# 由 mountinfo 的 major:minor 反查分区名
part_by_majmin() {
    _mm="$1"
    for _f in /sys/class/block/*/dev; do
        [ -r "$_f" ] || continue
        if [ "$(cat "$_f" 2>/dev/null)" = "$_mm" ]; then
            basename "$(dirname "$_f")"
            return 0
        fi
    done
    return 1
}

mm_to_part() {  # $1 = "8:2" -> /dev/vda2
    _n=$(part_by_majmin "$1" 2>/dev/null) || return 1
    printf '/dev/%s' "$_n"
}

disk_of_part() {  # /dev/vda2 -> /dev/vda
    _p="${1##*/}"
    [ -d "/sys/class/block/$_p" ] || return 1
    _d=$(dirname "$(readlink -f "/sys/class/block/$_p")")
    printf '/dev/%s' "$(basename "$_d")"
}

part_start() { cat "/sys/class/block/${1##*/}/start" 2>/dev/null; }
part_size()  { cat "/sys/class/block/${1##*/}/size"  2>/dev/null; }
blk_size()   { cat "/sys/class/block/${1##*/}/size"  2>/dev/null; }

align_up() {  # $1 值  $2 对齐
    echo $(( ( $1 + $2 - 1 ) / $2 * $2 ))
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 && return 0
    say "  · 缺少 $1，尝试自动安装 ..."
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$2" >/dev/null 2>&1 || apk add "$2" >/dev/null 2>&1
    elif command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1
        opkg install "$2" >/dev/null 2>&1
    fi
    command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------- 现状

# /rom 所在的分区（= 被固件镜像重写的那个分区，通常 p2）
ROM_PART=""
ROM_MM=$(awk '$5=="/rom"{print $3}' /proc/self/mountinfo 2>/dev/null | head -n1)
if [ -n "${ROM_MM:-}" ]; then
    ROM_PART=$(mm_to_part "$ROM_MM" 2>/dev/null || true)
fi
[ -n "$ROM_PART" ] || die "找不到 /rom 所在的分区，无法判断磁盘布局（非 OpenWrt 系统？）"

DISK=$(disk_of_part "$ROM_PART") || die "找不到 /rom 所在的磁盘"
[ -b "$DISK" ] || die "$DISK 不是块设备"

DISK_SECTORS=$(blk_size "$DISK")
[ -n "$DISK_SECTORS" ] || die "读不到磁盘扇区数"

# 当前 /overlay 的来源
OVL_MM=$(awk '$5=="/overlay"{print $3}' /proc/self/mountinfo 2>/dev/null | head -n1)
OVL_PART=""
if [ -n "${OVL_MM:-}" ]; then
    OVL_PART=$(mm_to_part "$OVL_MM" 2>/dev/null || true)
fi

TARGET_PART="${DISK}${PARTNUM}"
case "$DISK" in
    *[0-9]) TARGET_PART="${DISK}p${PARTNUM}" ;;
esac

# upper 层真正的位置（fstools 固定的 /overlay/upper）
UPPER_DIR="/overlay/upper"

# ---------------------------------------------------------------- 报告

show_state() {
    say "=============================================================="
    say " 现状"
    say "=============================================================="
    say " 固件分区(/rom) : $ROM_PART   ($(part_start "$ROM_PART") 起, $(part_size "$ROM_PART") 扇区)"
    say " 所在磁盘       : $DISK      ($DISK_SECTORS 扇区, 约 $(( DISK_SECTORS / 2048 )) MiB)"
    if [ -n "$OVL_PART" ]; then
        say " /overlay 来源  : $OVL_PART  (独立分区，已是最优布局)"
    else
        say " /overlay 来源  : 镜像内部(loop/tmpfs, 位于 $ROM_PART 内) → 空间受限、升级必丢"
    fi
    if [ -d "$UPPER_DIR" ]; then
        say " upper 数据层   : $UPPER_DIR  ($(du -sh "$UPPER_DIR" 2>/dev/null | cut -f1))"
    else
        say " upper 数据层   : 未找到 $UPPER_DIR"
    fi
    say " 目标数据分区   : $TARGET_PART (label=$LABEL)"
    say "=============================================================="
}

# ---------------------------------------------------------------- fstab

set_fstab() {
    rmnt="$TARGET_PART"
    if command -v uci >/dev/null 2>&1; then
        # 清掉所有指向 /overlay 的旧 mount 段（含历史 uuid 段与 auto_overlay）
        _secs=$(uci show fstab 2>/dev/null |
                sed -n "s/^fstab\.\([^.]*\)\.target='/overlay'/\\1/p" |
                sort -u)
        for _s in $_secs; do
            uci -q delete "fstab.$_s"
        done
        uci set fstab.extroot=mount
        uci set fstab.extroot.target='/overlay'
        uci set fstab.extroot.label="$LABEL"
        uci set fstab.extroot.fstype='ext4'
        uci set fstab.extroot.enabled='1'
        uci commit fstab
        ok "fstab 已写入（section=extroot, label=$LABEL）"
    else
        # 非 uci 系统：直接往 /etc/fstab 追加（旧行注释掉）
        cp /etc/fstab "/etc/fstab.bak.$(date +%s)" 2>/dev/null || true
        sed -i "s|^.*[[:space:]]/overlay[[:space:]].*$|# &#" /etc/fstab 2>/dev/null || true
        printf 'LABEL=%s /overlay ext4 defaults 0 0\n' "$LABEL" >> /etc/fstab
        ok "/etc/fstab 已追加 LABEL=$LABEL /overlay"
    fi
    sync
}

# ---------------------------------------------------------------- 扩容

do_grow() {
    [ -b "$TARGET_PART" ] || die "$TARGET_PART 不存在，请先 migrate"
    _start=$(part_start "$TARGET_PART")
    _size=$(part_size "$TARGET_PART")
    [ -n "$_start" ] && [ -n "$_size" ] || die "读不到 $TARGET_PART 的分区信息"
    _end=$(( _start + _size - 1 ))
    _free=$(( DISK_SECTORS - 34 - _end ))   # 留 34 扇区给 GPT 备份表

    say ""
    say " 分区 $TARGET_PART : 起始 $_start, 大小 $_size 扇区, 结束 $_end"
    say " 磁盘可用到        : $(( DISK_SECTORS - 34 )) 扇区"
    say " 尾部空闲          : $_free 扇区 (约 $(( _free / 2048 )) MiB)"

    if [ "$_free" -lt 4096 ]; then
        ok "已经是最大，无需扩容"
        return 0
    fi

    say ""
    say "[扩容] 把 $TARGET_PART 扩到盘尾 ..."
    need_tool parted || die "需要 parted（apk add parted / opkg install parted）"

    if ! parted -s "$DISK" resizepart "$PARTNUM" 100% 2>/dev/null; then
        # 有些环境不支持 100%，用绝对扇区
        _newend=$(( DISK_SECTORS - 34 ))
        parted -s "$DISK" unit s resizepart "$PARTNUM" "${_newend}s" 2>/dev/null || \
            die "parted 扩容失败（分区可能不是最后一段，或磁盘尾部有其它分区）"
    fi
    partprobe "$DISK" >/dev/null 2>&1 || true
    sync
    sleep 1

    _newsize=$(part_size "$TARGET_PART")
    say " 新大小: $_newsize 扇区 (约 $(( _newsize / 2048 )) MiB)"

    say "[扩容] 在线扩展 ext4 文件系统 ..."
    need_tool resize2fs e2fsprogs-extra || die "需要 resize2fs（apk add e2fsprogs-extra / opkg install e2fsprogs）"
    resize2fs "$TARGET_PART" || die "resize2fs 失败"
    sync

    say ""
    ok "扩容完成，/overlay 可用空间已扩大（无需重启）"
    df -h /overlay 2>/dev/null || true
}

# ---------------------------------------------------------------- 迁移

do_migrate() {
    [ -d "$UPPER_DIR" ] || warn "$UPPER_DIR 不存在，将以空的 upper 新建（插件需要重装）"

    _rs=$(part_start "$ROM_PART")
    _rz=$(part_size "$ROM_PART")
    _rend=$(( _rs + _rz - 1 ))
    # 起点：固件分区之后、给镜像尾部备份 GPT 留 34 扇区、再 1MiB 对齐
    START=$(align_up $(( _rend + 1 + 34 )) 2048)

    _avail=$(( DISK_SECTORS - 34 - START ))
    say ""
    say " 计划：新建 $TARGET_PART，起点 $START（镜像尾部之后 $(( (START - _rend - 1) )) 扇区余量）"
    say "       可用 $(( _avail / 2048 )) MiB"

    if [ "$_avail" -lt 300*2048 ]; then
        die "磁盘剩余空间不足 300MiB，无法建立独立 overlay 分区（先把虚拟磁盘扩容）"
    fi

    # 已有同名分区则直接拒绝，避免误删数据
    if [ -b "$TARGET_PART" ]; then
        _lbl=$(blkid -o value -s LABEL "$TARGET_PART" 2>/dev/null || true)
        _typ=$(blkid -o value -s TYPE  "$TARGET_PART" 2>/dev/null || true)
        if [ "$_typ" = "ext4" ] && [ "$_lbl" = "$LABEL" ]; then
            say " 已存在数据分区 $TARGET_PART (label=$_lbl)，改为走扩容流程"
            set_fstab
            do_grow
            return 0
        fi
        die "$TARGET_PART 已存在且不是 $LABEL 数据分区，为避免误删已停止。请手工确认后再运行"
    fi

    say ""
    say "[1/6] 建分区"
    if command -v fdisk >/dev/null 2>&1; then
        printf 'n\n%s\n%s\n\nw\n' "$PARTNUM" "$START" | fdisk --wipe always "$DISK" >/dev/null 2>&1 || \
            printf 'n\n%s\n%s\n\nw\n' "$PARTNUM" "$START" | fdisk "$DISK" >/dev/null 2>&1 || \
            die "fdisk 建分区失败"
    elif need_tool parted; then
        parted -s "$DISK" unit s mkpart primary "${START}s" 100% || die "parted 建分区失败"
    else
        die "没有 fdisk / parted 可用"
    fi
    partprobe "$DISK" >/dev/null 2>&1 || true
    sync
    _i=0
    while [ ! -b "$TARGET_PART" ] && [ "$_i" -lt 15 ]; do sleep 1; _i=$((_i+1)); done
    [ -b "$TARGET_PART" ] || die "$TARGET_PART 没有出现，请重启后重试"
    ok "分区已建立 $(part_start "$TARGET_PART") 起, $(part_size "$TARGET_PART") 扇区"

    say ""
    say "[2/6] 格式化为 ext4（label=$LABEL）"
    if command -v mke2fs >/dev/null 2>&1; then
        mke2fs -t ext4 -L "$LABEL" -m 0 -q "$TARGET_PART" || die "格式化失败"
    else
        need_tool mkfs.ext4 e2fsprogs || die "没有 mkfs.ext4"
        mkfs.ext4 -F -L "$LABEL" -m 0 "$TARGET_PART" || die "格式化失败"
    fi
    ok "已格式化"

    say ""
    say "[3/6] 挂载并复制现有 overlay 数据（插件本体）"
    mkdir -p "$MNT"
    mount "$TARGET_PART" "$MNT" || die "挂载 $TARGET_PART 失败"
    mkdir -p "$MNT/upper" "$MNT/work"
    if [ -d "$UPPER_DIR" ]; then
        _cnt_src=$(find "$UPPER_DIR" 2>/dev/null | wc -l)
        say " 正在复制 $_cnt_src 个条目，请等待 ...（不要断电）"
        if command -v cp >/dev/null 2>&1 && cp -a "$UPPER_DIR/." "$MNT/upper/" 2>/dev/null; then
            :
        else
            need_tool tar || die "复制失败且没有 tar 可用"
            ( cd "$UPPER_DIR" && tar cf - . ) | ( cd "$MNT/upper" && tar xf - ) || die "tar 复制失败"
        fi
        sync
        _cnt_dst=$(find "$MNT/upper" 2>/dev/null | wc -l)
        say " 源 $_cnt_src 条 → 目标 $_cnt_dst 条"
        if [ "$_cnt_dst" -lt $(( _cnt_src / 2 )) ]; then
            umount "$MNT" 2>/dev/null
            die "复制数量异常（可能空间不足），已停止，原系统未受影响"
        fi
        ok "数据已复制到 $TARGET_PART:/upper"
    else
        ok "无旧数据，跳过复制"
    fi

    say ""
    say "[4/6] 写 fstab（开机挂 /overlay）"
    set_fstab

    say ""
    say "[5/6] 自检"
    [ -f "$MNT/upper/etc/config/network" ] && ok "network 配置在" || warn "没有 etc/config/network（可能是全新系统）"
    [ -d "$MNT/upper/usr/lib" ] && ok "usr/lib 在（插件文件存在）" || warn "没有 usr/lib"
    du -sh "$MNT/upper" 2>/dev/null | sed 's/^/    upper 大小: /'
    df -h "$MNT" 2>/dev/null | tail -n1 | sed 's/^/    新分区: /'

    say ""
    say "[6/6] 卸载"
    umount "$MNT" || warn "卸载失败，可重启前忽略"
    rmdir "$MNT" 2>/dev/null || true
    sync

    say ""
    say "=============================================================="
    say " 迁移完成。现在执行 reboot，重启后 /overlay 就在 $TARGET_PART 上"
    say "=============================================================="
}

# ---------------------------------------------------------------- 升级体检

do_verify() {
    _img="${1:-}"
    [ -n "$_img" ] || die "用法: $0 verify <固件文件.img.gz>"
    [ -f "$_img" ] || die "找不到文件: $_img"
    command -v sysupgrade >/dev/null 2>&1 || die "本系统没有 sysupgrade（不是 OpenWrt？）"

    say "正在用 sysupgrade -T 校验（只读，不刷写）..."
    _out=$(sysupgrade -T "$_img" 2>&1)
    say "$_out" | sed 's/^/  | /'

    case "$_out" in
        *"Partition layout has changed"*)
            say ""
            warn "结论：本次升级会【全盘重写】磁盘！"
            say "      → 独立 overlay 分区($LABEL)会被覆盖，插件会丢"
            say "      处理办法："
            say "      1) 先备份  $UPPER_DIR  到外部（tar czf 后下载走）"
            say "      2) 升级后重新运行 $0 migrate 把数据搬回"
            say "      3) 或者改用『与当前磁盘布局一致』的安装器镜像（custom2 安装器已内置对齐逻辑）"
            return 1
            ;;
    esac

    say ""
    ok "结论：本次升级只写 p1/p2，独立 overlay 分区会保留（安全）"
    return 0
}

# ---------------------------------------------------------------- 状态判定

is_extroot_ok() {
    [ -b "$TARGET_PART" ] || return 1
    [ -n "$OVL_PART" ] || return 1
    [ "$OVL_PART" = "$TARGET_PART" ] || return 1
    return 0
}

# ---------------------------------------------------------------- 主流程

ACTION="${1:-auto}"

case "$ACTION" in
    check)
        show_state
        if is_extroot_ok; then
            ok "已使用独立 overlay 分区"
            _start=$(part_start "$TARGET_PART"); _size=$(part_size "$TARGET_PART")
            _free=$(( DISK_SECTORS - 34 - _start - _size ))
            if [ "$_free" -ge 4096 ]; then
                warn "磁盘尾部还有 $(( _free / 2048 )) MiB 没被用上 → 可执行: $0 grow"
            else
                ok "分区已铺满磁盘尾部"
            fi
        else
            warn "overlay 还在镜像内部 → 可执行: $0 migrate"
        fi
        ;;
    migrate)
        show_state
        do_migrate
        ;;
    grow)
        show_state
        set_fstab
        do_grow
        ;;
    verify)
        shift
        do_verify "${1:-}"
        ;;
    auto)
        show_state
        if is_extroot_ok; then
            do_grow
        elif [ -n "$OVL_PART" ] && [ "$OVL_PART" != "$TARGET_PART" ]; then
            warn "overlay 挂在别的分区($OVL_PART)，不是 $TARGET_PART"
            warn "如需统一，请先手工确认，再删除旧的 fstab 条目后运行 $0 migrate"
            exit 1
        else
            do_migrate
        fi
        ;;
    *)
        say "用法:"
        say "  $0            自动（未迁移则迁移，已迁移则扩容）"
        say "  $0 check      只体检"
        say "  $0 migrate    迁移 overlay 到独立分区"
        say "  $0 grow       扩容数据分区"
        say "  $0 verify <固件>  升级前体检是否全盘重写"
        exit 1
        ;;
esac
