#!/bin/bash

echo "=== Patching Android permissions ==="

MANIFEST_FILE="android/app/src/main/AndroidManifest.xml"

if [ ! -f "$MANIFEST_FILE" ]; then
    echo "ERROR: AndroidManifest.xml not found!"
    exit 1
fi

# 1. Add all required permissions to AndroidManifest.xml
for perm in "android.permission.ACCESS_FINE_LOCATION" "android.permission.ACCESS_COARSE_LOCATION" "android.permission.CAMERA" "android.permission.READ_MEDIA_IMAGES" "android.permission.READ_EXTERNAL_STORAGE" "android.permission.READ_CONTACTS" "android.permission.WRITE_CONTACTS" "android.permission.CALL_PHONE" "android.permission.READ_PHONE_STATE"; do
    if ! grep -q "$perm" "$MANIFEST_FILE"; then
        sed -i "/<\/manifest>/i\    <uses-permission android:name=\"$perm\" />" "$MANIFEST_FILE"
        echo "Added permission: $perm"
    fi
done

# 2. Add tel intent query for phone calls
if ! grep -q "android.intent.action.DIAL" "$MANIFEST_FILE"; then
    if grep -q "<queries>" "$MANIFEST_FILE"; then
        sed -i '/<queries>/a\\        <intent>\n            <action android:name="android.intent.action.DIAL" />\n            <data android:scheme="tel" />\n        </intent>' "$MANIFEST_FILE"
    else
        sed -i '/<application/i\\    <queries>\n        <intent>\n            <action android:name="android.intent.action.DIAL" />\n            <data android:scheme="tel" />\n        </intent>\n    </queries>' "$MANIFEST_FILE"
    fi
fi

# 3. Add usesCleartextTraffic to allow HTTP URLs
if ! grep -q "usesCleartextTraffic" "$MANIFEST_FILE"; then
    sed -i 's/<application/<application android:usesCleartextTraffic="true"/' "$MANIFEST_FILE"
    echo "Added usesCleartextTraffic"
fi

# 4. Replace MainActivity with custom one that handles permissions
ACTIVITY_DIR="android/app/src/main/java/com/webtoapp/app"
# Remove old MainActivity files (could be .java or .kt)
rm -f "$ACTIVITY_DIR/MainActivity.java" "$ACTIVITY_DIR/MainActivity.kt" 2>/dev/null || true
# Also search for any other MainActivity locations
find android/app/src/main/java -name "MainActivity.*" -delete 2>/dev/null || true
mkdir -p "$ACTIVITY_DIR"
cat > "$ACTIVITY_DIR/MainActivity.java" << 'MAINACTIVITY_EOF'
package com.webtoapp.app;

