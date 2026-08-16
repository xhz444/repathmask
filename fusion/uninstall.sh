#!/system/bin/sh
# PathMask Fusion uninstall: stop scene watcher, unload pkgmask + procguard,
# clean state. User conf files under /data/adb/pathmask are kept unless
# PKGMASK_PURGE=1.

MODDIR=${0%/*}
STATE_DIR=${SCENE_WATCH_STATE_DIR:-/data/adb/pathmask}
LOCK_DIR="$STATE_DIR/scene_debugfs_watch.lock"
STOP_PATH="$STATE_DIR/scene_debugfs_watch.stop"

log_i() {
	log -p i -t pkgmask-fusion "$*" 2>/dev/null || true
}

stop_scene_watcher() {
	mkdir -p "$STATE_DIR" 2>/dev/null || return 0
	: > "$STOP_PATH" 2>/dev/null || true

	wpid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
	case "$wpid" in
		''|*[!0-9]*) return 0 ;;
	esac
	if kill -0 "$wpid" 2>/dev/null; then
		cmdline="$(tr '\000' ' ' < "/proc/$wpid/cmdline" 2>/dev/null || true)"
		case "$cmdline" in
			*scene-debugfs-watch.sh*)
				kill "$wpid" 2>/dev/null || true
				log_i "stopped Scene watcher pid=$wpid"
				;;
		esac
	fi
}

stop_scene_watcher

if grep -q '^pkgmask ' /proc/modules 2>/dev/null; then
	rmmod pkgmask 2>/dev/null && log_i "rmmod pkgmask ok" || log_i "rmmod pkgmask failed; unloads after reboot"
fi

if grep -q '^procguard ' /proc/modules 2>/dev/null; then
	rmmod procguard 2>/dev/null && log_i "rmmod procguard ok" || log_i "rmmod procguard failed; unloads after reboot"
fi

rm -f \
	"$STATE_DIR/scene_debugfs_state" \
	"$STATE_DIR/scene_debugfs_paths" \
	"$STATE_DIR/scene_susfs_targets" \
	"$STATE_DIR/procguard_boot_state" \
	"$STATE_DIR/state.json" \
	"$STATE_DIR/service.log" \
	"$STATE_DIR/fail_count" \
	"$LOCK_DIR/pid" \
	"$STOP_PATH" 2>/dev/null || true
rmdir "$LOCK_DIR" 2>/dev/null || true

if [ "${PKGMASK_PURGE:-0}" = "1" ]; then
	rm -rf "$STATE_DIR" 2>/dev/null
else
	rmdir "$STATE_DIR" 2>/dev/null || true
fi

exit 0
