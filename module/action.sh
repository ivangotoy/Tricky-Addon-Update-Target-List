###########################################
## This file is NOT a part of Tricky Store
###########################################

REPO="KOWX712/KsuWebUIStandalone"

MOD_ID="TA_utl"
TS_ID="tricky_store"
OMK_ID="oh_my_keymint"
TEES_ID="teesim"

if [ -d "/data/adb/modules/$TS_ID" ] && [ ! -e "/data/adb/modules/$TS_ID/remove" ]; then
    ID=$TS_ID
elif [ -d "/data/adb/modules/$OMK_ID" ] && [ ! -e "/data/adb/modules/$OMK_ID/remove" ]; then
    ID=$OMK_ID
elif [ -d "/data/adb/modules/$TEES_ID" ] && [ ! -e "/data/adb/modules/$TEES_ID/remove" ]; then
    ID=$MOD_ID
else
    echo "! Tricky Store not found"
    exit 1
fi

manual_download() {
    echo "$1"
    sleep 3
    am start -a android.intent.action.VIEW -d "https://github.com/$REPO/releases"
    exit 1
}

# Launch KSUWebUI standalone or MMRL, open the KSUWebUI standalone releases page if both are not installed
if pm path io.github.a13e300.ksuwebui >/dev/null 2>&1; then
    echo "- Launching WebUI in KSUWebUIStandalone..."
    am start -n "io.github.a13e300.ksuwebui/.WebUIActivity" -e id "$ID"
elif pm path com.dergoogler.mmrl.wx > /dev/null 2>&1; then
    echo "- Launching WebUI in WebUI X..."
    am start -n "com.dergoogler.mmrl.wx/.ui.activity.webui.WebUIActivity" -e MOD_ID "$ID"
else
    echo "! No WebUI app found"
    manual_download "- Please download and install KSUWebUIStandalone from its releases page."
fi

echo "- WebUI launched successfully."
