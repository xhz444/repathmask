#!/usr/bin/env sh
# Package the PkgMask KernelSU module zip.
#
# Usage: sh tools/package_ksu.sh [ko_path] [output_zip]
#   ko_path   default kernel/pkgmask.ko (or set KO_PATH env)
#   output    default out/PkgMask-ksu.zip
#
# The ksu-module/ directory is the canonical template; conf files ship
# verbatim. Set UPDATE_JSON_URL=<https url> to append updateJson= to
# module.prop, or NO_UPDATE_JSON=1 to skip auto-derivation (CI default).
set -eu

KO_PATH="${1:-${KO_PATH:-kernel/pkgmask.ko}}"
OUTPUT="${2:-out/PkgMask-ksu.zip}"
UPDATE_JSON_URL="${UPDATE_JSON_URL:-}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE_DIR="$REPO_ROOT/ksu-module"
STAGE_DIR="$REPO_ROOT/out/ksu-stage"

case "$KO_PATH" in
	/*) ;;
	*) KO_PATH="$REPO_ROOT/$KO_PATH" ;;
esac

case "$OUTPUT" in
	/*) ;;
	*) OUTPUT="$REPO_ROOT/$OUTPUT" ;;
esac

if [ ! -f "$KO_PATH" ]; then
	echo "Missing kernel module: $KO_PATH" >&2
	exit 1
fi

if [ ! -d "$TEMPLATE_DIR" ]; then
	echo "Missing KernelSU template: $TEMPLATE_DIR" >&2
	exit 1
fi

if ! command -v zip >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
	echo "Missing dependency: zip or python" >&2
	exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$(dirname -- "$OUTPUT")"

cp -R "$TEMPLATE_DIR"/. "$STAGE_DIR"/
cp "$KO_PATH" "$STAGE_DIR/pkgmask.ko"

if [ -n "$UPDATE_JSON_URL" ]; then
	grep -v '^updateJson=' "$STAGE_DIR/module.prop" > "$STAGE_DIR/module.prop.tmp" || true
	mv "$STAGE_DIR/module.prop.tmp" "$STAGE_DIR/module.prop"
	printf 'updateJson=%s\n' "$UPDATE_JSON_URL" >> "$STAGE_DIR/module.prop"
fi

chmod 0755 "$STAGE_DIR/service.sh" "$STAGE_DIR/uninstall.sh" "$STAGE_DIR/action.sh"

rm -f "$OUTPUT"
if command -v zip >/dev/null 2>&1; then
	(cd "$STAGE_DIR" && zip -q -r "$OUTPUT" .)
elif command -v python >/dev/null 2>&1; then
	(cd "$STAGE_DIR" && python -m zipfile -c "$OUTPUT" .)
else
	(cd "$STAGE_DIR" && python3 -m zipfile -c "$OUTPUT" .)
fi

echo "Created KernelSU package: $OUTPUT"
echo "Kernel module:           $KO_PATH"
if [ -n "$UPDATE_JSON_URL" ]; then
	echo "Update JSON:             $UPDATE_JSON_URL"
fi
