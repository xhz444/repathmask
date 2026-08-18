#!/system/bin/sh
#
# PkgMask service: expand the hide-package list into kernel target paths,
# compute the exempt UID set, insmod pkgmask.ko, and publish state.json
# for the WebUI.
#
# Environment overrides (used by the WebUI hot reload / action button):
#   PKGMASK_INITIAL_DELAY=0    skip the pre-wait sleep
#   PKGMASK_WAIT_SECONDS=15    override wait_seconds.conf for this run
#   PKGMASK_RESET_FAIL_GUARD=1 clear the consecutive-failure counter first
#   PKGMASK_IGNORE_FAIL_GUARD=1  load even if the failure guard tripped
#
# Persistent user config lives in /data/adb/pkgmask (outside the module
# dir, so it survives module updates). Templates ship in the module dir
# and are seeded on first boot.

MODDIR=${0%/*}
CONFDIR=/data/adb/pkgmask
KO_PATH="$MODDIR/pkgmask.ko"
LOG_FILE="$CONFDIR/service.log"
STATE_FILE="$CONFDIR/state.json"
FAIL_FILE="$CONFDIR/fail_count"
MAX_TARGETS=128
MAX_TARGET_CSV=16000
MAX_INSMOD_RETRIES=3

MODULE_VERSION=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)

log() {
	echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

json_escape() {
	# Values here are restricted to [A-Za-z0-9._:/-] but stay defensive.
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_field_escape() {
	# Like json_escape, but also neutralises spaces (as \u0020) so the
	# status entries stay single words for the space-separated transport
	# variable in write_state. Invalid package names may contain spaces.
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/ /\\u0020/g'
}

append_log_limited() {
	# Keep the log bounded: drop the oldest half when over 2000 lines.
	if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 2000 ]; then
		tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
	fi
}

read_conf_lines() {
	# Print non-empty, non-comment lines of a conf file.
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

package_to_uid_from_packages_list() {
	_pkg="$1"
	[ -f /data/system/packages.list ] || return 0
	while IFS= read -r _line || [ -n "$_line" ]; do
		set -- $_line
		[ "$1" = "$_pkg" ] || continue
		case "$2" in
			''|*[!0-9]*) return 0 ;;
			*) printf '%s\n' "$2"; return 0 ;;
		esac
	done < /data/system/packages.list
}

package_to_uid_from_pm() {
	_pkg="$1"
	_output="$(
		timeout 5 cmd package list packages --user 0 -U "$_pkg" 2>/dev/null || true
		timeout 5 pm list packages --user 0 -U "$_pkg" 2>/dev/null || true
	)"
	printf '%s\n' "$_output" | while IFS= read -r _line; do
		case "$_line" in package:*" uid:"*) ;; *) continue ;; esac
		_found_pkg=${_line#package:}; _found_pkg=${_found_pkg%% uid:*}
		_found_uid=${_line##* uid:}; _found_uid=${_found_uid%% *}
		[ "$_found_pkg" = "$_pkg" ] || continue
		case "$_found_uid" in ''|*[!0-9]*) ;; *) printf '%s\n' "$_found_uid"; break ;; esac
	done
}

package_to_uid_from_data_dir() {
	_pkg="$1"
	for _dir in "/data/user/0/$_pkg" "/data/data/$_pkg"; do
		[ -d "$_dir" ] || continue
		_uid=$(stat -c '%u' "$_dir" 2>/dev/null || true)
		case "$_uid" in ''|*[!0-9]*) ;; *) printf '%s\n' "$_uid"; return 0 ;; esac
		_info=$(ls -ldn "$_dir" 2>/dev/null || true); set -- $_info
		case "$3" in ''|*[!0-9]*) ;; *) printf '%s\n' "$3"; return 0 ;; esac
	done
}

package_to_uid() {
	_uid=$(package_to_uid_from_packages_list "$1" | head -n 1)
	[ -n "$_uid" ] && { printf '%s\n' "$_uid"; return; }
	_uid=$(package_to_uid_from_pm "$1" | head -n 1)
	[ -n "$_uid" ] && { printf '%s\n' "$_uid"; return; }
	package_to_uid_from_data_dir "$1" | head -n 1
}

write_state() {
	# write_state <loaded> <resolved> <target_count> <detail>
	_loaded="$1"; _resolved="$2"; _tcount="$3"; _detail="$(json_escape "$4")"
	_fail=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
	_kern="$(uname -r)"
	# uname -r looks like "6.1.99-android14-8-gxxxx" -- the KMI tag is the
	# androidNN part combined with the kernel major.minor.
	_android_tag=$(printf '%s' "$_kern" | grep -o 'android[0-9][0-9]*' | head -n 1)
	_kern_ver=$(printf '%s' "$_kern" | cut -d- -f1 | cut -d. -f1,2)
	if [ -n "$_android_tag" ] && [ -n "$_kern_ver" ]; then
		_kmi="$_android_tag-$_kern_ver"
	else
		_kmi=""
	fi

	{
		printf '{'
		printf '"ts":%s,' "$(date +%s)"
		printf '"module_version":"%s",' "$(json_escape "$MODULE_VERSION")"
		printf '"kernel":"%s",' "$(json_escape "$_kern")"
		printf '"kmi_guess":"%s",' "$(json_escape "${_kmi:-unknown}")"
		printf '"loaded":%s,' "$_loaded"
		printf '"resolved_count":%s,' "${_resolved:-0}"
		printf '"target_count":%s,' "${_tcount:-0}"
		printf '"fail_count":%s,' "${_fail:-0}"
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
		printf '}\n'
	} > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

mkdir -p "$CONFDIR"
chmod 0700 "$CONFDIR" 2>/dev/null
: > "$CONFDIR/.mounted" 2>/dev/null || true

append_log_limited
log "=== service start (version=$MODULE_VERSION kernel=$(uname -r)) ==="

# ---- seed persistent config from module templates -------------------------
for conf in hide_packages.conf exempt_packages.conf exempt_uids.conf system_uids.conf wait_seconds.conf; do
	if [ ! -f "$CONFDIR/$conf" ] && [ -f "$MODDIR/$conf" ]; then
		cp "$MODDIR/$conf" "$CONFDIR/$conf"
		log "seeded $CONFDIR/$conf from module template"
	fi
done

# Progress marker so the WebUI never reports "尚无 state.json" while a
# (possibly slow) load is in flight; overwritten with the real result at
# every exit path below.
EXEMPT_UIDS=""
PKG_STATUS_JSON=""
TARGET_LIST=""
write_state false 0 0 "service 运行中（正在加载，稍候刷新查看结果）"

# ---- failure guard ---------------------------------------------------------
if [ "${PKGMASK_RESET_FAIL_GUARD:-0}" = "1" ]; then
	echo 0 > "$FAIL_FILE" 2>/dev/null
	log "fail guard reset requested"
fi
FAIL_COUNT=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
case "$FAIL_COUNT" in
	''|*[!0-9]*) FAIL_COUNT=0 ;;
esac
if [ "$FAIL_COUNT" -ge 3 ] && [ "${PKGMASK_IGNORE_FAIL_GUARD:-0}" != "1" ]; then
	log "failure guard tripped ($FAIL_COUNT consecutive insmod failures), skipping load"
	EXEMPT_UIDS=""
	PKG_STATUS_JSON=""
	TARGET_LIST=""
	write_state false 0 0 "连续加载失败 $FAIL_COUNT 次，已熔断。更新 KMI 匹配的 .ko 后在 WebUI 里重置熔断并重载。"
	exit 0
fi

# ---- initial delay + storage readiness ------------------------------------
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

# ---- module binary --------------------------------------------------------
if [ ! -f "$KO_PATH" ]; then
	log "missing $KO_PATH"
	EXEMPT_UIDS=""
	PKG_STATUS_JSON=""
	TARGET_LIST=""
	write_state false 0 0 "模块目录缺少 pkgmask.ko（安装包损坏？请重新刷入）"
	exit 0
fi

# ---- hot reload: unload previous instance ---------------------------------
if grep -q '^pkgmask ' /proc/modules 2>/dev/null; then
	rmmod pkgmask 2>>"$LOG_FILE"
	if grep -q '^pkgmask ' /proc/modules 2>/dev/null; then
		log "rmmod failed, module still loaded; aborting to avoid double hooks"
		EXEMPT_UIDS=""
		PKG_STATUS_JSON=""
		TARGET_LIST=""
		write_state false 0 0 "旧实例卸载失败（rmmod），请重启后重试"
		exit 1
	fi
	log "unloaded previous instance for hot reload"
fi

# ---- resolve packages -> owner UIDs + target paths ------------------------
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

# Volume prefixes worth expanding. /sdcard is a symlink to user 0's
# emulated volume, but the write-op hooks match the *string* the app
# passed, so both spellings must be present as targets. The read side
# resolves through kern_path, so aliases collapse to the same inode.
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

# Exempt packages: resolve UID from the package database first. Shared
# storage backing directories are commonly owned by media_rw (1023), not
# the app, so they must never be used as an app-UID oracle.
for p in $(read_conf_lines "$CONFDIR/exempt_packages.conf"); do
	if ! valid_package_name "$p"; then
		log "ignore invalid exempt package name: $p"
		continue
	fi
	puid=$(package_to_uid "$p")
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

	# Resolve the real app UID from packages.list / PackageManager /
	# private data-dir ownership. Never use /data/media ownership here:
	# on many ROMs it is media_rw (1023), which would leave the hidden
	# app itself unexempt and break its File.mkdirs()/media loading.
	owner_uid=$(package_to_uid "$pkg")

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
		# No owner uid resolved: hide anyway, but the app itself may see
		# its own dirs as missing until reload. Rare (package list changed
		# mid-boot); surfaced in the WebUI status.
		log "hide package $pkg: $paths_added path(s) (owner uid NOT resolved!)"
		PKG_STATUS_JSON="$PKG_STATUS_JSON {\"package\":\"$(json_field_escape "$pkg")\",\"status\":\"hidden-no-owner-uid\",\"paths\":$paths_added}"
	fi
done <<EOF
$(read_conf_lines "$CONFDIR/hide_packages.conf")
EOF

# ---- load ------------------------------------------------------------------
INSMOD_ERR=""
LOADED=0
if [ "$TARGET_COUNT" -eq 0 ]; then
	log "no hideable targets; not loading kernel module"
	write_state false 0 0 "隐藏列表为空或包均未安装，未加载内核模块"
	exit 0
fi

attempt=1
while [ $attempt -le "$MAX_INSMOD_RETRIES" ]; do
	INSMOD_ERR=$(insmod "$KO_PATH" \
		"target_paths=$TARGETS_CSV" \
		"scope_mode=allow" \
		"deny_uids=$(printf '%s' "$EXEMPT_UIDS" | tr ' ' ',' | sed 's/^,//;s/,$//')" \
		"write_op_policy=eacces" 2>&1)
	if [ $? -eq 0 ]; then
		LOADED=1
		break
	fi
	log "insmod attempt $attempt failed: $INSMOD_ERR"
	case "$INSMOD_ERR" in
		*"Invalid module format"*|*"Exec format"*|*"disagrees about version"*|*"Unknown symbol"*)
			# KMI/ABI mismatch: retrying is pointless.
			break
			;;
	esac
	attempt=$((attempt + 1))
	sleep 3
done

if [ "$LOADED" -ne 1 ]; then
	FAIL_COUNT=$((FAIL_COUNT + 1))
	echo "$FAIL_COUNT" > "$FAIL_FILE" 2>/dev/null
	case "$INSMOD_ERR" in
		*"Invalid module format"*|*"Exec format"*|*"disagrees about version"*|*"Unknown symbol"*)
			DETAIL="内核模块与设备不匹配（$INSMOD_ERR）。请用 uname -r 对照内核版本，刷入对应 KMI 的 zip，或按 README 用机型内核源码本地编译。"
			;;
		*)
			DETAIL="insmod 失败：$INSMOD_ERR"
			;;
	esac
	log "load failed (fail_count=$FAIL_COUNT): $DETAIL"
	write_state false 0 "$TARGET_COUNT" "$DETAIL"
	exit 1
fi

echo 0 > "$FAIL_FILE" 2>/dev/null

RESOLVED=$(cat /sys/module/pkgmask/parameters/resolved_count 2>/dev/null)
case "$RESOLVED" in
	''|*[!0-9]*) RESOLVED=0 ;;
esac

log "loaded: resolved=$RESOLVED/$TARGET_COUNT target(s), exempt uids:$EXEMPT_UIDS"
write_state true "$RESOLVED" "$TARGET_COUNT" "运行中"
exit 0
