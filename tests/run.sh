#!/bin/sh
# Dependency-free checks for the module scripts, the WebUI sources and the release patch.
# Usage: TMPDIR=<scratch dir> sh tests/run.sh   (POSIX sh or busybox ash)
# Checks that need python3/bash print SKIP when the tool is absent; TA_REQUIRE_TOOLS=1
# turns every SKIP into a failure.
# Module scripts run from copies whose absolute device paths (/data/adb, /storage/emulated/0)
# are rewritten into a throwaway root under TMPDIR, with stub commands first in PATH.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${TMPDIR:?set TMPDIR to a scratch directory}"
W=$(mktemp -d "$TMPDIR/ta-tests.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT TERM

pass=0 fail=0 skip=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
ko() { fail=$((fail + 1)); echo "FAIL $*"; }
sk() {
    if [ "${TA_REQUIRE_TOOLS:-0}" = 1 ]; then ko "$* (tool missing, TA_REQUIRE_TOOLS=1)"
    else skip=$((skip + 1)); echo "SKIP $*"; fi
}
have() { command -v "$1" >/dev/null 2>&1; }
check() { desc=$1; shift; if "$@"; then ok "$desc"; else ko "$desc"; fi; }

# ---------------------------------------------------------------- syntax
for f in $(cd "$ROOT" && find module lite-script_only -name '*.sh' -not -path 'module/webui/*' | sort); do
    check "sh -n $f" sh -n "$ROOT/$f"
done
if have bash; then check "bash -n .forgejo/module-ci.sh" bash -n "$ROOT/.forgejo/module-ci.sh"
else sk "bash -n .forgejo/module-ci.sh (no bash)"; fi

JSON_FILES=$(cd "$ROOT" && find . \( -name node_modules -o -name .git -o -path ./module/webui \) -prune -o -name '*.json' -print | sort)
if have python3; then
    for f in $JSON_FILES; do
        # webui/tsconfig.json is JSONC (comments), read by tsc only
        [ "$f" = ./webui/tsconfig.json ] && continue
        check "json $f" python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/$f"
    done
else
    sk "json parse (no python3)"
fi
if have python3 && python3 -I -c 'import yaml' 2>/dev/null; then
    for f in $(cd "$ROOT" && find .forgejo .github -name '*.yml' | sort); do
        check "yaml $f" python3 -I -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$ROOT/$f"
    done
else
    sk "yaml parse (no python3 yaml)"
fi

# ---------------------------------------------------------------- release patch
# .forgejo/module-ci.conf build() replaces these update.ts strings and exits when one of them
# does not occur exactly once (python str.count, newline included for the last two).
count_lit() { # literal eol(0/1) file -> occurrences
    awk -v s="$1" -v eol="$2" '{
        l = $0; off = 0
        while ((i = index(l, s)) > 0) {
            if (eol == 0 || off + i + length(s) - 1 == length($0)) n++
            off += i; l = substr(l, i + 1)
        }
    } END { print n + 0 }' "$3"
}
while IFS= read -r eol && IFS= read -r lit; do
    n=$(count_lit "$lit" "$eol" "$ROOT/webui/src/update.ts")
    check "update.ts patch string occurs once ($n): $lit" [ "$n" = 1 ]
    c=$(count_lit "$lit" 0 "$ROOT/.forgejo/module-ci.conf")
    check "module-ci.conf still patches: $lit" [ "$c" -ge 1 ]
done <<'EOF'
0
const UPDATE_JSON_URL = `${RAW_URL}/main/update.json`
0
const NIGHTLY_LINK = `https://nightly.link/${GITHUB_REPO}/workflows/build/main?preview`
1
    if (channel === 'stable') return this.#checkStableUpdate()
1
    if (channel === 'stable') return this.#performStableUpdate()
