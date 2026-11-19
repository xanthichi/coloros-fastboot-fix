#!/system/bin/sh
# 一加 13（PJZ110）Fastboot 镜像检查与恢复
#
# 在 MT 管理器终端执行 su，再用 id -u 确认输出为 0。
# 将脚本和 ColorOS 16.0.10.501 的 abl.img、engineering_cdt.img
# 一起放在手机内部存储的 FixFastboot 文件夹。只需这两个小镜像。
#
# 用同目录的镜像做只读预检：
#   sh /sdcard/FixFastboot/restore_fastboot.sh --check
# 读取当前运行槽位的完整镜像并做只读预检：
#   sh /sdcard/FixFastboot/restore_fastboot.sh --check-current
# 仅导出当前槽位镜像（输出目录须尚不存在）：
#   sh /sdcard/FixFastboot/restore_fastboot.sh --dump-current /sdcard/FixFastboot/current-backup
#
# 预检会显示来源、目标分区和镜像 SHA-256。PJZ110 的目标哈希与
# ColorOS 17.0.1.202 的参考值不符时会记录警告，写入模式可输入 1 继续。
#
# 不带参数显示机型菜单。--from-current 直接选择当前槽位镜像。
# 每次运行会在脚本同目录保存一份日志，并在退出时显示日志路径和链接。
# 以 ro.boot.slot_suffix 为准选择当前运行槽位的对侧，无需 bootctl。
# 写入流程不要求 Bootloader 已解锁，也不会设置或验证下次启动槽位。
# 写入流程会备份目标分区、要求手动确认，并在写入后回读校验。
# 先在系统升级页面完成 OTA 安装，保留页面上的「重启」按钮，等待
# Magisk 安装到未使用槽位并完成本脚本的写入校验。最后回到系统升级页面点「重启」。
# 混用不同版本的引导镜像可能无法启动。若写入或回读失败，请保留
# 脚本打印的分区备份路径并暂缓重启。

PATH=/system/bin:/system/xbin:/vendor/bin
export PATH
umask 077

fail() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

fail_write_blocked() {
    printf '当前以写入模式运行。可以在 Root 终端用以下命令做只读预检：\n' >&2
    printf '  sh "%s" --check         # 检查同目录镜像\n' "$0" >&2
    printf '  sh "%s" --check-current # 检查当前槽位镜像\n' "$0" >&2
    fail '写入条件未满足，分区内容未修改。'
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
    [ "$(getprop ro.boot.slot_suffix)" = "$current_suffix" ]
}

read_full() {
    dd "if=$1" "of=$2" bs=65536 || return 1
    [ "$(image_size "$2")" = "$3" ]
}

read_prefix() {
    head -c "$2" "$1" > "$work_dir/check.bin" || return 1
    [ "$(image_size "$work_dir/check.bin")" = "$2" ]
}

write_one() {
    slots_match || return 1
    [ "$(device_path "$1")" = "$2" ] || return 1
    case "$(blockdev --getro "$2")" in
        0) ;;
        1)
            restore_readonly=$2
            blockdev --setrw "$2" && [ "$(blockdev --getro "$2")" = 0 ] || return 1
            ;;
        *) return 1 ;;
    esac
    dd "if=$3" "of=$2" bs=65536 conv=notrunc || return 1
    sync || return 1
    read_prefix "$2" "$4" && cmp -s "$3" "$work_dir/check.bin" || return 1
    restore_readonly_flag
}

restore_readonly_flag() {
    [ -n "$restore_readonly" ] || return 0
    blockdev --setro "$restore_readonly" &&
        [ "$(blockdev --getro "$restore_readonly")" = 1 ] || return 1
    restore_readonly=
}

cleanup_work() {
    exit_status=$?
    if ! restore_readonly_flag; then
        printf '错误：未能恢复 %s 的只读状态，请勿重启。\n' "$restore_readonly" >&2
        exit_status=1
    fi
    if [ "$mode_check" = 1 ] && [ -n "$work_dir" ]; then
        rm -f -- "$replacement_abl" "$replacement_cdt" "$original_abl" "$original_cdt" "$work_dir/check.bin" &&
            rmdir -- "$work_dir" || exit_status=1
    fi
    rmdir -- "$lock_dir" || exit_status=1
    exit "$exit_status"
}

