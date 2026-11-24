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
# Replays module-ci.sh's update.json step (load_conf and the block from the update.json mkdir to the release_files fi,
# both cut verbatim from the script by content, not line numbers)
# plus its commit, in a scratch repo, with a made-up release and fixture zip.
CI="$ROOT/.forgejo/module-ci.sh"
sed -n '/^mkdir -p "\$(dirname "\$UPDATE_JSON_PATH")"$/,/^fi$/p' "$CI" > "$W/release-step.sh"
check "module-ci.sh update.json step found (writes update.json, runs release_files, stages RELEASE_FILES)" \
    sh -c 'grep -qF "\"zipUrl\": zip_url" "$1" && grep -qx "    release_files" "$1" && grep -qF "for f in \$RELEASE_FILES; do git add -- \"\$f\"; done" "$1" && tail -n1 "$1" | grep -qx fi' sh "$W/release-step.sh"
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
            eval "$(cat "$4")"
            git commit -q -m "update.json: $VERSION (versionCode $VC)"' sh "$CI" "$ROOT/.forgejo/module-ci.conf" "$RT/Mod-v1.0-ci7.zip" "$W/release-step.sh" &&
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

# downloads fail on HTTP errors and are bounded in time
reset_root
fake_module "$M"
(export PATH="$STUBS:$PATH"; run_t 20 sh "$M/common/get_extra.sh" --download https://example.invalid/file) > "$W/ge.out" 2>&1
check "get_extra.sh --download: curl -f with --max-time" grep -qxF 'curl -f --connect-timeout 10 --max-time 30 -Ls https://example.invalid/file' "$LOG"
check "get_extra.sh wget fallback keeps its -T timeout" grep -qF 'busybox wget -T 10 ' "$ROOT/module/common/get_extra.sh"
check "cli.ts downloadFile: curl -f with --max-time 300, wget fallback with -T" \
    sh -c 'grep -qF "spawn('"'"'curl'"'"', ['"'"'-f'"'"', '"'"'--connect-timeout'"'"', '"'"'10'"'"', '"'"'--max-time'"'"', '"'"'300'"'"', '"'"'-L'"'"', '"'"'-s'"'"', '"'"'-o'"'"', destPath, url]" "$1" && grep -qF "['"'"'wget'"'"', '"'"'-T'"'"', '"'"'10'"'"'" "$1"' sh "$ROOT/webui/src/cli.ts"

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
# keybox repo: the remote site opens in the external browser, never in a frame of the root WebUI;
# the downloaded keybox is set with Keybox > Local (file selector, Download/*.xml)
check "main.ts opens the keybox repo URL with linkRedirect" grep -qF 'await cli.linkRedirect(`${KEYBOX_REPO_URL}/${i18n.lang}`)' "$SRC/main.ts"
check "main.ts has no keybox repo iframe overlay" [ "$(grep -c 'KeyboxRepo\|keybox/repo/repo' "$SRC/main.ts")" = 0 ]
check "keybox repo import hint string in en.xml (other locales fall back to en)" \
    grep -qF '<string name="prompt_keybox_repo_import_hint">' "$ROOT/webui/public/locales/strings/en.xml"
check "Keybox > Local reads a .xml file picked from Download/ into keybox.xml" sh -c '
    grep -qF "mainMenu.on('"'"'menu-keybox-local'"'"', async () => await keybox.setLocalKey())" "$1/main.ts" &&
    grep -qF "const content = await this.#fileSelector.getFileContent('"'"'xml'"'"')" "$1/keybox/keybox.ts" &&
    grep -qF "#currentPath = '"'"'/storage/emulated/0/Download'"'"'" "$1/file_selector/file_selector.ts"' sh "$SRC"
# i18n.lang (part of the repo URL) is 'en' or a languages.json key: letters and one '-' only
LANG_KEYS=$(grep -o '"[^"]*": ' "$ROOT/webui/public/locales/languages.json")
check "languages.json keys are plain language tags" \
    [ -n "$LANG_KEYS" -a "$(printf '%s\n' "$LANG_KEYS" | grep -cvE '^"[a-z]{2,3}(-[A-Z]{2})?": $')" = 0 ]
# window.open in a manager WebView without a navigation guard loads the page in that WebView, next to the
# root bridge: the am start fallbacks open a window only on the dev server
check "window.open only behind import.meta.env.DEV (cli.ts linkRedirect, bootstrap.ts)" sh -c '
    [ "$(grep -rn "window\.open(" "$1" | grep -v "keybox/repo/" | grep -cv "errno !== 0 && import\.meta\.env\.DEV) window\.open(")" = 0 ] &&
    [ "$(grep -c "errno !== 0 && import\.meta\.env\.DEV) window\.open(" "$1/cli.ts" "$1/bootstrap.ts" | grep -c ":1\$")" = 2 ]' sh "$SRC"
# remote fetches (update.json, changelog, guide, exclude list, custom keybox providers) end after 30 s instead of
# leaving a spinner or a dialog waiting forever; bundled ./locales reads and the unused locale hot-update are not network
check "every live remote fetch() has AbortSignal.timeout (9 in update.ts, app_list.ts, dialog/i18n.ts, custom.ts)" sh -c '
    cd "$1" && L=$(grep -n "await fetch(" update.ts app_list/app_list.ts dialog/i18n.ts keybox/custom.ts | grep -vF -e "fetch('"'"'./locales/" -e "fetch(url)" -e "fetch(mirrorUrl)")
    [ "$(printf "%s\n" "$L" | grep -c "AbortSignal\.timeout(30000) })")" = 9 ] && [ "$(printf "%s\n" "$L" | grep -cv "AbortSignal\.timeout(")" = 0 ]' sh "$SRC"
# target.txt entries may carry a mode suffix (pkg! / pkg?): select-from-denylist must not add a second plain line
check "app_list.ts fetchDenyList skips packages already targeted with a suffix" \
    sh -c 'grep -A6 "async fetchDenyList(): Promise<void> {" "$1" | grep -qF "if (!target.some(t => stripSuffix(t) === pkg)) this.#config.push('"'"'target'"'"', pkg)"' sh "$SRC/app_list/app_list.ts"
# Ctrl+A/D/F/S in the search box or a policy field must edit the text, not select/deselect every app
check "keybind.ts leaves Ctrl shortcuts to text fields (Escape still handled)" sh -c '
    grep -qF "const editing = e.composedPath().some(t => t instanceof HTMLTextAreaElement || (t instanceof HTMLInputElement && t.type !== '"'"'checkbox'"'"' && t.type !== '"'"'radio'"'"'))" "$1" &&
    grep -qF "if (key && !(editing && key !== '"'"'keybind-esc'"'"')) {" "$1"' sh "$SRC/keybind.ts"
# policy saves (per-app dialog, default policy dialog) report a failed config write instead of an unhandled rejection
check "policy dialogs show prompt_save_error when config.write() fails" sh -c '
    [ "$(cat "$1/app_list/app_list.ts" "$1/dialog/policy.ts" | grep -cF "this.#config.write().catch(() => this.#snackbar.show(i18n.t('"'"'prompt_save_error'"'"'), false))")" = 2 ]' sh "$SRC"
check "no un-awaited, uncaught config.write() left in webui/src" [ "$(grep -rn '^ *this\.#config\.write()$' "$SRC" | wc -l)" = 0 ]
# switching the update channel to "disable" hides an update card that is already shown (its Install would do nothing)
check "main.ts hides the update card when the channel is disabled" \
    sh -c 'grep -A3 "  if (channel === '"'"'disable'"'"') {" "$1" | grep -qF "updateCard.classList.add('"'"'hide'"'"')"' sh "$SRC/main.ts"
# policy text fields: isValid() checks them (text fields leave type unset) and marks the failing field; TEESimulator
# fields keep their case and inner spaces; an invalid form never reaches #applyProfilePolicy; dev fixtures pass the validators
PE="$SRC/app_list/policy.ts"; TEE="$SRC/conifg/teesimulator/config_teesimulator.ts"
check "policy.ts isValid() validates text fields (type unset) and marks the failing field" sh -c '
    grep -qF "if (meta.type !== undefined && meta.type !== '"'"'text'"'"') continue" "$1" &&
    grep -qF "const result = val ? (meta as TextFieldMeta).validate(val) : true" "$1" && grep -qF "field.error = true" "$1" &&
    [ "$(grep -c "if (meta.type !== '"'"'text'"'"') continue" "$1")" = 0 ]' sh "$PE"
check "policy.ts lower-cases and rewrites only fields without caseSensitive" \
    grep -qF 'if (!textMeta.caseSensitive) field.value = val' "$PE"
check "TEESimulator text fields are caseSensitive (profile name, 3 patch levels, OS version, 9 identity fields)" \
    [ "$(grep -c 'caseSensitive: true' "$TEE")" = 14 ]
check "TEESimulator profile switch applies the form only when it is valid" grep -qF 'if (form) this.#applyProfilePolicy(' "$TEE"
check "dev fixtures carry no YYYYMM05 (rejected by the ini/legacy YYYYMMDD validator)" \
    [ "$(cat "$SRC/conifg/official/config_ini.ts" "$SRC/app_list/app_list.ts" | grep -c YYYYMM05)" = 0 ]
# TEESimulator profiles: a switch saves the form into the profile shown before it (not the new one), delete removes the
# profile the dialog shows, per-app selection does not move the global profile, names are own properties only
check "policy.ts hands onSelect the value the select showed before the change" sh -c '
    grep -qF "const replacement = meta.onSelect!(field.value, this, this.#context, this.#selectValues.get(key))" "$1" &&
    [ "$(grep -c "this.#selectValues.set(key, " "$1")" = 3 ]' sh "$PE"
check "TEESimulator switch applies the form to the previously shown profile; only the global dialog moves #activeProfile" sh -c '
    grep -qF "const shown = previous !== undefined && this.#hasProfile(previous) ? previous : this.#activeProfile" "$1" &&
    grep -qF "if (form) this.#applyProfilePolicy(shown, form)" "$1" &&
    grep -B3 "^            this.#activeProfile = value$" "$1" | grep -qF "if (form) this.#applyProfilePolicy(shown, form)"' sh "$TEE"
check "TEESimulator delete removes the profile the dialog shows" sh -c '
    grep -qF "if (!this.#deleteProfile(shown)) return" "$1" && grep -qF "delete this.#teeConfig.profiles[name]" "$1"' sh "$TEE"
check "TEESimulator profile lookups use own properties (no \`in this.#teeConfig.profiles\`)" sh -c '
    [ "$(grep -c "in this\.#teeConfig\.profiles" "$1")" = 0 ] && grep -qF "return Object.hasOwn(this.#teeConfig.profiles, name)" "$1"' sh "$TEE"
# per-app dialog for a TEESimulator app without a section shows its profile's values: saving it untouched must not apply
# an empty form to the profile (write() applies a section that differs from its baseline)
check "per-app dialog shows config.perAppDefault() for an app without a section; TEESimulator returns the profile's values" sh -c '
    grep -qF "this.#policyEditor.setPolicy(hasPolicy ? section : this.#config.perAppDefault())" "$1/app_list/app_list.ts" &&
    grep -A3 "  perAppDefault(): Policy | null {" "$1/conifg/config.ts" | grep -qx "    return null" &&
    grep -A3 "  override perAppDefault(): Policy {" "$1/conifg/teesimulator/config_teesimulator.ts" | grep -qF "return this.#profileWithMeta(name)"' sh "$SRC"
check "TEESimulator write() recreates the default profile only for apps in no profile" \
    sh -c 'grep -A1 "^    if (remainingApps.size > 0) {" "$1" | grep -qF "const defaultProfile = this.#defaultProfile()"' sh "$TEE"
# a config file that exists but cannot be read or parsed is never replaced by defaults: every backend records the failure
# (missing or empty file = defaults), clears it on each read, and write() refuses while it is set
CF="$SRC/conifg"
check "config.ts: readFailed() treats missing/empty as defaults, assertWritable() refuses after a failed read" sh -c '
    grep -qF "if ((await file.read(path)).trim() === '"'"''"'"') return" "$1" &&
    grep -qF "if (!(await file.exist(path).catch(() => true))) return" "$1" &&
    grep -qF "if (this.#unreadable) throw new Error(" "$1"' sh "$CF/config.ts"
for b in official/config_ini official/config_legacy teesimulator/config_teesimulator ohmykeymint/config_ohmykeymint; do
    case $b in */config_legacy|*/config_ohmykeymint) nf=2 ;; *) nf=1 ;; esac
    check "$b: read() clears and records read failures ($nf), write() starts with assertWritable()" sh -c '
        [ "$(grep -c "^    this.clearReadFailure()$" "$1")" = 1 ] && [ "$(grep -c "await this.readFailed(this\.[A-Z_]*_FILE)" "$1")" = "$2" ] &&
        grep -A1 "^  override async write(): Promise<void> {$" "$1" | grep -qx "    this.assertWritable()"' sh "$CF/$b.ts" "$nf"
done
check "TEESimulator global delete shows and activates the first profile, as the refreshed select does" \
    grep -qF "if (context === 'global') this.#activeProfile = Object.keys(this.#teeConfig.profiles)[0]" "$TEE"
check "search_bar.ts show() pushes no second 'search' history entry while the search is open" sh -c '
    grep -A3 "^  show(): void {" "$1" | grep -qF "if (!this.#searchBar.classList.contains('"'"'hide'"'"')) {"' sh "$SRC/search_bar/search_bar.ts"
check "main_menu.ts keeps one open flag per submenu" sh -c '
    grep -A2 "fragment.querySelectorAll('"'"'.sub-menu-entry'"'"').forEach(entry => {" "$1" | grep -qx "      let menuOpen = false" &&
    [ "$(grep -c "^    let menuOpen = false$" "$1")" = 0 ]' sh "$SRC/main_menu/main_menu.ts"
# legacy security_patch.txt validators accept the values TrickyStore readers document (dashed dates, YYYY/MM/DD
# placeholders, device_default): with isValid() enforced, the digits-only checks refused saving such files
LEG="$SRC/conifg/official/config_legacy.ts"
check "config_legacy.ts patch fields use the documented security_patch.txt grammar" sh -c '
    grep -qF "const PATCH_VALUE = /^(?:prop|no|device_default|(?:\\d{4}|yyyy)-?(?:\\d{2}|mm)(?:-?(?:\\d{2}|dd))?)\$/i" "$1" &&
    [ "$(grep -c "validate: (v) => !v || PATCH_VALUE.test(v) || PATCH_VALUE_HINT," "$1")" = 3 ]' sh "$LEG"
# backend choice: a tricky_store build with versionCode >= 246 that still uses target.txt (no config.ini) keeps the
# target.txt + security_patch.txt backend; config.ini when it exists or on a fresh install without target.txt
check "conifg/index.ts picks config.ini only when it exists or target.txt does not" sh -c '
    grep -qF "case ConfigIni.support(versionCode) && await usesConfigIni():" "$1" &&
    grep -qF "if (await file.exist('"'"'/data/adb/tricky_store/config.ini'"'"').catch(() => false)) return true" "$1" &&
    grep -qF "return !(await file.exist('"'"'/data/adb/tricky_store/target.txt'"'"').catch(() => false))" "$1" &&
    grep -qF "return await createConfig(await cli.getTrickyStoreInfo())" "$1"' sh "$SRC/conifg/index.ts"
# security_patch.txt per-package blocks ([com.example.app] ...) are kept verbatim: only the lines above the first header
# are parsed as the default policy, and the file is not deleted while blocks exist
check "config_legacy.ts keeps security_patch.txt per-package blocks" sh -c '
    grep -qF "const [globalPart, packageBlocks] = splitPackageBlocks(spRaw)" "$1" &&
    grep -qF "const policy = parseSecurityPatch(globalPart)" "$1" &&
    grep -qF "if (globalPart || this.#packageBlocks) {" "$1" &&
    grep -qF "[globalPart, this.#packageBlocks].filter(Boolean).join(" "$1"' sh "$LEG"
check "config_legacy.ts patch fields allow 14 characters (device_default, YYYY-MM-DD)" [ "$(grep -c 'maxlength: 14,' "$LEG")" = 3 -a "$(grep -c 'maxlength: [68],' "$LEG")" = 0 ]
# a target-list save that did not change the default policy leaves security_patch.txt alone ("no" values and comments kept)
check "config_legacy.ts writes or deletes security_patch.txt only when the default policy changed since read()" sh -c '
    grep -qF "this.#readPolicy = JSON.stringify(data.default_policy ?? null)" "$1" &&
    grep -A1 "const policyNow = JSON.stringify(data.default_policy ?? null)" "$1" | grep -qF "if (policyNow !== this.#readPolicy) {" &&
    grep -qF "this.#readPolicy = policyNow" "$1"' sh "$LEG"
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

# --- release cleanup (module-ci.sh release): delete only a release the forge still reports as a draft.
# The publish PATCH may be applied by the forge while its reply is lost; deleting on "PUBLISHED != 1"
# alone then removes a published release. Real: log/die/jget/api/cleanup and the publish statements
# (REQ= .. PUBLISHED=1) cut from .forgejo/module-ci.sh; stubbed: curl (fake forge at https://forge.invalid).
if command -v bash >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    RW="$W"/release-cleanup; mkdir -p "$RW/bin"
    {
        echo 'set -euo pipefail'
        echo 'API=https://forge.invalid/api/v1/repos/example/mod RELEASE_ID=7 PUBLISHED=0 SRC_SHA=0123456789abcdef0123456789abcdef01234567'
        echo 'DRAFT_REQUESTED=0 TAG=v9.9-ci7 REQ={}'
        echo 'AUTH_DIR=$(mktemp -d) AUTH_H=$AUTH_DIR/header; : > "$AUTH_H"'
        sed -n '/^log() {/p; /^die() {/p; /^jget() {/,/^print(d)/p; /^api() {/,/^}/p; /^cleanup() {/,/^}/p' "$ROOT/.forgejo/module-ci.sh"
        echo 'trap cleanup EXIT'
        echo 'if [ "$1" = create ]; then RELEASE_ID=""'
        sed -n '/^DRAFT_REQUESTED=1$/,/^RELEASE_ID="\$(api POST \/releases /p' "$ROOT/.forgejo/module-ci.sh"
        echo 'elif [ "$1" = publish ]; then'
        sed -n '/^REQ="\$(python3 -I -c .import json,sys;print(json.dumps({"draft":False/,/^PUBLISHED=1$/p' "$ROOT/.forgejo/module-ci.sh"
        echo 'else die "upload failed"; fi'
    } > "$RW/rel.sh"
    # fake curl: logs "METHOD URL"; POST exits $POST_RC, PATCH $PATCH_RC; GET of the release answers draft=$DRAFT or fails (DRAFT=fail)
    cat > "$RW/bin/curl" <<EOF
#!/bin/sh
m=GET; p=; for a in "\$@"; do [ "\$p" = -X ] && m=\$a; p=\$a; u=\$a; done
echo "\$m \$u" >> "$RW/calls"
case "\$m" in
  POST) exit "\${POST_RC:-0}" ;;
  PATCH) exit "\${PATCH_RC:-0}" ;;
  GET) [ "\$DRAFT" = fail ] && exit 22; printf '{"id": 7, "draft": %s}' "\$DRAFT" ;;
