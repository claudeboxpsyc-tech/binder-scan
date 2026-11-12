#!/usr/bin/env bash
# Builds the Binder Scan Android app: a small WebView wrapper around
# https://claudeboxpsyc-tech.github.io/binder-scan/ that runs without any browser installed.
# Run by .github/workflows/android.yml. Needs KEYSTORE_B64 and KS_PASS secrets.
set -euo pipefail

ROOT="$PWD"
P="$RUNNER_TEMP/binderscan-android"
rm -rf "$P"
mkdir -p "$P/app/src/main/java/io/github/binderscan" \
         "$P/app/src/main/res/mipmap-anydpi-v26" \
         "$P/app/src/main/res/drawable" \
         "$P/app/src/main/res/values"

echo "$KEYSTORE_B64" | base64 -d > "$RUNNER_TEMP/binderscan.p12"
export KS_PATH="$RUNNER_TEMP/binderscan.p12"

cat > "$P/settings.gradle" <<'EOF'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "BinderScan"
include ":app"
EOF

cat > "$P/build.gradle" <<'EOF'
plugins { id 'com.android.application' version '8.5.2' apply false }
EOF

cat > "$P/gradle.properties" <<'EOF'
org.gradle.jvmargs=-Xmx2g
android.useAndroidX=false
EOF

cat > "$P/app/build.gradle" <<'EOF'
plugins { id 'com.android.application' }
def run = Integer.parseInt(System.getenv("GITHUB_RUN_NUMBER") ?: "1")
android {
    namespace 'io.github.binderscan'
    compileSdk 34
    defaultConfig {
        applicationId 'io.github.binderscan.app'
        minSdk 26
        targetSdk 34
        versionCode run
        versionName "1." + run
    }
    signingConfigs {
        release {
            storeFile file(System.getenv("KS_PATH"))
            storeType "pkcs12"
            storePassword System.getenv("KS_PASS")
            keyAlias "binderscan"
            keyPassword System.getenv("KS_PASS")
        }
    }
    buildTypes {
        release { minifyEnabled false; signingConfig signingConfigs.release }
    }
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
    lint { checkReleaseBuilds false; abortOnError false }
}
EOF

cat > "$P/app/src/main/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-feature android:name="android.hardware.camera" android:required="false" />
    <application
        android:label="Binder Scan"
        android:icon="@mipmap/ic_launcher"
        android:roundIcon="@mipmap/ic_launcher"
        android:allowBackup="true"
        android:theme="@android:style/Theme.DeviceDefault.NoActionBar">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:screenOrientation="portrait"
            android:configChanges="orientation|screenSize|screenLayout|keyboardHidden|uiMode">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

cat > "$P/app/src/main/res/values/colors.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_bg">#14182B</color>
</resources>
EOF

cat > "$P/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_bg" />
    <foreground android:drawable="@drawable/ic_fg" />
</adaptive-icon>
EOF

# A card inside scanner brackets
cat > "$P/app/src/main/res/drawable/ic_fg.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:fillColor="#F2C230"
        android:pathData="M45,37h18a3,3 0 0 1 3,3v28a3,3 0 0 1 -3,3h-18a3,3 0 0 1 -3,-3v-28a3,3 0 0 1 3,-3z" />
    <path android:fillColor="#14182B" android:pathData="M46,41h16v13h-16z" />
    <path android:fillColor="#14182B" android:pathData="M46,58h16v2h-16z M46,63h11v2h-11z" />
    <path android:fillColor="#00000000" android:strokeColor="#E7E9F3" android:strokeWidth="2.5"
        android:strokeLineCap="round"
        android:pathData="M33,38v-8h8 M67,30h8v8 M75,70v8h-8 M41,78h-8v-8" />
</vector>
EOF

cat > "$P/app/src/main/java/io/github/binderscan/MainActivity.java" <<'EOF'
package io.github.binderscan;

import android.Manifest;
import android.app.Activity;
import android.content.ContentValues;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.provider.MediaStore;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

public class MainActivity extends Activity {
    static final String HOME = "https://claudeboxpsyc-tech.github.io/binder-scan/";
    static final String HOST = "claudeboxpsyc-tech.github.io";
    static final String PHOTO_DIR = Environment.DIRECTORY_PICTURES + "/BinderScan/";
    static final int REQ_CAM_LIVE = 1, REQ_CAM_PHOTO = 2, REQ_FILE = 3;

    WebView web;
    PermissionRequest pendingLive;
    ValueCallback<Uri[]> fileCb;
    WebChromeClient.FileChooserParams fileParams;
    Uri photoUri;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        cleanupPhotos();
        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#0F1220"));
        setContentView(web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setUserAgentString(s.getUserAgentString() + " BinderScanApp/1");
        web.addJavascriptInterface(new Bridge(), "BinderScanAndroid");

        // Only Binder Scan's own pages may open; everything else is blocked (no web browsing).
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                return !isAppUrl(r.getUrl());
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onPermissionRequest(final PermissionRequest req) {
                runOnUiThread(() -> {
                    boolean camera = false;
                    for (String r : req.getResources())
                        if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(r)) camera = true;
                    Uri o = req.getOrigin();
                    if (!camera || o == null || !HOST.equals(o.getHost())) { req.deny(); return; }
                    if (hasCamera()) req.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
                    else { pendingLive = req; requestPermissions(new String[]{Manifest.permission.CAMERA}, REQ_CAM_LIVE); }
                });
            }