main() (
mode_check=0
mode_dump=0
mode_menu=0
mode=files
case "$#:${1:-}" in
    0:) mode_menu=1 ;;
    1:--check) mode_check=1 ;;
    1:--check-current) mode_check=1; mode=current ;;
    1:--from-current) mode=current ;;
    1:--dump-current|2:--dump-current) mode_dump=1 ;;
    *) fail '用法：sh restore_fastboot.sh [--check | --check-current | --from-current | --dump-current [新目录绝对路径]]' ;;
esac
case "$(id -u)" in 0) ;; *) fail '请先执行 su，再在 Root 终端运行此脚本。' ;; esac
model=$(getprop ro.product.model)
[ -n "$model" ] || fail '无法识别设备型号。'
printf '检测到机型 %s。\n' "$model"
if [ "$mode_menu" = 1 ]; then
    while :; do
        if [ "$model" = PJZ110 ]; then
            printf '\n一加 13（PJZ110）\n1. 使用同目录下载的两个镜像替换另一槽位\n2. 提取当前系统的两个镜像并替换另一槽位\n0. 退出\n请选择 [1/2/0]：'
        else
            printf '\n1. 提取当前系统的两个镜像并替换另一槽位\n0. 退出\n请选择 [1/0]：'
        fi
        if ! IFS= read -r selection; then
            printf '\n输入已结束，退出。\n'
            exit 0
        fi
        case "$selection:$model" in
            0:*) printf '用户选择退出。\n'; exit 0 ;;
            1:PJZ110) mode=files; break ;;
            1:*|2:PJZ110) mode=current; break ;;
            *) printf '无效选项，请重新选择。\n' ;;
        esac
    done
    if [ "$mode" = files ]; then
        printf '已选择 %s：使用本地下载的镜像。\n' "$selection"
    else
        printf '已选择 %s：从当前运行槽位提取镜像。\n' "$selection"
    fi
elif [ "$model" != PJZ110 ]; then
    mode=current
fi
for required in getprop blockdev readlink stat mktemp dd sha256sum sync; do
    command -v "$required" >/dev/null 2>&1 || fail "手机缺少命令 $required。"
done

current_suffix=$(getprop ro.boot.slot_suffix)
case "$current_suffix" in
    _a) target_suffix=_b ;;
    _b) target_suffix=_a ;;
    *) fail '无法识别当前运行槽位。' ;;
esac
printf '当前运行槽位 %s，另一槽位 %s。\n' "$current_suffix" "$target_suffix"

if [ "$mode_dump" = 1 ]; then
    slots_match || fail '当前运行槽位查询结果不一致。'
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
    slots_match || fail '导出期间当前槽位状态发生变化。'
    sync || fail '无法同步导出的镜像。'
    trap - EXIT HUP INT TERM
    printf '型号：%s\n当前槽位：%s\n导出目录：%s\nabl.img (%s bytes) SHA-256 %s\nengineering_cdt.img (%s bytes) SHA-256 %s\n' \
        "$model" "$current_suffix" "$dump_dir" "$dump_abl_size" "$dump_abl_hash" "$dump_cdt_size" "$dump_cdt_hash"
    exit 0
fi

for required in head cmp; do
    command -v "$required" >/dev/null 2>&1 || fail "手机缺少命令 $required。"
done
locked=$(getprop ro.boot.flash.locked)
vbmeta=$(getprop ro.boot.vbmeta.device_state)
printf 'Bootloader 状态仅供记录：flash.locked=%s，vbmeta.device_state=%s。\n' "${locked:-未知}" "${vbmeta:-未知}"
printf '目标为当前运行槽位的对侧。下次启动槽位及可启动状态未验证。\n'
write_blocked=0

if [ "$mode" = current ]; then
    printf '镜像来源：当前槽位的两个完整分区。\n'
elif [ "$model" = PJZ110 ]; then
    image_dir=$script_dir
    if [ ! -e "$script_dir/abl.img" ] && [ ! -e "$script_dir/engineering_cdt.img" ] &&
        [ -d "$script_dir/PJZ110_16.0.10.501_images" ]; then
        image_dir=$script_dir/PJZ110_16.0.10.501_images
    fi
    printf 'PJZ110 固定镜像来自 ColorOS 16.0.10.501。\n'
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
    case "$(blockdev --getro "$partition" 2>/dev/null)" in
        0) printf '目标分区 %s 的 Linux 只读标志为 0。\n' "$partition" ;;
        1) printf '目标分区 %s 的 Linux 只读标志为 1；实际写入时需临时清除并恢复。\n' "$partition" ;;
        *) printf '写入阻止：无法读取目标分区 %s 的 Linux 只读标志。\n' "$partition"; write_blocked=1 ;;
    esac