import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.webkit.WebView;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {

    private static final String TAG = "WebToApp";
    private static final int PERMISSION_REQUEST_CODE = 100;
    private String[] requiredPermissions = new String[]{"android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION", "android.permission.CAMERA", "android.permission.READ_MEDIA_IMAGES", "android.permission.READ_EXTERNAL_STORAGE", "android.permission.READ_CONTACTS", "android.permission.WRITE_CONTACTS", "android.permission.CALL_PHONE", "android.permission.READ_PHONE_STATE"};
    private Handler gpsHandler = null;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.d(TAG, "MainActivity onCreate");
        new Handler(Looper.getMainLooper()).postDelayed(() -> {
            requestAllPermissions();
        }, 1500);
        new Handler(Looper.getMainLooper()).postDelayed(() -> {
            startGpsOverride();
        }, 3000);
    }

    private void startGpsOverride() {
        try {
            if (getBridge() == null) {
                Log.w(TAG, "Bridge not ready, retrying GPS override...");
                new Handler(Looper.getMainLooper()).postDelayed(() -> startGpsOverride(), 2000);
                return;
            }
            WebView webView = getBridge().getWebView();
            if (webView == null) {
                Log.w(TAG, "WebView not ready, retrying GPS override...");
                new Handler(Looper.getMainLooper()).postDelayed(() -> startGpsOverride(), 2000);
                return;
            }
            final String gpsJs = "(function(){if(navigator.geolocation){var g=navigator.geolocation;var og=g.getCurrentPosition.bind(g);var ow=g.watchPosition.bind(g);g.getCurrentPosition=function(s,e,o){o=o||{};o.enableHighAccuracy=true;return og(s,e,o)};g.watchPosition=function(s,e,o){o=o||{};o.enableHighAccuracy=true;return ow(s,e,o)}}})();";
            injectGpsOverride(webView, gpsJs);
            gpsHandler = new Handler(Looper.getMainLooper());
            gpsHandler.postDelayed(new Runnable() {
                @Override
                public void run() {
                    if (gpsHandler == null) return;
                    try {
                        WebView wv = getBridge().getWebView();
                        if (wv != null) injectGpsOverride(wv, gpsJs);
                    } catch (Exception e) {
                        Log.e(TAG, "GPS periodic inject error: " + e.getMessage());
                    }
                    if (gpsHandler != null) gpsHandler.postDelayed(this, 5000);
                }
            }, 5000);
            Log.d(TAG, "GPS high-accuracy override started");
        } catch (Exception e) {
            Log.e(TAG, "GPS override start failed: " + e.getMessage());
        }
    }

    private void injectGpsOverride(WebView webView, String js) {
        webView.evaluateJavascript(js, null);
        Log.d(TAG, "GPS override injected");
    }

    @Override
    protected void onDestroy() {
        if (gpsHandler != null) gpsHandler = null;
        super.onDestroy();
    }

    private void requestAllPermissions() {
        if (requiredPermissions == null || requiredPermissions.length == 0) return;
        java.util.List<String> needed = new java.util.ArrayList<>();
        for (String perm : requiredPermissions) {
            if (ContextCompat.checkSelfPermission(this, perm) != PackageManager.PERMISSION_GRANTED) {
                needed.add(perm);
                Log.d(TAG, "Need permission: " + perm);
            }
        }
        if (!needed.isEmpty()) {
            String[] perms = needed.toArray(new String[0]);
            Log.d(TAG, "Requesting " + perms.length + " permissions");
            ActivityCompat.requestPermissions(this, perms, PERMISSION_REQUEST_CODE);
        } else {
            Log.d(TAG, "All permissions already granted");
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        for (int i = 0; i < permissions.length; i++) {
            Log.d(TAG, "Permission " + permissions[i] + ": " + (grantResults[i] == PackageManager.PERMISSION_GRANTED ? "GRANTED" : "DENIED"));
        }
    }
}

MAINACTIVITY_EOF
echo "Custom MainActivity.java created at $ACTIVITY_DIR/MainActivity.java"
cat "$ACTIVITY_DIR/MainActivity.java" | head -5

# 4. Update app name in strings.xml
STRINGS_FILE="android/app/src/main/res/values/strings.xml"
if [ -f "$STRINGS_FILE" ]; then
    sed -i "s|<string name=\"app_name\">[^<]*<\/string>|<string name=\"app_name\">营口CRM<\/string>|" "$STRINGS_FILE"
    sed -i "s|<string name=\"title_activity_main\">[^<]*<\/string>|<string name=\"title_activity_main\">营口CRM<\/string>|" "$STRINGS_FILE"
    echo "Updated app_name to: 营口CRM"
    cat "$STRINGS_FILE"
else
    echo "WARNING: strings.xml not found"
fi

# 5. Copy custom icon to all mipmap directories
if [ -f "app-icon.png" ]; then
    echo "Custom icon detected, copying..."
    for dir in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
        mkdir -p "android/app/src/main/res/mipmap-$dir"
        cp app-icon.png "android/app/src/main/res/mipmap-$dir/ic_launcher.png"
        cp app-icon.png "android/app/src/main/res/mipmap-$dir/ic_launcher_round.png"
    done
    # Also copy to drawable for adaptive icon foreground
    for dir in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
        mkdir -p "android/app/src/main/res/drawable-$dir"
        cp app-icon.png "android/app/src/main/res/drawable-$dir/ic_launcher_foreground.png"
    done
    # Remove adaptive icon XMLs that might reference different resources
    find android/app/src/main/res -name "ic_launcher.xml" -delete 2>/dev/null || true
    find android/app/src/main/res -name "ic_launcher_round.xml" -delete 2>/dev/null || true
    find android/app/src/main/res -name "ic_launcher_background.xml" -delete 2>/dev/null || true
    echo "Icon replacement completed"
else
    echo "No custom icon, using default"
fi

echo "=== Permission patch completed! ==="
echo "Manifest permissions added: 9"
echo "Runtime permissions: 9"