            @Override
            public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams p) {
                if (fileCb != null) fileCb.onReceiveValue(null);
                fileCb = cb;
                fileParams = p;
                if (p.isCaptureEnabled() && Build.VERSION.SDK_INT >= 29) {
                    if (hasCamera()) openCamera();
                    else requestPermissions(new String[]{Manifest.permission.CAMERA}, REQ_CAM_PHOTO);
                } else openPicker();
                return true;
            }
        });

        if (state != null) web.restoreState(state);
        else web.loadUrl(HOME);
    }

    boolean isAppUrl(Uri u) {
        return u != null && "https".equals(u.getScheme()) && HOST.equals(u.getHost())
                && u.getPath() != null && u.getPath().startsWith("/binder-scan");
    }

    boolean hasCamera() {
        return checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED;
    }

    void openPicker() {
        boolean images = false;
        if (fileParams != null)
            for (String t : fileParams.getAcceptTypes()) if (t != null && t.startsWith("image")) images = true;
        Intent i = new Intent(Intent.ACTION_GET_CONTENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType(images ? "image/*" : "*/*");
        launch(i);
    }

    @android.annotation.TargetApi(29)
    void openCamera() {
        ContentValues cv = new ContentValues();
        cv.put(MediaStore.Images.Media.DISPLAY_NAME, "binderscan-" + System.currentTimeMillis() + ".jpg");
        cv.put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg");
        cv.put(MediaStore.Images.Media.RELATIVE_PATH, PHOTO_DIR);
        photoUri = getContentResolver().insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cv);
        Intent cam = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
        cam.putExtra(MediaStore.EXTRA_OUTPUT, photoUri);
        cam.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_READ_URI_PERMISSION);
        launch(cam);
    }

    void launch(Intent i) {
        try { startActivityForResult(i, REQ_FILE); }
        catch (Exception e) { finishChooser(null); }
    }

    void finishChooser(Uri[] result) {
        if (fileCb != null) fileCb.onReceiveValue(result);
        fileCb = null;
        fileParams = null;
    }

    // Card photos are only needed for the scan; remove the ones this app took on earlier runs.
    @android.annotation.TargetApi(29)
    void cleanupPhotos() {
        if (Build.VERSION.SDK_INT < 29) return;
        try {
            getContentResolver().delete(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    MediaStore.Images.Media.RELATIVE_PATH + "=?", new String[]{PHOTO_DIR});
        } catch (Exception ignored) { }
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        if (req != REQ_FILE) { super.onActivityResult(req, res, data); return; }
        Uri[] out = null;
        if (res == RESULT_OK) {
            if (photoUri != null) out = new Uri[]{photoUri};
            else if (data != null && data.getData() != null) out = new Uri[]{data.getData()};
        } else if (photoUri != null) {
            try { getContentResolver().delete(photoUri, null, null); } catch (Exception ignored) { }
        }
        photoUri = null;
        finishChooser(out);
    }

    @Override
    public void onRequestPermissionsResult(int req, String[] perms, int[] grants) {
        boolean ok = grants.length > 0 && grants[0] == PackageManager.PERMISSION_GRANTED;
        if (req == REQ_CAM_LIVE && pendingLive != null) {
            if (ok) pendingLive.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
            else pendingLive.deny();
            pendingLive = null;
        } else if (req == REQ_CAM_PHOTO) {
            if (ok) openCamera(); else openPicker();
        }
    }

    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) web.goBack();
        else super.onBackPressed();
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        if (web != null) web.saveState(out);
    }

    // Lets the page save a collection backup to Downloads (WebView can't download files by itself).
    class Bridge {
        @JavascriptInterface
        public boolean saveFile(String name, String text) {
            try {
                byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
                String where;
                if (Build.VERSION.SDK_INT >= 29) {
                    ContentValues cv = new ContentValues();
                    cv.put(MediaStore.Downloads.DISPLAY_NAME, name);
                    cv.put(MediaStore.Downloads.MIME_TYPE, "application/json");
                    Uri u = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv);
                    try (OutputStream os = getContentResolver().openOutputStream(u)) { os.write(bytes); }
                    where = "Downloads";
                } else {
                    File f = new File(getExternalFilesDir(null), name);
                    try (FileOutputStream os = new FileOutputStream(f)) { os.write(bytes); }
                    where = f.getParent();
                }
                final String msg = "Saved " + name + " to " + where;
                runOnUiThread(() -> Toast.makeText(MainActivity.this, msg, Toast.LENGTH_LONG).show());
                return true;
            } catch (Exception e) {
                return false;
            }
        }
    }
}
EOF

cd "$P"
gradle --no-daemon :app:assembleRelease
mkdir -p "$ROOT/dist"
cp app/build/outputs/apk/release/app-release.apk "$ROOT/dist/BinderScan.apk"
ls -l "$ROOT/dist"