done
[ "$mode_check" = 1 ] || [ "$write_blocked" = 0 ] || fail_write_blocked
target_abl_size=$(device_size "$target_abl") || fail '无法读取目标 abl 大小。'
target_cdt_size=$(device_size "$target_cdt") || fail '无法读取目标 engineering_cdt 大小。'

lock_dir=/data/local/tmp/restore_fastboot.lock
mkdir "$lock_dir" || fail "另一个脚本实例可能仍在运行，锁目录为 $lock_dir。"
restore_readonly=
work_dir=
trap cleanup_work EXIT
trap 'exit 1' HUP INT TERM
work_dir=$(mktemp -d /data/local/tmp/restore_fastboot.XXXXXXXX) || fail '无法创建备份目录。'
replacement_abl=$work_dir/abl.img
replacement_cdt=$work_dir/engineering_cdt.img
original_abl=$work_dir/original_${abl_name}.img
original_cdt=$work_dir/original_${cdt_name}.img

if [ "$mode" = files ]; then
    printf '镜像来源：%s/abl.img，%s/engineering_cdt.img。\n' "$image_dir" "$image_dir"
    [ -f "$image_dir/abl.img" ] && [ -f "$image_dir/engineering_cdt.img" ] || fail '指定目录缺少 abl.img 或 engineering_cdt.img。'
    cp -- "$image_dir/abl.img" "$replacement_abl" &&
        cp -- "$image_dir/engineering_cdt.img" "$replacement_cdt" || fail '镜像复制失败。'
else
    printf '镜像来源：abl%s（%s），engineering_cdt%s（%s）。\n' "$current_suffix" "$active_abl" "$current_suffix" "$active_cdt"
    active_abl_size=$(device_size "$active_abl") || fail '无法读取当前 abl 大小。'
    active_cdt_size=$(device_size "$active_cdt") || fail '无法读取当前 engineering_cdt 大小。'
    [ "$active_abl_size" = "$target_abl_size" ] && [ "$active_cdt_size" = "$target_cdt_size" ] || fail '两槽分区大小不同。'
    read_full "$active_abl" "$replacement_abl" "$active_abl_size" &&
        read_full "$active_cdt" "$replacement_cdt" "$active_cdt_size" || fail '当前槽位提取失败。'
    slots_match || fail '读取期间当前槽位发生变化。'
fi

replacement_abl_size=$(image_size "$replacement_abl") || fail 'abl 镜像无效。'
replacement_cdt_size=$(image_size "$replacement_cdt") || fail 'engineering_cdt 镜像无效。'
[ "$replacement_abl_size" -le "$target_abl_size" ] &&
    [ "$replacement_cdt_size" -le "$target_cdt_size" ] || fail '镜像大于目标分区。'
replacement_abl_hash=$(digest "$replacement_abl") || fail '无法校验 abl 镜像。'
replacement_cdt_hash=$(digest "$replacement_cdt") || fail '无法校验 engineering_cdt 镜像。'

if [ "$model" = PJZ110 ]; then
    if [ "$mode" = current ]; then
        expected_abl_hash=f8cd7ca3d5fafb4c97cf2d7ef6a32d934e7bb0d22b65d1f135c5ea1d3a294908
        expected_abl_size=1048576
    else
        expected_abl_hash=c6aa137b7e2b8c6f86040438022488eee6b2a69a1fad95f109a86c8a77d64bed
        expected_abl_size=278528
    fi
    [ "$replacement_abl_size" = "$expected_abl_size" ] && [ "$replacement_cdt_size" = 1048576 ] &&
        [ "$replacement_abl_hash" = "$expected_abl_hash" ] &&
        [ "$replacement_cdt_hash" = f463a71214658af0d64c06be6e473d676fac793c13b3b211a79ac936494d861a ] || fail '来源镜像与已核实的 PJZ110 ColorOS 16.0.10.501 镜像不匹配。'
fi

printf '比对目标：%s（%s），%s（%s）。\n' "$abl_name" "$target_abl" "$cdt_name" "$target_cdt"
read_full "$target_abl" "$original_abl" "$target_abl_size" &&
    read_full "$target_cdt" "$original_cdt" "$target_cdt_size" || fail '目标槽位备份失败。'
sync || fail '无法同步备份。'

