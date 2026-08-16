#!/system/bin/sh
# KernelSU "Action" button: hot-reload pkgmask + re-evaluate scene watcher,
# then print a one-line summary of all three components.

MODDIR=${0%/*}

echo "PathMask Fusion 重载中..."
PKGMASK_RESET_FAIL_GUARD=1 PKGMASK_INITIAL_DELAY=0 PKGMASK_WAIT_SECONDS=15 sh "$MODDIR/service.sh"
rc=$?

if grep -q '^pkgmask ' /proc/modules 2>/dev/null; then
	echo "pkgmask: 已加载"
else
	echo "pkgmask: 未加载（详见 WebUI 状态页）"
fi
if grep -q '^procguard ' /proc/modules 2>/dev/null; then
	echo "procguard: 已加载"
else
	echo "procguard: 未加载"
fi
if [ -f "$MODDIR/scene-debugfs-watch.sh" ]; then
	wpid=$(cat /data/adb/pathmask/scene_debugfs_watch.lock/pid 2>/dev/null || true)
	if [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; then
		echo "scene 监视: 运行中 (pid $wpid)"
	else
		echo "scene 监视: 未运行（未装 Scene 或已停止）"
	fi
else
	echo "scene 监视: 本包未包含"
fi
exit $rc