esac
EOF
    chmod 755 "$RW/bin/curl"
    rel() { rel_mode=$1; shift; : > "$RW/calls"; env PATH="$RW/bin:$PATH" TMPDIR="$RW" "$@" bash "$RW/rel.sh" "$rel_mode" > "$RW/err" 2>&1; }
    if ! grep -q '^PUBLISHED=1$' "$RW/rel.sh" || ! grep -q '^cleanup() {' "$RW/rel.sh" || ! grep -q '^api() {' "$RW/rel.sh"; then
        ko "release cleanup: cleanup()/api()/publish statements not found in module-ci.sh"
    else
        rel publish PATCH_RC=28 DRAFT=false; rc=$?
        if [ "$rc" -ne 0 ] && grep -q '^PATCH ' "$RW/calls" && ! grep -q '^DELETE ' "$RW/calls"; then
            ok "release cleanup: failed PATCH, forge reports published: release kept, job fails"
        else ko "release cleanup: failed PATCH, published (rc=$rc): $(tr '\n' ';' < "$RW/calls")"; fi
        rel upload DRAFT=true; rc=$?
        if [ "$rc" -ne 0 ] && grep -qx 'DELETE https://forge.invalid/api/v1/repos/example/mod/releases/7' "$RW/calls"; then
            ok "release cleanup: failure before publish deletes the draft"
        else ko "release cleanup: draft not deleted (rc=$rc): $(tr '\n' ';' < "$RW/calls")"; fi
        rel publish PATCH_RC=28 DRAFT=fail; rc=$?
        if [ "$rc" -ne 0 ] && ! grep -q '^DELETE ' "$RW/calls" && grep -q 'release 7' "$RW/err"; then
            ok "release cleanup: unreadable state: nothing deleted, release id logged"
        else ko "release cleanup: unreadable state (rc=$rc): $(tr '\n' ';' < "$RW/calls")"; fi
        rel publish DRAFT=false; rc=$?
        if [ "$rc" -eq 0 ] && ! grep -q '^DELETE ' "$RW/calls"; then
            ok "release cleanup: good publish deletes nothing, exit 0"
        else ko "release cleanup: good publish (rc=$rc): $(tr '\n' ';' < "$RW/calls")"; fi
        rel create POST_RC=28 DRAFT=true; rc=$?
        if [ "$rc" -ne 0 ] && grep -q '^POST ' "$RW/calls" && ! grep -q '^DELETE ' "$RW/calls" \
          && grep -q 'the draft request for v9.9-ci7 failed or its reply was lost' "$RW/err" && ! grep -q 'unbound variable' "$RW/err"; then
          ok "release cleanup: failed or unanswered draft request: tag logged for a check by hand"
        else ko "release cleanup: lost draft reply (rc=$rc): $(tr '\n' ';' < "$RW/err")"; fi
    fi