target_mismatch=0
if [ "$model" = PJZ110 ]; then
    read_prefix "$original_abl" 278528 || fail '无法校验目标 abl。'
    target_abl_hash=$(digest "$work_dir/check.bin") || fail '无法计算目标 abl 的 SHA-256。'
    if [ "$target_abl_hash" != 926fcdd96eff6383c7f107ec0cf86faa2db12e72f38f92ce4530de32d967164d ]; then
        printf '警告：目标 abl 与 ColorOS 17.0.1.202 不匹配（SHA-256：%s）。\n' "$target_abl_hash"
        target_mismatch=1
    fi
    read_prefix "$original_cdt" 1048576 || fail '无法校验目标 engineering_cdt。'
    target_cdt_hash=$(digest "$work_dir/check.bin") || fail '无法计算目标 engineering_cdt 的 SHA-256。'
    if [ "$target_cdt_hash" != 8e080dcaa9e852826282ef03bf09f00c962eca97358c8ee85210cff4acf4b8d6 ]; then
        printf '警告：目标 engineering_cdt 与 ColorOS 17.0.1.202 不匹配（SHA-256：%s）。\n' "$target_cdt_hash"
        target_mismatch=1
    fi
fi

printf '当前槽位 %s，另一槽位 %s。\n' "$current_suffix" "$target_suffix"
printf '来源 abl SHA-256 %s\n来源 engineering_cdt SHA-256 %s\n' "$replacement_abl_hash" "$replacement_cdt_hash"
if [ "$mode_check" = 1 ]; then
    if [ "$write_blocked" = 1 ]; then
        printf '预检完成。写入条件未满足。\n'
    elif [ "$target_mismatch" = 1 ]; then
        printf '预检完成。目标镜像与参考版本不匹配，写入模式可确认后继续。\n'
    else
        printf '镜像和目标校验通过。写入条件检查通过。\n'
    fi
    exit 0
fi
printf '备份及校验目录：%s\n' "$work_dir"
printf '混用不同版本的引导分区可能导致无法开机。请确认系统更新已完成且 Magisk 已安装到目标槽位。\n'
printf '写入和回读校验成功后，请回到系统升级页面点「重启」。\n'
if [ "$target_mismatch" = 1 ]; then
    printf '1. 接受目标版本不匹配的风险，继续写入槽位 %s\n' "$target_suffix"
else
    printf '1. 确认写入槽位 %s\n' "$target_suffix"
fi
printf '0. 取消并退出\n'
while :; do
    printf '请选择 [1/0]：'
    if ! IFS= read -r confirmation; then
        printf '\n输入已结束，已取消写入。\n'
        exit 0
    fi
    case "$confirmation" in
        1) break ;;
        0) printf '已取消写入。\n'; exit 0 ;;
        *) printf '无效选项，请重新选择。\n' ;;
    esac
done
if [ "$target_mismatch" = 1 ]; then
    printf '用户已确认接受目标版本不匹配的风险。\n'
fi
slots_match || fail '等待确认期间槽位状态发生变化。'
cmp -s "$original_abl" "$target_abl" && cmp -s "$original_cdt" "$target_cdt" || fail '目标分区在备份后发生变化。'

if ! write_one "$abl_name" "$target_abl" "$replacement_abl" "$replacement_abl_size"; then
    fail "abl 写入或回读失败，请勿重启。原始分区备份位于 $work_dir。"
fi
if ! write_one "$cdt_name" "$target_cdt" "$replacement_cdt" "$replacement_cdt_size"; then
    fail "engineering_cdt 写入或回读失败，目标槽位可能已部分修改，请勿重启。原始分区备份位于 $work_dir。"
fi
slots_match || fail "写入后槽位状态异常，请勿重启。原始分区备份位于 $work_dir。"
printf '两个目标镜像已写入并通过回读校验。备份位于 %s。\n' "$work_dir"
printf '下一步：回到系统升级页面点「重启」。\n'
)

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || fail '无法确定脚本目录。'
set -o pipefail || fail '请使用 Android 系统的 /system/bin/sh 运行脚本。'
log_file=$(mktemp "$script_dir/restore_fastboot.log.XXXXXXXX") || fail '无法在脚本同目录创建日志。'

# Preserve terminal input while tee receives the script's output.
{
    printf '开始时间 %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    main "$@" <&3 3<&-
} 3<&0 2>&1 | tee "$log_file"
result=$?
{
    printf '\n结束时间 %s\n退出码 %s\n日志已保存至 %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$result" "$log_file"
    printf '%s\n' 'GitHub 开源地址 https://github.com/xanthichi/coloros-fastboot-fix' \
        '夸克网盘 https://pan.quark.cn/s/1cc3228c49d6'
} | tee -a "$log_file" || exit 1
exit "$result"
