#!/bin/sh

# Tricky Addon Lite: Update Target List Script v2.8
# GitHub Repository: https://github.com/KOWX712/Tricky-Addon-Update-Target-List/tree/main/lite-script_only
# Telegram channel: https://t.me/kowchannel

# This script will put all non-system app into /data/adb/tricky_store/target.txt

###################################################
# Configurable exclude and addition list
# Don't remove default package names here
###################################################

EXCLUDE="
oneplus
coloros
miui
com.android.patch
me.bmax.apatch
me.garfieldhan.apatch.next"

ADDITION="
com.google.android.gms
com.google.android.gsf
com.android.vending
io.github.vvb2060.keyattestation
io.github.vvb2060.mahoshojo
icu.nullptr.nativetest"

###################################################
# Script
###################################################

echo " "
echo "- Staring script..."
echo " "
echo "- Adding apps to target.txt..."

EXCLUDE=$(echo "$EXCLUDE" | tr '\n' '|' | sed 's/^|//;s/|$//')
ADDITION=$(echo "$ADDITION" | tr '\n' ' ' | sed 's/^ //;s/ $//')

# Add all non-system apps to the target file and remove exclusions
if ! PACKAGES=$(su -c pm list packages -3 </dev/null); then
    echo "! pm list packages failed, target.txt left unchanged"
    exit 1
fi
printf '%s' "$PACKAGES" | awk -F: '{print $2}' | grep -Ev "$EXCLUDE" > /data/adb/tricky_store/target.txt.tmp

# Add additional apps to the target file if they are not already present
for app in $ADDITION; do
    if ! grep -qx "$app" /data/adb/tricky_store/target.txt.tmp; then
        echo "$app" >> /data/adb/tricky_store/target.txt.tmp
    fi
done
mv -f /data/adb/tricky_store/target.txt.tmp /data/adb/tricky_store/target.txt

echo " "
echo "- All done!"