else
    sk "release cleanup (no bash/python3)"
fi

# build step (module-ci.sh build): whatever the build user started is killed after the build,
# failed or not. setpriv and chown are stubs: the stub records a kill and never runs it (here the
# test user may well be the build uid, and `kill -9 -1` would end this session).
if ! command -v bash >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    sk "module-ci.sh build step (bash/git missing)"
else
    BW="$(mktemp -d "$W/case.XXXXXX")"; mkdir -p "$BW/bin"
    cat > "$BW/bin/setpriv" <<'EOF'
#!/bin/sh
case " $* " in *" kill "*) echo "kill-requested $*" >> "$SETPRIV_LOG"; exit 0 ;; esac
while [ $# -gt 0 ]; do case "$1" in --*) shift ;; *) break ;; esac; done
exec "$@"
EOF
    printf '#!/bin/sh\nexit 0\n' > "$BW/bin/chown"
    chmod 755 "$BW/bin/setpriv" "$BW/bin/chown"
    # build_step <ok|failed>: a work tree with this module-ci.sh and a conf whose build() passes or fails
    build_step() {
        _b="$BW/$1"; mkdir -p "$_b/.forgejo"
        cp "$ROOT/.forgejo/module-ci.sh" "$_b/.forgejo/"
        if [ "$1" = ok ]; then
            printf 'build() { echo zip > "$OUT/module.zip"; }\n' > "$_b/.forgejo/module-ci.conf"
        else
            printf 'build() { echo "stub build failed" >&2; return 1; }\n' > "$_b/.forgejo/module-ci.conf"
        fi
        (cd "$_b" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm t) > /dev/null 2>&1
        : > "$_b/setpriv.log"
        if [ "$(PATH="$BW/bin:$PATH" command -v setpriv)" != "$BW/bin/setpriv" ]; then
            ko "build step $1: setpriv stub not first on PATH, not run"; return
        fi
        _rc=0
        (cd "$_b" && env PATH="$BW/bin:$PATH" SETPRIV_LOG="$_b/setpriv.log" SERVER_URL=https://forge.invalid \
            REPOSITORY=owner/repo BASE_SHA="$(git rev-parse HEAD)" bash .forgejo/module-ci.sh build "$_b") > "$_b/out.log" 2>&1 || _rc=$?
        if [ "$1" = ok ]; then _want=0; [ -f "$_b/.ci-out/module.zip" ] && _res=zip || _res=missing
        else _want=1; grep -q "stub build failed" "$_b/out.log" && _res=stub-failure || _res=missing; fi
        if [ "$([ "$_rc" = 0 ] && echo 0 || echo 1)" = "$_want" ] && [ "$_res" != missing ] \
            && ! grep -q "unbound variable" "$_b/out.log" && grep -q 'kill-requested .*--reuid=1000 .*kill -9 -1' "$_b/setpriv.log"; then
            ok "module-ci.sh build step $1: exit as expected, build user's processes killed"
        else
            ko "module-ci.sh build step $1 (rc=$_rc, $_res, kills: $(grep -c kill-requested "$_b/setpriv.log")): $(tail -n 2 "$_b/out.log" | tr '\n' ' ')"
        fi
    }
    build_step ok
    build_step failed
fi

# the job builds the dispatched commit even when main has moved since: the steps whose run text
# clones or calls `module-ci.sh build` run against a local bare repo whose main has a commit after
# BASE_SHA. The fixture's .forgejo/module-ci.sh is a marker script that records which commit's copy
# ran; the real pipeline is never reachable from here. Run blocks are read without PyYAML.
wf_dispatched() {
  _wf=$W/workflow
  mkdir -p "$_wf/job" "$_wf/forge/owner" "$_wf/seed/.forgejo" || return 1
  git init -q --bare "$_wf/forge/owner/repo.git" && git init -q "$_wf/seed" || return 1
  for _c in dispatched later-on-main; do
    printf '#!/bin/sh\necho "%s $*" >> "$MARKER_LOG"\n' "$_c" > "$_wf/seed/.forgejo/module-ci.sh"
    (cd "$_wf/seed" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm "$_c") || return 1
    [ "$_c" = dispatched ] && _base=$(git -C "$_wf/seed" rev-parse HEAD)
  done
  git -C "$_wf/seed" push -q "$_wf/forge/owner/repo.git" HEAD:refs/heads/main || return 1
  python3 -I - "$ROOT/.forgejo/workflows/module-release.yml" > "$_wf/steps.sh" <<'PY'
import re, sys
steps, cur = [], None
for l in open(sys.argv[1]).read().split("\n"):
    if re.match(r"^      - name:", l):
        cur = {"run": [], "in": False}; steps.append(cur); continue
    if cur is None:
        continue
    if re.match(r"^        run: \|\s*$", l):
        cur["in"] = True; continue
    m = re.match(r"^        run: (.+)$", l)
    if m:
        cur["run"].append(m.group(1)); continue
    if cur["in"]:
        if l.startswith("          ") or not l.strip():
            cur["run"].append(l[10:])
        else:
            cur["in"] = False
for st in steps:
    text = "\n".join(st["run"])
    if "git clone" in text or "module-ci.sh build" in text:
        print("(\n" + text + "\n)")
PY
  : > "$_wf/marker.log"
  (cd "$_wf/job" && env SERVER_URL="file://$_wf/forge" REPOSITORY=owner/repo BASE_SHA="$_base" \
    MARKER_LOG="$_wf/marker.log" sh "$_wf/steps.sh") > "$_wf/out.log" 2>&1 || { tail -n 2 "$_wf/out.log"; return 1; }
  [ "$(git -C "$_wf/job/src" rev-parse HEAD)" = "$_base" ] && [ "$(cat "$_wf/marker.log")" = "dispatched build src" ] \
    || { echo "     ran: $(tr '\n' ';' < "$_wf/marker.log")"; return 1; }
}
if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  check "workflow: checkout and build use the dispatched commit after main moved" wf_dispatched
else
  sk "workflow dispatched-commit check (needs python3 and git)"
fi

echo "passed $pass failed $fail skipped $skip"
[ "$fail" = 0 ]
