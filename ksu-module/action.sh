#!/system/bin/sh
# KernelSU "Action" button: hot-reload PkgMask with the current config
# (same as the WebUI 重载按钮, usable without opening the WebUI).

MODDIR=${0%/*}

echo "PkgMask 重载中..."
PKGMASK_RESET_FAIL_GUARD=1 PKGMASK_INITIAL_DELAY=0 PKGMASK_WAIT_SECONDS=15 sh "$MODDIR/service.sh"
rc=$?

if [ $rc -eq 0 ]; then
	if grep -q '^pkgmask ' /proc/modules 2>/dev/null; then
		echo "已加载。"
	else
		echo "本次未加载（详见 WebUI 状态页）"
	fi
else
	echo "重载失败（详见 WebUI 状态页/日志）"
fi
exit $rc
