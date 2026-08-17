#!/system/bin/sh
#
# PathMask Fusion boot service.
#
# Merges the user's original ProcGuard loader package with PkgMask:
#   1. procguard.ko   - loaded with retry + vermagic precheck (was: single
#                       insmod attempt, silent failure)
#   2. scene watcher  - started only when scene-debugfs-watch.sh ships in
#                       the module AND the Scene package (com.omarea.vtools)
#                       is installed; no polling at all otherwise
#   3. pkgmask.ko     - PkgMask package hiding (see kernel/pkgmask.c):
#                       hide list -> target paths, exempt UID set,
#                       write-op errno masquerade, fail guard, state.json
#
# The package is a drop-in upgrade of the previous id=pathmask module;
# /data/adb/pathmask keeps scene/procguard state files and gains the
# pkgmask conf files.
#
# Environment overrides (WebUI hot reload / action button):
#   PKGMASK_INITIAL_DELAY=0 / PKGMASK_WAIT_SECONDS=15
#   PKGMASK_RESET_FAIL_GUARD=1 / PKGMASK_IGNORE_FAIL_GUARD=1
#   SCENE_WATCH_DISABLED=1 (skip scene watcher for this run)

MODDIR=${0%/*}
CONFDIR=/data/adb/pathmask
PKG_KO="$MODDIR/pkgmask.ko"
PKG_MODNAME=pkgmask
PG_KO="$MODDIR/procguard.ko"
SCENE_SCRIPT="$MODDIR/scene-debugfs-watch.sh"
LOG_FILE="$CONFDIR/service.log"
STATE_FILE="$CONFDIR/state.json"
FAIL_FILE="$CONFDIR/fail_count"
MAX_TARGETS=128
MAX_TARGET_CSV=16000
MAX_INSMOD_RETRIES=3
SCENE_PACKAGES="com.omare.vtools com.omarea.vtools"

MODULE_VERSION=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)

PG_STATUS="missing"
PG_DETAIL=""
PG_LOADED=0
SCENE_STATUS="no-script"
SCENE_DETAIL=""

log() {
	echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

log_i() {
	log -p i -t pkgmask-fusion "$*" 2>/dev/null || true
}

json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_field_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/ /\\u0020/g'
}

append_log_limited() {
	if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 2000 ]; then
		tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
	fi
}

read_conf_lines() {
	[ -f "$1" ] && sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$1"
}

valid_package_name() {
	case "$1" in
		''|*[!a-zA-Z0-9._]*)
			return 1
			;;
		*)
			return 0
			;;
	esac
}

# vermagic note: on CONFIG_MODVERSIONS kernels (all Android GKI/OEM builds
# here) the kernel's same_magic() IGNORES the release token of vermagic and
# relies on per-symbol CRCs instead -- a ko built for 6.1.75 loads fine on
# 6.1.141. So a vermagic difference is only a DIAGNOSTIC hint, never a
# reason to skip insmod; we record both strings and surface them when the
# load fails. Unreadable -> "unknown".
ko_vermagic() {
	strings "$1" 2>/dev/null | grep -m 1 '^vermagic=' | cut -d= -f2 | cut -d' ' -f1
}

write_state() {
	# write_state <pkgmask_loaded> <resolved> <target_count> <detail>
	_loaded="$1"; _resolved="$2"; _tcount="$3"; _detail="$(json_escape "$4")"
	_fail=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
	_kern="$(uname -r)"
	_android_tag=$(printf '%s' "$_kern" | grep -o 'android[0-9][0-9]*' | head -n 1)
	_kern_ver=$(printf '%s' "$_kern" | cut -d- -f1 | cut -d. -f1,2)
	if [ -n "$_android_tag" ] && [ -n "$_kern_ver" ]; then
		_kmi="$_android_tag-$_kern_ver"
	else
		_kmi=""
	fi
	_pgver=$(ko_vermagic "$PG_KO")
	_pkver=$(ko_vermagic "$PKG_KO")

	{
		printf '{'
		printf '"ts":%s,' "$(date +%s)"
		printf '"module_version":"%s",' "$(json_escape "$MODULE_VERSION")"
		printf '"kernel":"%s",' "$(json_escape "$_kern")"
		printf '"kmi_guess":"%s",' "$(json_escape "${_kmi:-unknown}")"
		printf '"fusion":true,'
		printf '"pkgmask":{'
		printf '"loaded":%s,' "$_loaded"
		printf '"resolved_count":%s,' "${_resolved:-0}"
		printf '"target_count":%s,' "${_tcount:-0}"
		printf '"fail_count":%s,' "${_fail:-0}"
		printf '"ko_vermagic":"%s",' "$(json_escape "${_pkver:-unknown}")"
		printf '"policy":"eacces","scope":"allow",'
		printf '"detail":"%s",' "$_detail"
		printf '"exempt_uids":['
		first=1
		for u in $EXEMPT_UIDS; do
			[ $first -eq 1 ] || printf ','
			printf '%s' "$u"
			first=0
		done
		printf '],'
		printf '"packages":['
		first=1
		for entry in $PKG_STATUS_JSON; do
			[ $first -eq 1 ] || printf ','
			printf '%s' "$entry"
			first=0
		done
		printf '],'
		printf '"targets":['
		first=1
		for t in $TARGET_LIST; do
			[ $first -eq 1 ] || printf ','
			printf '"%s"' "$(json_escape "$t")"
			first=0
		done
		printf ']'
		printf '},'
		printf '"procguard":{'
		printf '"loaded":%s,' "$PG_LOADED"
		printf '"status":"%s",' "$(json_escape "$PG_STATUS")"
		printf '"ko_vermagic":"%s",' "$(json_escape "${_pgver:-unknown}")"
		printf '"detail":"%s"' "$(json_escape "$PG_DETAIL")"
		printf '},'
		printf '"scene":{'
		printf '"status":"%s",' "$(json_escape "$SCENE_STATUS")"
		printf '"detail":"%s"' "$(json_escape "$SCENE_DETAIL")"
		printf '}'
		printf '}\n'
	} > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE"

	# Backward-compatible flat file for the previous loader package.
	printf 'status=%s\nmodule=procguard\npath=%s\nupdated=%s\ndetail=%s\n' \
		"$PG_STATUS" "$PG_KO" "$(date +%s)" "$PG_DETAIL" \
		> "$CONFDIR/procguard_boot_state" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
mkdir -p "$CONFDIR"
chmod 0700 "$CONFDIR" 2>/dev/null

append_log_limited
log "=== fusion service start (version=$MODULE_VERSION kernel=$(uname -r)) ==="

# ---- seed pkgmask conf files (never touches scene/procguard state) --------
for conf in hide_packages.conf exempt_packages.conf exempt_uids.conf system_uids.conf wait_seconds.conf; do
	if [ ! -f "$CONFDIR/$conf" ] && [ -f "$MODDIR/$conf" ]; then
		cp "$MODDIR/$conf" "$CONFDIR/$conf"
		log "seeded $CONFDIR/$conf from module template"
	fi
done

# ---- 1. procguard: retry load + vermagic precheck --------------------------
load_procguard() {
	if grep -q '^procguard ' /proc/modules 2>/dev/null; then
		PG_STATUS="already-loaded"
		PG_DETAIL="present in /proc/modules"
		PG_LOADED=1
		return 0
	fi
	if [ ! -f "$PG_KO" ]; then
		PG_STATUS="missing"
		PG_DETAIL="not found: $PG_KO"
		return 0
	fi

	vm=$(ko_vermagic "$PG_KO")
	PG_VM_NOTE=""
	if [ -n "$vm" ] && [ "$vm" != "$(uname -r)" ]; then
		PG_VM_NOTE="ko=$vm kernel=$(uname -r)"
		log "procguard vermagic differs (may still load under modversions): $PG_VM_NOTE"
	fi

	pgat=1
	while [ $pgat -le "$MAX_INSMOD_RETRIES" ]; do
		if insmod "$PG_KO" 2>>"$LOG_FILE"; then
			PG_STATUS="loaded"
			if [ -n "$PG_VM_NOTE" ]; then
				PG_DETAIL="insmod ok (attempt $pgat; vermagic differs but accepted: $PG_VM_NOTE)"
			else
				PG_DETAIL="insmod ok (attempt $pgat)"
			fi
			PG_LOADED=1
			log "procguard loaded (attempt $pgat)"
			return 0
		fi
		log "procguard insmod attempt $pgat failed"
		pgat=$((pgat + 1))
		sleep 3
	done
	PG_STATUS="failed"
	if [ -n "$PG_VM_NOTE" ]; then
		PG_DETAIL="insmod failed ${MAX_INSMOD_RETRIES}x ($PG_VM_NOTE); likely symbol CRC mismatch, rebuild against the current kernel tree"
	else
		PG_DETAIL="insmod failed ${MAX_INSMOD_RETRIES}x, see dmesg"
	fi
	return 0
}
load_procguard

# ---- 2. scene watcher: only when script ships AND Scene is installed -------
start_scene() {
	if [ ! -f "$SCENE_SCRIPT" ]; then
		SCENE_STATUS="no-script"
		SCENE_DETAIL="scene-debugfs-watch.sh not in this package"
		return 0
	fi
	if [ "${SCENE_WATCH_DISABLED:-0}" = "1" ]; then
		SCENE_STATUS="disabled"
		SCENE_DETAIL="SCENE_WATCH_DISABLED=1"
		return 0
	fi

	# Already running? (lock pid from the watcher's own lock dir)
	wpid=$(cat "$CONFDIR/scene_debugfs_watch.lock/pid" 2>/dev/null || true)
	case "$wpid" in
		''|*[!0-9]*) ;;
		*)
			if kill -0 "$wpid" 2>/dev/null; then
				SCENE_STATUS="already-running"
				SCENE_DETAIL="watcher pid=$wpid"
				return 0
			fi
			;;
	esac

	scene_installed=0
	if [ -r /data/system/packages.list ]; then
		for p in $SCENE_PACKAGES; do
			grep -q "^$p " /data/system/packages.list 2>/dev/null && scene_installed=1
		done
	fi
	if [ "$scene_installed" -ne 1 ]; then
		SCENE_STATUS="package-absent"
		SCENE_DETAIL="Scene not installed; watcher not started (restart via WebUI reload after installing Scene)"
		log "scene watcher skipped: package absent"
		return 0
	fi

	rm -f "$CONFDIR/scene_debugfs_watch.stop" 2>/dev/null || true
	if command -v setsid >/dev/null 2>&1; then
		SCENE_WATCH_STATE_DIR="$CONFDIR" setsid sh "$SCENE_SCRIPT" </dev/null >/dev/null 2>&1 &
	else
		SCENE_WATCH_STATE_DIR="$CONFDIR" sh "$SCENE_SCRIPT" </dev/null >/dev/null 2>&1 &
	fi
	SCENE_STATUS="started"
	SCENE_DETAIL="watcher pid=$!"
	log "scene watcher started pid=$!"
}
start_scene

# ---- 3. pkgmask ------------------------------------------------------------
if [ "${PKGMASK_RESET_FAIL_GUARD:-0}" = "1" ]; then
	echo 0 > "$FAIL_FILE" 2>/dev/null
	log "fail guard reset requested"
fi
FAIL_COUNT=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
case "$FAIL_COUNT" in
	''|*[!0-9]*) FAIL_COUNT=0 ;;
esac
if [ "$FAIL_COUNT" -ge 3 ] && [ "${PKGMASK_IGNORE_FAIL_GUARD:-0}" != "1" ]; then
	log "failure guard tripped ($FAIL_COUNT consecutive insmod failures), skipping pkgmask load"
	EXEMPT_UIDS=""
	PKG_STATUS_JSON=""
	TARGET_LIST=""
	write_state false 0 0 "pkgmask 连续加载失败 $FAIL_COUNT 次，已熔断。核对 .ko 与内核版本后在 WebUI 里重置并重载。"
	exit 0
fi

if [ -z "${PKGMASK_INITIAL_DELAY:-}" ]; then
	PKGMASK_INITIAL_DELAY=5
fi
sleep "$PKGMASK_INITIAL_DELAY" 2>/dev/null || sleep 5

WAIT_BUDGET=$(head -n 1 "$CONFDIR/wait_seconds.conf" 2>/dev/null)
case "$WAIT_BUDGET" in
	''|*[!0-9]*) WAIT_BUDGET=60 ;;
esac
if [ -n "${PKGMASK_WAIT_SECONDS:-}" ]; then
	case "$PKGMASK_WAIT_SECONDS" in
		''|*[!0-9]*) ;;
		*) WAIT_BUDGET="$PKGMASK_WAIT_SECONDS" ;;
	esac
fi

waited=0
while [ $waited -lt "$WAIT_BUDGET" ]; do
	[ -d /storage/emulated/0/Android/data ] && break
	sleep 2
	waited=$((waited + 2))
done
if [ ! -d /storage/emulated/0/Android/data ]; then
	log "shared storage not ready after ${WAIT_BUDGET}s; loading anyway with what exists"
fi

if [ ! -f "$PKG_KO" ]; then
	log "pkgmask.ko not present; procguard/scene keep running without path hiding"
	EXEMPT_UIDS=""
	PKG_STATUS_JSON=""
	TARGET_LIST=""
	write_state false 0 0 "pkgmask.ko 未安装：procguard/Scene 功能正常，路径隐藏未激活。放入 ko 后点 WebUI 热重载。"
	exit 0
fi

if grep -q "^$PKG_MODNAME " /proc/modules 2>/dev/null; then
	rmmod "$PKG_MODNAME" 2>>"$LOG_FILE"
	if grep -q "^$PKG_MODNAME " /proc/modules 2>/dev/null; then
		log "rmmod $PKG_MODNAME failed, module still loaded; aborting to avoid double hooks"
		EXEMPT_UIDS=""
		PKG_STATUS_JSON=""
		TARGET_LIST=""
		write_state false 0 0 "pkgmask 旧实例卸载失败（rmmod），请重启后重试"
		exit 1
	fi
	log "unloaded previous pkgmask instance for hot reload"
fi

TARGET_LIST=""
TARGETS_CSV=""
TARGET_COUNT=0
EXEMPT_UIDS=""
PKG_STATUS_JSON=""

add_target() {
	_t="$1"
	case " $TARGET_LIST " in
		*" $_t "*) return 0 ;;
	esac
	if [ "$TARGET_COUNT" -ge "$MAX_TARGETS" ]; then
		log "target limit ($MAX_TARGETS) reached, skipping $_t"
		return 1
	fi
	if [ $(( ${#TARGETS_CSV} + ${#_t} + 1 )) -gt "$MAX_TARGET_CSV" ]; then
		log "target_paths parameter length limit reached, skipping $_t"
		return 1
	fi
	if [ -z "$TARGET_LIST" ]; then
		TARGET_LIST="$_t"
		TARGETS_CSV="$_t"
	else
		TARGET_LIST="$TARGET_LIST $_t"
		TARGETS_CSV="$TARGETS_CSV,$_t"
	fi
	TARGET_COUNT=$((TARGET_COUNT + 1))
	return 0
}

add_exempt_uid() {
	case " $EXEMPT_UIDS " in
		*" $1 "*) return 0 ;;
	esac
	EXEMPT_UIDS="$EXEMPT_UIDS $1"
}

PREFIXES="/sdcard"
for v in /storage/emulated/*; do
	[ -d "$v" ] && PREFIXES="$PREFIXES $v"
done
for v in /storage/*; do
	case "$v" in
		/storage/emulated|/storage/self) continue ;;
	esac
	[ -d "$v/Android" ] && PREFIXES="$PREFIXES $v"
done
log "volume prefixes: $PREFIXES"

for u in $(read_conf_lines "$CONFDIR/system_uids.conf"); do
	case "$u" in
		''|*[!0-9]*) log "ignore invalid system uid: $u" ;;
		*) add_exempt_uid "$u" ;;
	esac
done
for u in $(read_conf_lines "$CONFDIR/exempt_uids.conf"); do
	case "$u" in
		''|*[!0-9]*) log "ignore invalid exempt uid: $u" ;;
		*) add_exempt_uid "$u" ;;
	esac
done

for p in $(read_conf_lines "$CONFDIR/exempt_packages.conf"); do
	if ! valid_package_name "$p"; then
		log "ignore invalid exempt package name: $p"
		continue
	fi
	puid=""
	for d in /data/user/*/"$p" /data/data/"$p"; do
		[ -d "$d" ] || continue
		puid=$(stat -c '%u' "$d" 2>/dev/null) && [ -n "$puid" ] && break
		puid=""
	done
	if [ -n "$puid" ]; then
		add_exempt_uid "$puid"
		log "exempt package $p -> uid $puid"
	else
		log "exempt package $p not installed, nothing to exempt"
	fi
done

while IFS= read -r pkg; do
	[ -n "$pkg" ] || continue
	if ! valid_package_name "$pkg"; then
		log "ignore invalid package name: $pkg"
		PKG_STATUS_JSON="$PKG_STATUS_JSON {\"package\":\"$(json_field_escape "$pkg")\",\"status\":\"invalid-name\"}"
		continue
	fi

	owner_uid=""
	for d in /data/media/*/Android/data/"$pkg"; do
		[ -d "$d" ] || continue
		owner_uid=$(stat -c '%u' "$d" 2>/dev/null)
		[ -n "$owner_uid" ] && break
		owner_uid=""
	done
	if [ -z "$owner_uid" ]; then
		# dumpsys can take seconds per unknown package and makes the
		# WebUI hot reload feel hung -- bound it (toybox timeout).
		owner_uid=$(timeout 5 dumpsys package "$pkg" 2>/dev/null | grep -m 1 -o 'userId=[0-9]*' | cut -d= -f2)
	fi

	paths_added=0
	for prefix in $PREFIXES; do
		for sub in data obb; do
			cand="$prefix/Android/$sub/$pkg"
			if [ -d "$cand" ]; then
				if add_target "$cand"; then
					paths_added=$((paths_added + 1))
				fi
			fi
		done
	done

	if [ "$paths_added" -eq 0 ]; then
		log "package $pkg: no Android/data|obb dirs found (not installed or not yet created) -- nothing to hide"
		PKG_STATUS_JSON="$PKG_STATUS_JSON {\"package\":\"$(json_field_escape "$pkg")\",\"status\":\"not-installed\"}"
		continue
	fi

	if [ -n "$owner_uid" ]; then
		add_exempt_uid "$owner_uid"
		log "hide package $pkg (owner uid $owner_uid): $paths_added path(s)"
		PKG_STATUS_JSON="$PKG_STATUS_JSON {\"package\":\"$(json_field_escape "$pkg")\",\"status\":\"hidden\",\"uid\":$owner_uid,\"paths\":$paths_added}"
	else
		log "hide package $pkg: $paths_added path(s) (owner uid NOT resolved!)"
		PKG_STATUS_JSON="$PKG_STATUS_JSON {\"package\":\"$(json_field_escape "$pkg")\",\"status\":\"hidden-no-owner-uid\",\"paths\":$paths_added}"
	fi
done <<EOF
$(read_conf_lines "$CONFDIR/hide_packages.conf")
EOF

INSMOD_ERR=""
LOADED=0
if [ "$TARGET_COUNT" -eq 0 ]; then
	log "no hideable targets; not loading pkgmask"
	write_state false 0 0 "隐藏列表为空或包均未安装，pkgmask 未加载（procguard/Scene 不受影响）"
	exit 0
fi

# vermagic hint for failure messages (see note at ko_vermagic: the release
# token is ignored under modversions, so we never skip the attempt).
kvm=$(ko_vermagic "$PKG_KO")
PKG_VM_NOTE=""
if [ -n "$kvm" ] && [ "$kvm" != "$(uname -r)" ]; then
	PKG_VM_NOTE="ko=$kvm kernel=$(uname -r)"
	log "pkgmask vermagic differs (may still load under modversions): $PKG_VM_NOTE"
fi

attempt=1
while [ $attempt -le "$MAX_INSMOD_RETRIES" ]; do
	INSMOD_ERR=$(insmod "$PKG_KO" \
		"target_paths=$TARGETS_CSV" \
		"scope_mode=allow" \
		"deny_uids=$(printf '%s' "$EXEMPT_UIDS" | tr ' ' ',' | sed 's/^,//;s/,$//')" \
		"write_op_policy=eacces" 2>&1)
	if [ $? -eq 0 ]; then
		LOADED=1
		break
	fi
	log "pkgmask insmod attempt $attempt failed: $INSMOD_ERR"
	case "$INSMOD_ERR" in
		*"Invalid module format"*|*"Exec format"*|*"disagrees about version"*|*"Unknown symbol"*)
			break
			;;
	esac
	attempt=$((attempt + 1))
	sleep 3
done

if [ "$LOADED" -ne 1 ]; then
	FAIL_COUNT=$((FAIL_COUNT + 1))
	echo "$FAIL_COUNT" > "$FAIL_FILE" 2>/dev/null
	VM_HINT=""
	[ -n "$PKG_VM_NOTE" ] && VM_HINT="；vermagic 对照：$PKG_VM_NOTE"
	case "$INSMOD_ERR" in
		*"Invalid module format"*|*"Exec format"*|*"disagrees about version"*|*"Unknown symbol"*)
			DETAIL="pkgmask 内核模块与设备不匹配（$INSMOD_ERR）$VM_HINT。请按 README 用当前内核源码树编译。"
			;;
		*)
			DETAIL="pkgmask insmod 失败：$INSMOD_ERR$VM_HINT"
			;;
	esac
	log "pkgmask load failed (fail_count=$FAIL_COUNT): $DETAIL"
	write_state false 0 "$TARGET_COUNT" "$DETAIL"
	exit 1
fi

echo 0 > "$FAIL_FILE" 2>/dev/null

RESOLVED=$(cat "/sys/module/$PKG_MODNAME/parameters/resolved_count" 2>/dev/null)
case "$RESOLVED" in
	''|*[!0-9]*) RESOLVED=0 ;;
esac

log "pkgmask loaded: resolved=$RESOLVED/$TARGET_COUNT target(s), exempt uids:$EXEMPT_UIDS"
write_state true "$RESOLVED" "$TARGET_COUNT" "运行中"
exit 0
