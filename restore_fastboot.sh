#!/system/bin/sh

PATH=/system/bin:/system/xbin:/vendor/bin
export PATH
umask 077

fail() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

digest() {
    digest_line=$(sha256sum "$1") || return 1
    printf '%s\n' "${digest_line%% *}"
}

image_size() {
    image_count=$(stat -c '%s' "$1") || return 1
    case "$image_count" in ''|*[!0-9]*) return 1 ;; esac
    [ "$image_count" -gt 0 ] || return 1
    printf '%s\n' "$image_count"
}

device_size() {
    device_count=$(blockdev --getsize64 "$1") || return 1
    case "$device_count" in ''|*[!0-9]*) return 1 ;; esac
    [ "$device_count" -gt 0 ] || return 1
    printf '%s\n' "$device_count"
}

device_path() {
    device_result=
    for device_dir in /dev/block/by-name /dev/block/bootdevice/by-name; do
        entry=$device_dir/$1
        [ -e "$entry" ] || continue
        [ -b "$entry" ] || return 1
        resolved=$(readlink -f "$entry") || return 1
        case "$resolved" in /dev/block/*) ;; *) return 1 ;; esac
        [ -z "$device_result" ] || [ "$device_result" = "$resolved" ] || return 1
        device_result=$resolved
    done
    [ -n "$device_result" ] || return 1
    printf '%s\n' "$device_result"
}

slots_match() {
    [ "$(getprop ro.boot.slot_suffix)" = "$current_suffix" ] &&
        [ "$(bootctl get-current-slot)" = "$current_slot" ] &&
        [ "$(bootctl get-active-boot-slot)" = "$target_slot" ] &&
        bootctl is-slot-bootable "$target_slot" >/dev/null
}

read_full() {
    dd "if=$1" "of=$2" bs=65536 || return 1
    [ "$(image_size "$2")" = "$3" ]
}

dump_slot_matches() {
    [ "$(getprop ro.boot.slot_suffix)" = "$current_suffix" ] || return 1
    if command -v bootctl >/dev/null 2>&1; then
        reported_slot=$(bootctl get-current-slot 2>/dev/null) || return 0
        [ "$reported_slot" = "$current_slot" ] || return 1
    fi
    return 0
}

read_prefix() {
    head -c "$2" "$1" > "$work_dir/check.bin" || return 1
    [ "$(image_size "$work_dir/check.bin")" = "$2" ]
}

write_one() {
    slots_match || return 1
    [ "$(device_path "$1")" = "$2" ] || return 1
    [ "$(blockdev --getro "$2")" = 0 ] || return 1
    dd "if=$3" "of=$2" bs=65536 conv=notrunc || return 1
    sync || return 1
    read_prefix "$2" "$4" && cmp -s "$3" "$work_dir/check.bin"
}

mode_check=0
mode_dump=0
case "$#:${1:-}" in
    0:) ;;
    1:--check) mode_check=1 ;;
    1:--dump-current|2:--dump-current) mode_dump=1 ;;
    *) fail '用法：sh restore_fastboot.sh [--check | --dump-current [新目录绝对路径]]' ;;
esac
case "$(id -u)" in 0) ;; *) fail '请先执行 su，再在 Root 终端运行此脚本。' ;; esac
for required in getprop blockdev readlink stat mktemp dd sha256sum sync; do
    command -v "$required" >/dev/null 2>&1 || fail "手机缺少命令 $required。"
done

current_suffix=$(getprop ro.boot.slot_suffix)
case "$current_suffix" in
    _a) current_slot=0; target_slot=1; target_suffix=_b ;;
    _b) current_slot=1; target_slot=0; target_suffix=_a ;;
    *) fail '无法识别当前运行槽位。' ;;
esac
model=$(getprop ro.product.model)
[ -n "$model" ] || fail '无法识别设备型号。'

if [ "$mode_dump" = 1 ]; then
    dump_slot_matches || fail '当前运行槽位查询结果不一致。'
    dump_abl=$(device_path "abl$current_suffix") || fail '无法定位当前槽位的 abl。'
    dump_cdt=$(device_path "engineering_cdt$current_suffix") || fail '无法定位当前槽位的 engineering_cdt。'
    dump_abl_id=$(stat -c '%t:%T' "$dump_abl") || fail '无法核对当前 abl 分区。'
    dump_cdt_id=$(stat -c '%t:%T' "$dump_cdt") || fail '无法核对当前 engineering_cdt 分区。'
    [ "$dump_abl_id" != "$dump_cdt_id" ] || fail '两个分区指向同一个底层设备。'
    dump_abl_size=$(device_size "$dump_abl") || fail '无法读取当前 abl 大小。'
    dump_cdt_size=$(device_size "$dump_cdt") || fail '无法读取当前 engineering_cdt 大小。'

    if [ "$#" = 2 ]; then
        case "$2" in /*) ;; *) fail '请输入新目录的绝对路径。' ;; esac
        dump_dir=${2%/}
        [ -n "$dump_dir" ] && mkdir -- "$dump_dir" || fail '不能创建指定目录，请确认其父目录已存在，且输出目录尚不存在。'
    else
        dump_dir=$(mktemp -d /data/local/tmp/fastboot_current.XXXXXXXX) || fail '无法创建导出目录。'
    fi
    trap 'rm -f -- "$dump_dir/abl.img" "$dump_dir/engineering_cdt.img"; rmdir -- "$dump_dir"' EXIT
    trap 'exit 1' HUP INT TERM
    read_full "$dump_abl" "$dump_dir/abl.img" "$dump_abl_size" || fail '读取当前 abl 失败。'
    read_full "$dump_cdt" "$dump_dir/engineering_cdt.img" "$dump_cdt_size" || fail '读取当前 engineering_cdt 失败。'
    dump_abl_hash=$(digest "$dump_dir/abl.img") || fail '无法计算 abl 镜像 SHA-256。'
    dump_cdt_hash=$(digest "$dump_dir/engineering_cdt.img") || fail '无法计算 engineering_cdt 镜像 SHA-256。'
    [ "$(digest "$dump_abl")" = "$dump_abl_hash" ] || fail 'abl 镜像与当前分区校验不一致。'
    [ "$(digest "$dump_cdt")" = "$dump_cdt_hash" ] || fail 'engineering_cdt 镜像与当前分区校验不一致。'
    dump_slot_matches || fail '导出期间当前槽位状态发生变化。'
    sync || fail '无法同步导出的镜像。'
    trap - EXIT HUP INT TERM
    printf '型号：%s\n当前槽位：%s\n导出目录：%s\nabl.img (%s bytes) SHA-256 %s\nengineering_cdt.img (%s bytes) SHA-256 %s\n' \
        "$model" "$current_suffix" "$dump_dir" "$dump_abl_size" "$dump_abl_hash" "$dump_cdt_size" "$dump_cdt_hash"
    exit 0
fi

for required in bootctl head cmp; do
    command -v "$required" >/dev/null 2>&1 || fail "手机缺少命令 $required。"
done
locked=$(getprop ro.boot.flash.locked)
vbmeta=$(getprop ro.boot.vbmeta.device_state)
case "$locked:$vbmeta" in 0:|0:unlocked|:unlocked) ;; *) fail '无法确认 Bootloader 已解锁。' ;; esac
[ "$(bootctl get-number-slots)" = 2 ] || fail '无法确认设备有两个 A/B 槽位。'
slots_match || fail '下次启动槽位未指向另一槽位。请先完成本地 OTA 和 Magisk 未使用槽位安装，并暂时不要重启。'

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || fail '无法确定脚本目录。'
mode=files
if [ "$model" = PJZ110 ]; then
    image_dir=$script_dir
    if [ -d "$script_dir/PJZ110_16.0.10.501_images" ]; then
        image_dir=$script_dir/PJZ110_16.0.10.501_images
    fi
    printf 'PJZ110 固定镜像来自 ColorOS 16.0.10.501。\n'
else
    printf '型号：%s\n1. 使用旧系统镜像\n2. 提取当前槽位镜像并用它们覆盖目标槽位\n请选择 [1/2]：' "$model"
    IFS= read -r selection || fail '未读取到选项。'
    case "$selection" in
        1)
            printf '输入已有 abl.img 和 engineering_cdt.img 的目录（回车使用脚本同级目录）：'
            IFS= read -r image_dir || fail '未读取到目录。'
            image_dir=${image_dir:-$script_dir}
            ;;
        2) mode=dump ;;
        *) fail '请选择 1 或 2。' ;;
    esac
fi

abl_name=abl$target_suffix
cdt_name=engineering_cdt$target_suffix
active_abl=$(device_path "abl$current_suffix") || fail '无法定位当前槽位的 abl。'
active_cdt=$(device_path "engineering_cdt$current_suffix") || fail '无法定位当前槽位的 engineering_cdt。'
target_abl=$(device_path "$abl_name") || fail '无法定位目标槽位的 abl。'
target_cdt=$(device_path "$cdt_name") || fail '无法定位目标槽位的 engineering_cdt。'
seen_devices=' '
for partition in "$active_abl" "$active_cdt" "$target_abl" "$target_cdt"; do
    device_id=$(stat -c '%t:%T' "$partition") || fail "无法核对分区 $partition。"
    case "$seen_devices" in *" $device_id "*) fail '分区路径指向了重复的底层设备。' ;; esac
    seen_devices="$seen_devices$device_id "
done
for partition in "$target_abl" "$target_cdt"; do
    [ "$(blockdev --getro "$partition")" = 0 ] || fail "目标分区不可写 $partition。"
done
target_abl_size=$(device_size "$target_abl") || fail '无法读取目标 abl 大小。'
target_cdt_size=$(device_size "$target_cdt") || fail '无法读取目标 engineering_cdt 大小。'

lock_dir=/data/local/tmp/restore_fastboot.lock
mkdir "$lock_dir" || fail "另一个脚本实例可能仍在运行，锁目录为 $lock_dir。"
trap 'rmdir "$lock_dir"' EXIT
trap 'exit 1' HUP INT TERM
work_dir=$(mktemp -d /data/local/tmp/restore_fastboot.XXXXXXXX) || fail '无法创建备份目录。'
printf '备份及校验目录：%s\n' "$work_dir"
replacement_abl=$work_dir/abl.img
replacement_cdt=$work_dir/engineering_cdt.img
original_abl=$work_dir/original_${abl_name}.img
original_cdt=$work_dir/original_${cdt_name}.img

if [ "$mode" = files ]; then
    [ -f "$image_dir/abl.img" ] && [ -f "$image_dir/engineering_cdt.img" ] || fail '指定目录缺少 abl.img 或 engineering_cdt.img。'
    cp -- "$image_dir/abl.img" "$replacement_abl" &&
        cp -- "$image_dir/engineering_cdt.img" "$replacement_cdt" || fail '镜像复制失败。'
else
    active_abl_size=$(device_size "$active_abl") || fail '无法读取当前 abl 大小。'
    active_cdt_size=$(device_size "$active_cdt") || fail '无法读取当前 engineering_cdt 大小。'
    [ "$active_abl_size" = "$target_abl_size" ] && [ "$active_cdt_size" = "$target_cdt_size" ] || fail '两槽分区大小不同。'
    read_full "$active_abl" "$replacement_abl" "$active_abl_size" &&
        read_full "$active_cdt" "$replacement_cdt" "$active_cdt_size" || fail '当前槽位提取失败。'
fi

replacement_abl_size=$(image_size "$replacement_abl") || fail 'abl 镜像无效。'
replacement_cdt_size=$(image_size "$replacement_cdt") || fail 'engineering_cdt 镜像无效。'
[ "$replacement_abl_size" -le "$target_abl_size" ] &&
    [ "$replacement_cdt_size" -le "$target_cdt_size" ] || fail '镜像大于目标分区。'
replacement_abl_hash=$(digest "$replacement_abl") || fail '无法校验 abl 镜像。'
replacement_cdt_hash=$(digest "$replacement_cdt") || fail '无法校验 engineering_cdt 镜像。'

if [ "$model" = PJZ110 ]; then
    [ "$replacement_abl_hash" = c6aa137b7e2b8c6f86040438022488eee6b2a69a1fad95f109a86c8a77d64bed ] &&
        [ "$replacement_cdt_hash" = f463a71214658af0d64c06be6e473d676fac793c13b3b211a79ac936494d861a ] || fail '镜像与固定的 ColorOS 16.0.10.501 镜像不匹配。'
fi

read_full "$target_abl" "$original_abl" "$target_abl_size" &&
    read_full "$target_cdt" "$original_cdt" "$target_cdt_size" || fail '目标槽位备份失败。'
sync || fail '无法同步备份。'

if [ "$model" = PJZ110 ]; then
    read_prefix "$original_abl" 278528 || fail '无法校验目标 abl。'
    [ "$(digest "$work_dir/check.bin")" = 926fcdd96eff6383c7f107ec0cf86faa2db12e72f38f92ce4530de32d967164d ] || fail '目标 abl 与 ColorOS 17.0.1.202 不匹配。'
    read_prefix "$original_cdt" 1048576 || fail '无法校验目标 engineering_cdt。'
    [ "$(digest "$work_dir/check.bin")" = 8e080dcaa9e852826282ef03bf09f00c962eca97358c8ee85210cff4acf4b8d6 ] || fail '目标 engineering_cdt 与 ColorOS 17.0.1.202 不匹配。'
fi

printf '当前槽位 %s，下次启动槽位 %s。对应分区为 %s 和 %s。\n' "$current_suffix" "$target_suffix" "$abl_name" "$cdt_name"
if [ "$mode_check" = 1 ]; then
    printf '检查通过，分区内容未写入。镜像和备份位于 %s。\n' "$work_dir"
    exit 0
fi
printf '混用不同版本的引导分区可能导致无法开机。确认系统更新已完成且 Magisk 已安装到未使用槽位后，输入 WRITE%s 继续：' "$target_suffix"
IFS= read -r confirmation || fail '未读取到确认。'
[ "$confirmation" = "WRITE$target_suffix" ] || fail '已取消。'
slots_match || fail '等待确认期间槽位状态发生变化。'
cmp -s "$original_abl" "$target_abl" && cmp -s "$original_cdt" "$target_cdt" || fail '目标分区在备份后发生变化。'

if ! write_one "$abl_name" "$target_abl" "$replacement_abl" "$replacement_abl_size"; then
    fail "abl 写入或回读失败，请勿重启。原始分区备份位于 $work_dir。"
fi
if ! write_one "$cdt_name" "$target_cdt" "$replacement_cdt" "$replacement_cdt_size"; then
    fail "engineering_cdt 写入或回读失败，目标槽位可能已部分修改，请勿重启。原始分区备份位于 $work_dir。"
fi
slots_match || fail "写入后槽位状态异常，请勿重启。原始分区备份位于 $work_dir。"
printf '两个目标镜像已写入并通过回读校验。备份位于 %s。请返回系统更新页面手动重启。\n' "$work_dir"
