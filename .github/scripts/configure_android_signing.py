#!/usr/bin/env python3
"""Configure Android release signing from the owner's GitHub Secrets.

When the secrets are absent the build stays debug-signed and a warning is
printed. Keystores and passwords are only written to the CI runner (both are
git-ignored) and are never committed.
"""
import base64
import os
import sys
from pathlib import Path

names = ["ANDROID_KEYSTORE_BASE64", "ANDROID_KEYSTORE_PASSWORD", "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD"]
values = {name: os.environ.get(name, "") for name in names}
if not all(values.values()):
    if any(values.values()):
        print("::error::Android signing secrets are incomplete; set all of " + ", ".join(names))
        sys.exit(1)
    print("::warning::Android signing secrets not set: APK is signed with the runner's debug key "
          "and may not install over a previously installed build.")
    sys.exit(0)

app = Path("android/app")
(app / "upload-keystore.jks").write_bytes(base64.b64decode(values["ANDROID_KEYSTORE_BASE64"]))
Path("android/key.properties").write_text(
    "storeFile=upload-keystore.jks\n"
    f"storePassword={values['ANDROID_KEYSTORE_PASSWORD']}\n"
    f"keyAlias={values['ANDROID_KEY_ALIAS']}\n"
    f"keyPassword={values['ANDROID_KEY_PASSWORD']}\n")

gradle = app / "build.gradle.kts"
text = gradle.read_text()
debug_line = 'signingConfig = signingConfigs.getByName("debug")'
if text.count(debug_line) != 1 or "\nandroid {\n" not in text:
    print("::error::Generated build.gradle.kts layout not recognised; signing not configured")
    sys.exit(1)
config = '''android {
    val keystoreProperties = java.util.Properties().apply {
        java.io.FileInputStream(rootProject.file("key.properties")).use { load(it) }
    }
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }
'''
text = text.replace("\nandroid {\n", "\n" + config, 1)
text = text.replace(debug_line, 'signingConfig = signingConfigs.getByName("release")', 1)
gradle.write_text(text)
print("Android release signing configured from GitHub Secrets.")
