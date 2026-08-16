#!/usr/bin/env sh
# Build a PathMask Fusion KernelSU zip from the user's existing loader zip.
#
# Usage: sh tools/package_fusion.sh <source_zip> [pkgmask.ko] [output_zip]
#   source_zip   the previous id=pathmask loader package containing
#                procguard.ko (and optionally scene-debugfs-watch.sh)
#   pkgmask.ko   optional; when present it activates path hiding in the
#                same install -- otherwise the zip can be flashed first and
#                the ko dropped into the module dir later
#   output_zip   default out/PathMask-Fusion-<kmi>.zip (kmi guessed from
#                the source zip filename)
#
# Layout of the produced zip:
#   module.prop / service.sh / uninstall.sh / action.sh   (fusion template)
#   hide_packages.conf ... wait_seconds.conf              (pkgmask confs)
#   webroot/                                              (fusion-aware WebUI)
#   procguard.ko                                          (from source zip)
#   scene-debugfs-watch.sh                                (from source zip, if any)
#   pkgmask.ko                                            (optional argument)
set -eu

SRC_ZIP="${1:-}"
PKG_KO="${2:-}"
OUTPUT="${3:-}"

# ELF magic check: a real .ko starts with 7f 45 4c 46. Guards against
# packaging a non-module file (e.g. a stray zip) as pkgmask.ko.
is_elf() {
	[ -f "$1" ] || return 1
	magic=$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')
	[ "$magic" = "7f454c46" ]
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
FUSION_DIR="$REPO_ROOT/fusion"
TEMPLATE_DIR="$REPO_ROOT/ksu-module"
STAGE_DIR="$REPO_ROOT/out/fusion-stage"

if [ -z "$SRC_ZIP" ]; then
	echo "usage: sh tools/package_fusion.sh <source_zip> [pkgmask.ko] [output_zip]" >&2
	exit 1
fi

case "$SRC_ZIP" in
	/*) ;;
	*) SRC_ZIP="$REPO_ROOT/$SRC_ZIP" ;;
esac
if [ ! -f "$SRC_ZIP" ]; then
	echo "Missing source zip: $SRC_ZIP" >&2
	exit 1
fi

# Flexible arg handling: if $2 is not an ELF file it is the output path
# (allows "package_fusion.sh <src> <out.zip>" without a ko).
if [ -n "$PKG_KO" ] && ! is_elf "$PKG_KO"; then
	[ -n "$OUTPUT" ] && echo "warning: '$2' is not an ELF module; treating it as output_zip" >&2
	OUTPUT="${OUTPUT:-$PKG_KO}"
	PKG_KO=""
fi
if [ -n "$PKG_KO" ]; then
	case "$PKG_KO" in
		/*) ;;
		*) PKG_KO="$REPO_ROOT/$PKG_KO" ;;
	esac
	if ! is_elf "$PKG_KO"; then
		echo "pkgmask.ko argument is not an ELF module: $PKG_KO" >&2
		exit 1
	fi
fi

# KMI tag from the source zip filename (e.g. android14-6.1_pathmask-ksu.zip).
KMI_TAG=$(basename "$SRC_ZIP" .zip | sed -n 's/^\(android[0-9]*-[0-9]*\.[0-9]*\)_.*/\1/p')
if [ -z "$OUTPUT" ]; then
	if [ -n "$KMI_TAG" ]; then
		OUTPUT="out/PathMask-Fusion-$KMI_TAG.zip"
	else
		OUTPUT="out/PathMask-Fusion.zip"
	fi
fi
case "$OUTPUT" in
	/*) ;;
	*) OUTPUT="$REPO_ROOT/$OUTPUT" ;;
esac

if ! command -v zip >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
	echo "Missing dependency: unzip, and zip or python" >&2
	exit 1
fi
if ! command -v unzip >/dev/null 2>&1; then
	echo "Missing dependency: unzip" >&2
	exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$(dirname -- "$OUTPUT")" "$STAGE_DIR/_src"

unzip -q -o "$SRC_ZIP" -d "$STAGE_DIR/_src"
if [ ! -f "$STAGE_DIR/_src/procguard.ko" ]; then
	echo "source zip does not contain procguard.ko -- not a fusion-compatible loader package" >&2
	rm -rf "$STAGE_DIR"
	exit 1
fi

# fusion template + pkgmask conf templates + shared webroot
cp "$FUSION_DIR/module.prop" "$FUSION_DIR/service.sh" "$FUSION_DIR/uninstall.sh" "$FUSION_DIR/action.sh" "$STAGE_DIR/"
for conf in hide_packages.conf exempt_packages.conf exempt_uids.conf system_uids.conf wait_seconds.conf; do
	cp "$TEMPLATE_DIR/$conf" "$STAGE_DIR/$conf"
done
cp -R "$TEMPLATE_DIR/webroot" "$STAGE_DIR/webroot"

# binaries from the user's previous package
cp "$STAGE_DIR/_src/procguard.ko" "$STAGE_DIR/procguard.ko"
if [ -f "$STAGE_DIR/_src/scene-debugfs-watch.sh" ]; then
	cp "$STAGE_DIR/_src/scene-debugfs-watch.sh" "$STAGE_DIR/scene-debugfs-watch.sh"
	chmod 0755 "$STAGE_DIR/scene-debugfs-watch.sh"
fi
rm -rf "$STAGE_DIR/_src"

# optional pkgmask.ko from a local kernel build
if [ -n "$PKG_KO" ]; then
	cp "$PKG_KO" "$STAGE_DIR/pkgmask.ko"
fi

chmod 0755 "$STAGE_DIR/service.sh" "$STAGE_DIR/uninstall.sh" "$STAGE_DIR/action.sh"

HAVE_SCENE=no
[ -f "$STAGE_DIR/scene-debugfs-watch.sh" ] && HAVE_SCENE=yes

rm -f "$OUTPUT"
if command -v zip >/dev/null 2>&1; then
	(cd "$STAGE_DIR" && zip -q -r "$OUTPUT" .)
elif command -v python >/dev/null 2>&1; then
	(cd "$STAGE_DIR" && python -m zipfile -c "$OUTPUT" .)
else
	(cd "$STAGE_DIR" && python3 -m zipfile -c "$OUTPUT" .)
fi
rm -rf "$STAGE_DIR"

echo "Created PathMask Fusion package: $OUTPUT"
echo "  procguard.ko:           yes (from $(basename "$SRC_ZIP"))"
echo "  scene-debugfs-watch.sh: $HAVE_SCENE"
if [ -n "$PKG_KO" ]; then
	echo "  pkgmask.ko:             yes (path hiding active)"
else
	echo "  pkgmask.ko:             NO -- flash now, add the ko later + hot reload"
fi