EOF
check "module-ci.conf patches exactly 4 strings" [ "$(grep -c '^    ("' "$ROOT/.forgejo/module-ci.conf")" = 4 ]

# ---------------------------------------------------------------- module scripts
STUBS="$W/bin"
mkdir -p "$STUBS"
LOG="$W/stub.log"
for c in resetprop pm am ksud apd magisk curl wget ping chcon; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$c" "$LOG" > "$STUBS/$c"
done
printf '#!/bin/sh\n[ "$1" = sys.boot_completed ] && echo 1\nexit 0\n' > "$STUBS/getprop"
printf '#!/bin/sh\necho "busybox $*" >> "%s"\nexit 0\n' "$LOG" > "$STUBS/busybox"
chmod +x "$STUBS"/*

# copy of a module script with device paths moved under $FAKE; fails when nothing was rewritten
FAKE="$W/root"
rewrite() { # src dst
    grep -q '/data/adb\|/storage/emulated/0' "$1" || { echo "rewrite: no device path in $1"; return 1; }
    sed -e "s|/data/adb|$FAKE/data/adb|g" -e "s|/storage/emulated/0|$FAKE/storage/emulated/0|g" "$1" > "$2"
}
reset_root() {
    rm -rf "$FAKE" "$LOG"
    mkdir -p "$FAKE/data/adb/modules" "$FAKE/data/adb/tricky_store" "$FAKE/storage/emulated/0"
    : > "$LOG"
}
# install-time copy of module/ (no webui build needed)
fake_module() { # dir
    rm -rf "$1"; mkdir -p "$1"
    cp -R "$ROOT/module/." "$1/" && rm -rf "$1/webui"
    for s in $(cd "$ROOT/module" && find . -name '*.sh' -not -path './webui/*'); do
        grep -q '/data/adb\|/storage/emulated/0' "$ROOT/module/$s" || continue
        rewrite "$ROOT/module/$s" "$1/$s" || return 1
    done
    ! find "$1" -name '*.sh' -exec grep -q '^[^#]*[^A-Za-z0-9_./-]/data/adb' {} \; -print | grep -q . \
        || { echo "fake_module: unrewritten device path"; return 1; }
}
run_t() { # seconds cmd...
    if have timeout; then timeout "$@"; else shift; "$@"; fi
}

# customize.sh is sourced by the root manager installer, which provides these helpers
customize() { # manager-vars...
    inst="$W/inst"; mod="$W/inst-mod"
    rm -rf "$inst"; mkdir -p "$inst"; cp "$ROOT/module/module.prop" "$inst/"
    fake_module "$mod" || return 1
    (
        PATH="$STUBS:$PATH"; TMPDIR="$inst"; MODPATH="$mod"
        ui_print() { echo "$*"; }
        abort() { echo "abort: $*"; exit 1; }
        grep_prop() { sed -n "s/^$1=//p" "$2" | head -n1; }
        set_perm() { :; }
        for v in "$@"; do eval "$v"; done
        . "$mod/customize.sh"
    ) > "$W/customize.out" 2>&1
}

reset_root
mkdir -p "$FAKE/data/adb/modules/tricky_store"
customize KSU=true KSU_VER_CODE=40000 KSU_KERNEL_VER_CODE=40000
r=$?
check "customize.sh KSU: exit 0" [ "$r" = 0 ]
check "customize.sh KSU: common/update/module.prop installed" cmp -s "$ROOT/module/module.prop" "$W/inst-mod/common/update/module.prop"

# post-fs-data.sh: manager detection, stale symlink cleanup
reset_root
M="$FAKE/data/adb/modules/TA_utl"; TS="$FAKE/data/adb/modules/tricky_store"
mkdir -p "$TS"
fake_module "$M"
ln -s "$M/webui" "$TS/webroot"
(export PATH="$STUBS:$PATH" KSU=true; run_t 20 sh "$M/post-fs-data.sh") > "$W/pfd.out" 2>&1
check "post-fs-data.sh KSU: manager.sh says KSU" grep -qx 'MANAGER=KSU' "$M/common/manager.sh"
check "post-fs-data.sh: stale TS webroot symlink removed" [ ! -L "$TS/webroot" ]
# KSU/APatch steady state (service.sh renamed action.sh): no runtime module -> flag self for removal
reset_root
fake_module "$M"
mv "$M/action.sh" "$M/action.sh.old"
(export PATH="$STUBS:$PATH" KSU=true; run_t 20 sh "$M/post-fs-data.sh") > "$W/pfd.out" 2>&1
check "post-fs-data.sh KSU without TrickyStore: module flagged for removal" [ -e "$M/remove" ]

# uninstall.sh: residue and symlinks of the module it was attached to
reset_root
M="$FAKE/data/adb/modules/TA_utl"; TS="$FAKE/data/adb/modules/tricky_store"
mkdir -p "$TS" "$FAKE/data/adb/modules/.TA_utl"
fake_module "$M"
ln -s "$M/webui" "$TS/webroot"; ln -s "$M/action.sh" "$TS/action.sh"
echo deadbeef > "$FAKE/data/adb/boot_hash"
: > "$FAKE/storage/emulated/0/stop-tspa-auto-target"
(export PATH="$STUBS:$PATH"; run_t 20 sh "$M/uninstall.sh") > "$W/un.out" 2>&1
check "uninstall.sh: TS webroot/action.sh symlinks removed" [ ! -L "$TS/webroot" -a ! -L "$TS/action.sh" ]
check "uninstall.sh: boot_hash, hidden dir, sdcard flag removed" \
    [ ! -e "$FAKE/data/adb/boot_hash" -a ! -e "$FAKE/data/adb/modules/.TA_utl" -a ! -e "$FAKE/storage/emulated/0/stop-tspa-auto-target" ]

# ---------------------------------------------------------------- WebUI sources
SRC="$ROOT/webui/src"
# no keybox.xml.bak copies (owner: no backup files on the device)
check "keybox.ts writes keybox.xml via file.write" grep -qF 'await file.write(this.keyboxPath, content)' "$SRC/keybox/keybox.ts"
check "keybox writers make no .bak copy" [ "$(cat "$SRC/keybox/keybox.ts" "$SRC/keybox/custom.ts" | grep -c '\.bak')" = 0 ]

echo "passed $pass failed $fail skipped $skip"
[ "$fail" = 0 ]
