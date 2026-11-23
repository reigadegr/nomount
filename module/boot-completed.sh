#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"

MODULES_DIR="${MODULES_DIR:-/data/adb/modules}"

if [ -f "$BOOT_SEMAPHORE" ]; then
    rm -f "$BOOT_SEMAPHORE"
    klog "boot completed safely."
fi

if [ -f "$DUMP_RULES_FLAG" ]; then
    dump_all_rules_logcat "on boot" || true
fi

# ── 开机后二次注入 ────────────────────────────────────────────────────────────
#
# post-fs-data 阶段的注入发生在其他模块写文件之前。而模块往 system/ 送内容的
# 常见做法是「暂存目录 + rm -rf 旧目录 + mv 过来」——整棵子树的 inode 会换掉。
# 规则在那时就绑好了旧 inode，目标路径因此变负，stat 给 ENOENT：表现为安装记录
# 里的 APK「缺失」，任何按 sourceDir 逐包核对文件是否存在的检测都会直接命中，
# 不需要任何计时分析。
#
# 内核侧现在会在 lookup 时重绑自愈，但自愈要多走一轮慢路径才稳定。这里在
# boot_completed 之后整体重载一次，让绑定从一开始就指向最终对象。
#
# 为什么不能只重载一次：各模块的 service.sh / boot-completed.sh 与本脚本的执行
# 顺序不确定，重写可能发生在我们之后。所以用「指纹稳定」收尾——重载后若模块
# system/ 树的 (path,inode,size,mtime) 又变了，就再重载，最多 N 轮。
#
# 为什么不直接调 metamount.sh：它内部的 bootloop_check 在信号文件缺失时会重写
# 它，而我们在上面刚把它删掉；写回去的是本次 boot_id，下次开机比对必然不等，
# 会被判成 bootloop 并 disable 模块。这里只做重载，不碰那套判定。
#
# 关闭：touch /data/adb/nomount/no_boot_reload
# 调参：环境变量 BOOT_RELOAD_DELAY / BOOT_RELOAD_INTERVAL / BOOT_RELOAD_ROUNDS

BOOT_RELOAD_DELAY="${BOOT_RELOAD_DELAY:-20}"
BOOT_RELOAD_INTERVAL="${BOOT_RELOAD_INTERVAL:-12}"
BOOT_RELOAD_ROUNDS="${BOOT_RELOAD_ROUNDS:-3}"

nm_modules_fingerprint() {
    for _d in "$MODULES_DIR"/*/system; do
        [ -d "$_d" ] || continue
        find "$_d" \( -type f -o -type l \) -exec stat -c '%n %i %s %Y' {} + 2>/dev/null
    done | md5sum 2>/dev/null
}

nm_reload_modules() {
    local mod_path mod_name status=0

    for mod_path in "$MODULES_DIR"/*; do
        [ -d "$mod_path" ] || continue
        mod_name="${mod_path##*/}"
        [ "$mod_name" = "nomount" ] && continue
        if [ -f "$mod_path/disable" ] || [ -f "$mod_path/remove" ] || [ -f "$mod_path/skip_mount" ]; then
            continue
        fi
        "$LOADER" module load "$mod_path" || status=1
    done
    return "$status"
}

if [ -f "$NOMOUNT_DATA/no_boot_reload" ]; then
    klog "post-boot reload disabled by flag"
elif ! "$LOADER" version >/dev/null 2>&1; then
    klogwarn "post-boot reload skipped: LKM not loaded"
elif ! _lock_acquire "$NOMOUNT_DATA/.inject.flock" 60; then
    klogwarn "post-boot reload skipped: injection lock busy"
else
    trap '_lock_release' EXIT INT TERM

    prev="$(nm_modules_fingerprint)"
    if [ "$BOOT_RELOAD_DELAY" -gt 0 ] 2>/dev/null; then
        sleep "$BOOT_RELOAD_DELAY"
    fi

    round=0
    while :; do
        nm_reload_modules || klogwarn "post-boot reload round $round finished with errors"
        klog "post-boot reload round $round done"

        [ "$round" -ge "$BOOT_RELOAD_ROUNDS" ] && break
        sleep "$BOOT_RELOAD_INTERVAL"

        cur="$(nm_modules_fingerprint)"
        [ "$cur" = "$prev" ] && break
        prev="$cur"
        round=$((round + 1))
    done

    _lock_release
    trap - EXIT INT TERM
fi

exit 0
