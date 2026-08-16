#!/system/bin/sh
# PkgMask uninstall: unload the kernel module and remove persistent state.
# User conf files under /data/adb/pkgmask are kept unless PKGMASK_PURGE=1.

MODDIR=${0%/*}

if grep -q '^pkgmask ' /proc/modules 2>/dev/null; then
	rmmod pkgmask 2>/dev/null
fi

rm -f /data/adb/pkgmask/state.json /data/adb/pkgmask/service.log /data/adb/pkgmask/fail_count /data/adb/pkgmask/.mounted 2>/dev/null

if [ "${PKGMASK_PURGE:-0}" = "1" ]; then
	rm -rf /data/adb/pkgmask 2>/dev/null
fi

exit 0
