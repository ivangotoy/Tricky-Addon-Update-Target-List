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
# the build step runs upstream code (pnpm install lifecycle scripts): no signing secrets there
check "module-release.yml passes no SIGN_* secrets" [ "$(grep -c 'SIGN_' "$ROOT/.forgejo/workflows/module-release.yml")" = 0 ]
check "module-release.yml still builds via module-ci.sh build" grep -qF 'bash src/.forgejo/module-ci.sh build src' "$ROOT/.forgejo/workflows/module-release.yml"
check "module-ci.conf patches exactly 4 strings" [ "$(grep -c '^    ("' "$ROOT/.forgejo/module-ci.conf")" = 4 ]

# ---------------------------------------------------------------- release_files (zip sha256 into update.json)
# Replays module-ci.sh's update.json step (load_conf and lines 266-278, taken verbatim from the script)
# plus its commit, in a scratch repo, with a made-up release and fixture zip.
CI="$ROOT/.forgejo/module-ci.sh"
check "module-ci.sh:266-278 is still the update.json + release_files step" \
    sh -c 'sed -n 266p "$1" | grep -qF "mkdir -p \"\$(dirname \"\$UPDATE_JSON_PATH\")\"" && sed -n 277p "$1" | grep -qF "for f in \$RELEASE_FILES; do git add -- \"\$f\"; done" && sed -n 278p "$1" | grep -qx "fi"' sh "$CI"
if have bash && have python3 && have git; then
    RT="$W/release"; mkdir -p "$RT/repo"
    printf 'fixture zip bytes\n' > "$RT/Mod-v1.0-ci7.zip"
    (
        cd "$RT/repo" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
            GIT_AUTHOR_NAME=ci GIT_AUTHOR_EMAIL=ci@example.invalid GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=ci@example.invalid
        git init -q . && git commit -q --allow-empty -m init &&
        bash -c 'set -euo pipefail
            REPOSITORY=owner/repo
            eval "$(sed -n "/^load_conf() {\$/,/^}\$/p" "$1")"
            load_conf "$2"
            VERSION=v1.0-ci7 VC=123 ZIP="$3" ZIP_NAME=Mod-v1.0-ci7.zip TAG=v1.0-ci7 BUILT_VERSION=v1.0 SRC_SHA=0000000000000000000000000000000000000000
            ZIP_URL=https://forge.example.invalid/owner/repo/releases/download/v1.0-ci7/Mod-v1.0-ci7.zip
            CHANGELOG_URL=https://forge.example.invalid/owner/repo/raw/commit/0000000000000000000000000000000000000000/changelog.md
            UPDATE_URL=https://forge.example.invalid/owner/repo/raw/branch/main/.forgejo/update.json BODY=body
            ZIP_SHA="$(sha256sum "$ZIP" | cut -d" " -f1)"
            eval "$(sed -n "266,278p" "$1")"
            git commit -q -m "update.json: $VERSION (versionCode $VC)"' sh "$CI" "$ROOT/.forgejo/module-ci.conf" "$RT/Mod-v1.0-ci7.zip" &&
        git show HEAD:.forgejo/update.json
    ) > "$RT/update.json" 2> "$RT/err"
    check "release step commits a valid update.json with the 4 fields and zipSha256 of the zip" python3 -I -c '
import hashlib, json, sys
d = json.load(open(sys.argv[1]))
want = {"version": "v1.0-ci7", "versionCode": 123,
        "zipUrl": "https://forge.example.invalid/owner/repo/releases/download/v1.0-ci7/Mod-v1.0-ci7.zip",
        "changelog": "https://forge.example.invalid/owner/repo/raw/commit/0000000000000000000000000000000000000000/changelog.md",
        "zipSha256": hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()}
sys.exit(0 if d == want else "got %r" % d)' "$RT/update.json" "$RT/Mod-v1.0-ci7.zip"
else
    sk "release_files replay (needs bash, python3, git)"
fi

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
# the uninstall remnant (common/update + uninstall.sh + .default) is Magisk-only
check "customize.sh KSU: no Magisk remnant copies" [ ! -e "$W/inst-mod/common/update/uninstall.sh" -a ! -e "$W/inst-mod/common/update/common/.default" ]
customize MAGISK_VER_CODE=28000 MAGISK_VER=28.0
r=$?
check "customize.sh Magisk: exit 0" [ "$r" = 0 ]
check "customize.sh Magisk: remnant gets uninstall.sh and .default" \
    sh -c 'cmp -s "$1" "$2/uninstall.sh" && cmp -s "$3" "$2/common/.default"' sh \
    "$W/inst-mod/uninstall.sh" "$W/inst-mod/common/update" "$ROOT/module/common/.default"
check "customize.sh Magisk: no test syntax error" [ "$(grep -c 'missing' "$W/customize.out")" = 0 ]

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

# no runtime module: never delete the directory the script runs from
# KSU/APatch fresh install (action.sh not yet renamed): flag own dir for removal
reset_root
fake_module "$M"
(export PATH="$STUBS:$PATH" KSU=true; run_t 20 sh "$M/post-fs-data.sh") > "$W/pfd.out" 2>&1
check "post-fs-data.sh KSU fresh install without TrickyStore: own dir kept, flagged for removal" [ -f "$M/post-fs-data.sh" -a -e "$M/remove" ]
# Magisk running from the hidden copy: TA_utl remnant (common/update) flagged for removal
reset_root
H="$FAKE/data/adb/modules/.TA_utl"
fake_module "$H"
(export PATH="$STUBS:$PATH"; unset KSU APATCH; run_t 20 sh "$H/post-fs-data.sh") > "$W/pfd.out" 2>&1
check "post-fs-data.sh Magisk hidden copy without TrickyStore: TA_utl remnant flagged for removal" \
    [ -f "$M/service.sh" -a -e "$M/remove" -a -f "$H/post-fs-data.sh" ]
# Magisk running from TA_utl itself: flag own dir
reset_root
fake_module "$M"
(export PATH="$STUBS:$PATH"; unset KSU APATCH; run_t 20 sh "$M/post-fs-data.sh") > "$W/pfd.out" 2>&1
check "post-fs-data.sh Magisk TA_utl without TrickyStore: own dir kept, flagged for removal" [ -f "$M/post-fs-data.sh" -a -e "$M/remove" ]

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
# service.sh links webroot into TEESimulator's module too
reset_root
TEES="$FAKE/data/adb/modules/teesim"
mkdir -p "$TEES"
fake_module "$M"
ln -s "$M/webui" "$TEES/webroot"; ln -s "$M/action.sh" "$TEES/action.sh"
(export PATH="$STUBS:$PATH"; run_t 20 sh "$M/uninstall.sh") > "$W/un.out" 2>&1
check "uninstall.sh: TEESimulator webroot/action.sh symlinks removed" [ ! -L "$TEES/webroot" -a ! -L "$TEES/action.sh" ]

# action.sh (Magisk): without a WebUI app it opens the releases page, never pm-installs a downloaded APK
AB="$W/actbin"; mkdir -p "$AB"
for c in pm am curl wget busybox ping sleep; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n[ "%s" = pm ] && exit 1\nexit 0\n' "$c" "$LOG" "$c" > "$AB/$c"
done
chmod +x "$AB"/*
reset_root
mkdir -p "$FAKE/data/adb/modules/tricky_store"
fake_module "$M"
(export PATH="$AB:$PATH"; run_t 20 sh "$M/action.sh") > "$W/action.out" 2>&1
check "action.sh no WebUI app: opens the KSUWebUIStandalone releases page" \
    grep -qF 'am start -a android.intent.action.VIEW -d https://github.com/KOWX712/KsuWebUIStandalone/releases' "$LOG"
check "action.sh no WebUI app: no download, no pm install" [ "$(grep -c '^curl\|^wget\|^busybox wget\|^pm install' "$LOG")" = 0 ]

# lite script: target.txt is replaced only when pm list packages succeeded
LB="$W/litebin"; mkdir -p "$LB"
printf '#!/bin/sh\n[ "$1" = -c ] && shift\nexec "$@"\n' > "$LB/su"
printf '#!/bin/sh\n[ -n "$PM_FAIL" ] && { echo "Error: pm down" >&2; exit 1; }\n[ -n "$PM_EMPTY" ] && exit 0\nprintf "package:com.example.one\\npackage:com.miui.example\\npackage:com.example.two\\n"\n' > "$LB/pm"
chmod +x "$LB/su" "$LB/pm"
reset_root
rewrite "$ROOT/lite-script_only/UpdateTargetList.sh" "$W/lite.sh"
TT="$FAKE/data/adb/tricky_store/target.txt"
printf 'com.example.keep\n' > "$TT"
(export PATH="$LB:$PATH" PM_FAIL=1; run_t 20 sh "$W/lite.sh") > "$W/lite.out" 2>&1
check "lite script: pm failure leaves target.txt unchanged" [ "$(cat "$TT")" = com.example.keep ]
check "lite script: no temp file left after pm failure" [ ! -e "$TT.tmp" ]
(export PATH="$LB:$PATH"; run_t 20 sh "$W/lite.sh") > "$W/lite.out" 2>&1
check "lite script: target.txt = user apps minus excludes plus additions" \
    [ "$(tr '\n' ' ' < "$TT")" = "com.example.one com.example.two com.google.android.gms com.google.android.gsf com.android.vending io.github.vvb2060.keyattestation io.github.vvb2060.mahoshojo icu.nullptr.nativetest " ]
check "lite script: no temp file left" [ ! -e "$TT.tmp" ]
(export PATH="$LB:$PATH" PM_EMPTY=1; run_t 20 sh "$W/lite.sh") > "$W/lite.out" 2>&1
check "lite script: no user apps -> additions only, no blank line" [ "$(grep -c '^$' "$TT")" = 0 -a "$(wc -l < "$TT")" -eq 6 ]

# ---------------------------------------------------------------- WebUI sources
SRC="$ROOT/webui/src"
# no keybox.xml.bak copies (owner: no backup files on the device)
check "keybox.ts writes keybox.xml via file.write" grep -qF 'await file.write(this.keyboxPath, content, true)' "$SRC/keybox/keybox.ts"
check "keybox writers make no .bak copy" [ "$(cat "$SRC/keybox/keybox.ts" "$SRC/keybox/custom.ts" | grep -c '\.bak')" = 0 ]
# ShellFile.write: data must not be able to end the here-doc (a data line equal to the delimiter
# would run the following lines as root shell commands)
check "shellFile.ts picks a here-doc delimiter absent from the data" grep -qF "while (data.includes(eof)) eof += '_'" "$SRC/file/shellFile.ts"
# ShellFile.write: tmp file in the target's directory, mv onto the target only when the write succeeded
check "shellFile.ts writes a tmp file and mv's it onto the target only on success" \
    grep -qF '> "${tmp}" && mv -f "${tmp}" "${path}" || { rm -f "${tmp}"; false; }' "$SRC/file/shellFile.ts"
check "shellFile.ts tmp file sits next to the target" grep -qF 'const tmp = `${path}.tmp.${Date.now()}`' "$SRC/file/shellFile.ts"
check "shellFile.ts has no fixed FileEOF delimiter" [ "$(grep -c "<< 'FileEOF'" "$SRC/file/shellFile.ts")" = 0 ]
# KsuIo.write: the tmp file replaces the target only after write, flush and close succeeded
check "ksuIo.ts write() renames tmp onto the target" grep -qF 'tmpFile.renameTo(path)' "$SRC/file/ksuIo.ts"
check "ksuIo.ts write() renames only a complete tmp file" grep -qF 'if (complete && !tmpFile.renameTo(path))' "$SRC/file/ksuIo.ts"
# custom keybox script: the shell redirect must not truncate keybox.xml before the script ran
check "custom.ts transforms into a tmp output" grep -qF 'transformFile(input, output, script)' "$SRC/keybox/custom.ts"
check "custom.ts never redirects a script into keybox.xml" [ "$(grep -c 'transformFile([^)]*keyboxPath' "$SRC/keybox/custom.ts")" = 0 ]
# app labels are chosen by whoever ships the app: never raw HTML in the root WebUI
check "app_list.ts escapes the label in the card (alt + name) and the policy dialog" \
    [ "$(grep -c 'escapeHtml(entry.appName)' "$SRC/app_list/app_list.ts")" = 2 -a "$(grep -c 'escapeHtml(appName)' "$SRC/app_list/app_list.ts")" = 1 ]
check "app_list.ts has no raw label in HTML" [ "$(grep -c '\${entry.appName}\|`\${appName}' "$SRC/app_list/app_list.ts")" = 0 ]
# file selector: names under /storage/emulated/0 are chosen by any app with storage access
FS="$SRC/file_selector/file_selector.ts"
check "file_selector.ts single-quotes paths in exec (cd, cat)" \
    [ "$(grep -c 'cd \${shellQuote(path)}' "$FS")" = 1 -a "$(grep -c 'cat \${shellQuote(path)}' "$FS")" = 1 ]
check "file_selector.ts has no double-quoted path in exec" [ "$(grep -c '"\${path}"' "$FS")" = 0 ]
check "file_selector.ts escapes names in the list and the path bar" \
    [ "$(grep -c '<span>\${escapeHtml(item.name)}</span>' "$FS")" = 1 -a "$(grep -c 'data-path="\${escapeHtml(fullPath)}">\${escapeHtml(segment)}<' "$FS")" = 1 ]
# WebUI uninstall restores module.prop / the Magisk remnant from common/update (customize.sh, update.ts)
check "cli.ts uninstall copies from common/update (KSU/APatch, Magisk)" [ "$(grep -c '\${basePath}/common/update' "$SRC/cli.ts")" = 2 ]
check "cli.ts uninstall awaits both copies before spawning the manager" \
    [ "$(grep -c 'await file.copy(`\${basePath}/common/update' "$SRC/cli.ts")" = 2 -a "$(grep -c "if (option == 'uninstall') file.copy(" "$SRC/cli.ts")" = 0 ]
check "cli.ts has no \${basePath}/update path" [ "$(grep -c '\${basePath}/update' "$SRC/cli.ts")" = 0 ]
check "file_selector.ts escapes path segments on back navigation and on open" \
    [ "$(grep -c "filter(Boolean).map(escapeHtml).join('<span" "$FS")" = 2 -a "$(grep -c "filter(Boolean).join('<span" "$FS")" = 0 ]
# keybox data (private keys) only in files that are mode 600 before the data is written
check "file.ts write() takes ownerOnly" grep -qF 'abstract write(path: string, data: string, ownerOnly?: boolean): Promise<void>' "$SRC/file/file.ts"
check "shellFile.ts creates the tmp file under umask 077 for ownerOnly" \
    grep -qF "\${ownerOnly ? 'umask 077; ' : ''}cat << '\${eof}' > \"\${tmp}\"" "$SRC/file/shellFile.ts"
check "ksuIo.ts creates the tmp file mode 600 before writing for ownerOnly" grep -qF "umask 077 && : > '\${tmpPath}'" "$SRC/file/ksuIo.ts"
check "keybox.ts writes keybox.xml ownerOnly" grep -qF 'file.write(this.keyboxPath, content, true)' "$SRC/keybox/keybox.ts"
check "custom.ts writes the downloaded keybox input ownerOnly" grep -qF 'file.write(input, data, true)' "$SRC/keybox/custom.ts"
check "cli.ts transformFile output created under umask 077" grep -qF 'exec(`umask 077; (${command}) < ${quote(src)} > ${quote(dst)}`)' "$SRC/cli.ts"
# ksu.spawn hosts (KernelSU, KernelSU Next, WebUI X) join args into one root shell line unquoted:
# cli.ts only passes args made of characters that arrive unchanged (probe: shell metachars, globs, braces)
RE=$(sed -n 's|^const SPAWN_ARG = /\(.*\)/$|\1|p' "$SRC/cli.ts")
check "cli.ts defines SPAWN_ARG" [ -n "$RE" ]
spawn_ok() { [ -n "$RE" ] && printf '%s\n' "$1" | grep -Eq "$RE"; }
ZIPURL=$(sed -n 's/^ *"zipUrl": "\(.*\)",*$/\1/p' "$ROOT/.forgejo/update.json")
for a in "$ZIPURL" "https://gh.sevencdn.com/$ZIPURL" /data/adb/modules/.TA_utl/common/tmp/module.zip \
         /data/adb/modules/TA_utl/common/get_extra.sh TA_utl https://forge.example.invalid/owner/repo/releases/download/v1.0-ci1/Mod-v1.0-ci1.zip; do
    check "SPAWN_ARG accepts $a" spawn_ok "$a"
done
for c in '&' ';' '$' '`' "'" '"' '(' ')' '<' '>' '|' ' ' '\' '*' '?' '[' ']' '{' '}'; do
    check "SPAWN_ARG rejects [$c]" sh -c '! printf "%s\n" "$2" | grep -Eq "$1"' sh "$RE" "https://x.invalid/a${c}b"
done
check "SPAWN_ARG rejects a leading ~, # or -" sh -c '! printf "~/x\n#x\n-x\n" | grep -Eq "$1"' sh "$RE"
check "cli.ts checks spawn args in downloadFile, manageModule and getXposedList" \
    [ "$(grep -c 'assertSpawnArgs(\[' "$SRC/cli.ts")" = 3 ]
# remote markdown (changelog, translation guide) and locale strings never become live HTML in the root WebUI
check "update.ts: locale hot-update disabled (updateLocales returns false first)" \
    sh -c 'grep -qx "const LOCALES_HOT_UPDATE = false" "$1" && grep -A1 "async updateLocales(): Promise<boolean> {" "$1" | grep -qx "    if (!LOCALES_HOT_UPDATE) return false"' sh "$ROOT/webui/src/update.ts"
check "markdown.ts escapes raw HTML in marked output" grep -qF 'marked.use({ renderer: { html: ({ text }) => escapeHtml(text) } })' "$SRC/dialog/markdown.ts"
check "markdown.ts strips non-http(s) link targets" grep -qF "a.removeAttribute('href')" "$SRC/dialog/markdown.ts"
check "cli.ts linkRedirect: http(s) only, single-quoted for the shell" \
    [ "$(grep -c 'if (!/^https?:\\/\\//.test(url)) return' "$SRC/cli.ts")" = 1 -a "$(grep -cF -e '-d ${quote(url)}`' "$SRC/cli.ts")" = 1 ]
# a failed module download leaves no partial module.zip behind
check "update.ts deletes the partial module.zip when the download throws" \
    sh -c 'grep -A2 "await this.#downloadFile(url, \`\${tmpDir}/module.zip\`).catch(async (error) => {" "$1" | grep -qF "await file.delete(\`\${tmpDir}/module.zip\`).catch(() => {})"' sh "$SRC/update.ts"
# WebUI updater installs a module zip only when its sha256 equals update.json's zipSha256
UT="$SRC/update.ts"
check "update.ts passes update.json zipSha256 to the installer" grep -qF 'return this.#downloadAndInstall(data.zipUrl, data.zipSha256)' "$UT"
check "update.ts requires a 64-hex zipSha256 before downloading" grep -qF "if (!/^[0-9a-f]{64}\$/.test(expected)) throw new Error('update.json has no valid zipSha256')" "$UT"
check "update.ts hashes the fixed module.zip path and refuses a mismatch before installModule" sh -c '
    h=$(grep -n "exec(\`sha256sum '"'"'\${zip}'"'"'\`)" "$1" | cut -d: -f1 | head -n1)
    m=$(grep -n "throw new Error('"'"'module.zip sha256 mismatch'"'"')" "$1" | cut -d: -f1 | head -n1)
    i=$(grep -n "await this.#cli.installModule(zip)" "$1" | cut -d: -f1 | head -n1)
    [ -n "$h" ] && [ -n "$m" ] && [ -n "$i" ] && [ "$h" -lt "$m" ] && [ "$m" -lt "$i" ]' sh "$UT"

echo "passed $pass failed $fail skipped $skip"
[ "$fail" = 0 ]
