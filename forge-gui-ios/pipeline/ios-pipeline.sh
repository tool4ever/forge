#!/bin/bash
# ios-pipeline.sh — build unmodified upstream Forge for iOS (MobiVM).
#
# MobiVM's runtime library is Java-7-era. Instead of hand-backporting modern
# Java, this pipeline transforms the built jars:
#   1. JvmDowngrader -c 52 : Java 9-17 surface -> Java 8 bytecode
#      (records, List.of, String.repeat, switch expressions, concat-indy)
#   2. MobiVmBridge (src/) : Java 8 library surface missing from MobiVM ->
#      streamsupport backports + forge.compat + app-supplied java.* classes
#      (rules in bridge.cfg; java.time = relocated ThreeTen; java.nio.file =
#      java-supply/)
#   3. MobiVmLinkAudit     : verifies every java/javax/java8/compat member
#      reference in the final jars against the real runtime — the report is
#      the complete porting workload after an upstream merge (usually empty)
#
# Usage:
#   pipeline/ios-pipeline.sh classpath   # transform jars -> tmp/ios-m2 (run
#                                        #   after every module rebuild/merge)
#   pipeline/ios-pipeline.sh sim         # build + install + launch simulator
#   pipeline/ios-pipeline.sh device      # build + sign + install to iPad
#
# Typical merge workflow:
#   git pull && mvn clean install -pl forge-core,forge-game,forge-gui,forge-gui-mobile,forge-ai -DskipTests
#   pipeline/ios-pipeline.sh classpath   # check the audit report it prints
#   pipeline/ios-pipeline.sh sim         # or: device
#
# App identity: robovm.properties is untracked (developer-specific bundle id)
# and is generated on first run from robovm.properties.template using APP_ID
# from your .env. Register your own App ID -- do not ship under someone
# else's bundle identifier.
#
# Machine/developer-specific settings (device UDIDs, signing identity) are
# NOT stored in this script. Put them in the untracked .env at the repo root
# (or export them). Example .env entries:
#
#   SIM_UDID=<simulator UDID from: xcrun simctl list devices available>
#   IPAD_UDID=<device UDID from: xcrun devicectl list devices>
#   SIGN_ID='Apple Development: Your Name (CERTID1234)'
#   PROFILE=/path/to/embedded.mobileprovision
#   TEAM_ID=YOURTEAMID
#
# Environment overrides (all may also live in .env):
#   APP_ID        bundle identifier   (default: app.id from robovm.properties)
#   APP_EXEC      executable name     (default: app.executable from robovm.properties)
#   SIM_UDID      simulator device        (required for: sim)
#   IPAD_UDID     devicectl install target (required for: device)
#   SIGN_ID       codesign identity        (required for: device)
#   PROFILE       provisioning profile     (required for: device)
#   TEAM_ID       Apple team id            (required for: device)
#   SKIP_CACHE_CLEAR=1   reuse the RoboVM AOT cache (safe: content-hashed)
#
# Working artifacts (downloaded jars, transformed output, cloned repo) live
# under tmp/ (untracked): tmp/jvmdg/ and tmp/ios-m2/. First run bootstraps
# the third-party jars from GitHub/Maven Central automatically.
set -e
# (no pipefail: `cmd | head` legitimately SIGPIPEs the left side here)

MODE="${1:-classpath}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIPE="$ROOT/forge-gui-ios/pipeline"
JV="$ROOT/tmp/jvmdg"
WORK="$JV/work"
CLONE="$ROOT/tmp/ios-m2"
M2="$HOME/.m2/repository"
SETTINGS="$ROOT/.mvn/local-settings.xml"
CP_FILE="$JV/ios-classpath.txt"

# machine/developer-specific settings live in the untracked repo-root .env
if [ -f "$ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env"
    set +a
fi

# app identity: robovm.properties (untracked) is generated from the tracked
# template using YOUR bundle identifier (APP_ID from .env / environment)
PROPS="$ROOT/forge-gui-ios/robovm.properties"
if [ ! -f "$PROPS" ]; then
    if [ -z "$APP_ID" ]; then
        echo "ERROR: $PROPS does not exist and APP_ID is not set." >&2
        echo "       Register your own bundle identifier and add APP_ID=<your.bundle.id>" >&2
        echo "       to $ROOT/.env, then re-run. See robovm.properties.template." >&2
        exit 1
    fi
    sed "s/@APP_ID@/$APP_ID/" "$ROOT/forge-gui-ios/robovm.properties.template" > "$PROPS"
    echo "generated $PROPS for $APP_ID"
fi
APP_ID="${APP_ID:-$(sed -n 's/^app\.id=//p' "$PROPS")}"
APP_EXEC="${APP_EXEC:-$(sed -n 's/^app\.executable=//p' "$PROPS")}"

require_env() {
    for v in "$@"; do
        if [ -z "${!v}" ]; then
            echo "ERROR: $v is not set. Export it or add it to $ROOT/.env" >&2
            echo "       (see the header of this script for expected entries)" >&2
            exit 1
        fi
    done
}

JVMDG_VER=1.3.6
SS_VER=1.7.4
THREETEN_VER=1.7.1
ASM_VER=9.9.1

JVMDG_JAR="$JV/jvmdowngrader-$JVMDG_VER-all.jar"
SS_JAR="$JV/streamsupport-$SS_VER.jar"
SSCF_JAR="$JV/streamsupport-cfuture-$SS_VER.jar"
THREETEN_JAR="$JV/threetenbp-$THREETEN_VER.jar"
API8_JAR="$JV/java-api-8.jar"
NIO_JAR="$JV/java-nio-supply.jar"
ASM="$M2/org/ow2/asm/asm/$ASM_VER/asm-$ASM_VER.jar"
ASMC="$M2/org/ow2/asm/asm-commons/$ASM_VER/asm-commons-$ASM_VER.jar"
TOOLS_CP="$ASM:$ASMC:$JV/tools"

RT="$M2/com/mobidevelop/robovm/robovm-rt/2.3.23/robovm-rt-2.3.23.jar"
ROBOVM_OBJC="$M2/com/mobidevelop/robovm/robovm-objc/2.3.23/robovm-objc-2.3.23.jar"
ROBOVM_CT="$M2/com/mobidevelop/robovm/robovm-cocoatouch/2.3.23/robovm-cocoatouch-2.3.23.jar"
GDXB="$M2/com/badlogicgames/gdx/gdx-backend-robovm/1.13.5/gdx-backend-robovm-1.13.5.jar"

# ---------------------------------------------------------------- bootstrap
bootstrap() {
    mkdir -p "$JV/tools"

    [ -f "$JVMDG_JAR" ] || curl -sL -o "$JVMDG_JAR" \
        "https://github.com/unimined/JvmDowngrader/releases/download/$JVMDG_VER/jvmdowngrader-$JVMDG_VER-all.jar"
    [ -f "$SS_JAR" ] || curl -sL -o "$SS_JAR" \
        "https://repo1.maven.org/maven2/net/sourceforge/streamsupport/streamsupport/$SS_VER/streamsupport-$SS_VER.jar"
    [ -f "$SSCF_JAR" ] || curl -sL -o "$SSCF_JAR" \
        "https://repo1.maven.org/maven2/net/sourceforge/streamsupport/streamsupport-cfuture/$SS_VER/streamsupport-cfuture-$SS_VER.jar"
    [ -f "$THREETEN_JAR" ] || curl -sL -o "$THREETEN_JAR" \
        "https://repo1.maven.org/maven2/org/threeten/threetenbp/$THREETEN_VER/threetenbp-$THREETEN_VER.jar"
    if [ ! -f "$ASM" ]; then
        mvn -q --settings "$SETTINGS" dependency:get -Dartifact=org.ow2.asm:asm:$ASM_VER
        mvn -q --settings "$SETTINGS" dependency:get -Dartifact=org.ow2.asm:asm-commons:$ASM_VER
    fi

    # jvmdg runtime stubs, pre-downgraded to Java 8
    [ -f "$API8_JAR" ] || java -jar "$JVMDG_JAR" -c 52 debug downgradeApi "$API8_JAR"

    # bridge/audit tools (compile when missing or sources newer)
    if [ ! -f "$JV/tools/MobiVmBridge.class" ] \
       || [ "$PIPE/src/MobiVmBridge.java" -nt "$JV/tools/MobiVmBridge.class" ] \
       || [ "$PIPE/src/MobiVmLinkAudit.java" -nt "$JV/tools/MobiVmLinkAudit.class" ]; then
        javac -cp "$ASM:$ASMC" -d "$JV/tools" "$PIPE/src/MobiVmBridge.java" "$PIPE/src/MobiVmLinkAudit.java"
    fi

    # java.nio.file + UncheckedIOException supply (java.base patch-module)
    if [ ! -f "$NIO_JAR" ] || [ -n "$(find "$PIPE/java-supply/src" -name '*.java' -newer "$NIO_JAR" 2>/dev/null | head -1)" ]; then
        rm -rf "$JV/java-supply-classes"
        mkdir -p "$JV/java-supply-classes"
        (cd "$PIPE/java-supply/src" && javac --patch-module java.base=. --release 17 \
            -d "$JV/java-supply-classes" $(find . -name "*.java"))
        (cd "$JV/java-supply-classes" && jar cf "$NIO_JAR" .)
    fi
}

# ------------------------------------------------------------- transform all
classpath() {
    echo "=== [1/8] resolve classpath + fix \${revision} poms ==="
    VERSION="$(grep -A1 '<versionCode>' "$ROOT/pom.xml" | grep -o '[0-9.]*')-SNAPSHOT"
    find "$M2/forge" -name "*.pom" -exec sed -i '' "s/\\\${revision}/$VERSION/g" {} \;
    (cd "$ROOT/forge-gui-ios" && mvn -q dependency:build-classpath \
        -Dmdep.outputFile="$CP_FILE" --settings "$SETTINGS")

    echo "=== [2/8] reset work dirs + clone maven repo (APFS CoW) ==="
    rm -rf "$WORK" "$CLONE"
    mkdir -p "$WORK/dg" "$WORK/out"
    cp -Rc "$M2" "$CLONE"

    echo "=== [3/8] partition classpath ==="
    ALL_JARS=$(tr ':' '\n' < "$CP_FILE")
    TRANSFORM=()
    KEEP=()
    while IFS= read -r j; do
        case "$j" in
            # robovm + ALL badlogicgames (libGDX) jars are MobiVM-clean by
            # construction; transforming them is unnecessary risk
            */robovm-*|*natives*|*com/badlogicgames/*) KEEP+=("$j") ;;
            *) TRANSFORM+=("$j") ;;
        esac
    done <<< "$ALL_JARS"
    echo "transform: ${#TRANSFORM[@]} jars, keep: ${#KEEP[@]} jars"
    FULL_CP=$(tr '\n' ':' <<< "$ALL_JARS" | sed 's/:$//')

    echo "=== [4/8] JvmDowngrader -c 52 on ${#TRANSFORM[@]} jars ==="
    for j in "${TRANSFORM[@]}"; do
        java -jar "$JVMDG_JAR" -q -c 52 downgrade -t "$j" "$WORK/dg/$(basename "$j")" \
            -cp "$FULL_CP" 2>&1 | grep -v "^\[" || true
    done

    echo "=== [5/8] relocate ThreeTen -> java.time supply ==="
    java -cp "$TOOLS_CP" MobiVmBridge --rules "$PIPE/relocate-time.cfg" --index "$RT" \
        --in "$THREETEN_JAR" --out "$WORK/java-time-supply.jar" | tail -1
    # duplicate TZDB.dat at the relocated path too
    (cd "$WORK" && unzip -oq java-time-supply.jar org/threeten/bp/TZDB.dat \
      && mkdir -p java/time && cp org/threeten/bp/TZDB.dat java/time/TZDB.dat \
      && jar -uf java-time-supply.jar java/time/TZDB.dat && rm -rf org java)

    echo "=== [6/8] MobiVmBridge on all downgraded jars + jvmdg api jar ==="
    DG_JARS=$(ls "$WORK"/dg/*.jar | tr '\n' ',' | sed 's/,$//')
    KEEP_CS=$(IFS=,; echo "${KEEP[*]}")
    INDEX="$RT,$ROBOVM_OBJC,$ROBOVM_CT,$SS_JAR,$SSCF_JAR,$API8_JAR,$WORK/java-time-supply.jar,$NIO_JAR,$KEEP_CS,$DG_JARS"
    BRIDGE_ARGS=()
    for j in "$WORK"/dg/*.jar; do
        BRIDGE_ARGS+=(--in "$j" --out "$WORK/out/$(basename "$j")")
    done
    BRIDGE_ARGS+=(--in "$API8_JAR" --out "$WORK/out/jvmdg-java-api-mobivm.jar")
    java -cp "$TOOLS_CP" MobiVmBridge --rules "$PIPE/bridge.cfg" --index "$INDEX" \
        "${BRIDGE_ARGS[@]}" > "$WORK/bridge-report.txt" 2>&1 || true
    head -2 "$WORK/bridge-report.txt"
    # bundle MissingStubError (lives in the CLI jar, referenced by stubs)
    (cd "$WORK" && unzip -oq "$JVMDG_JAR" 'xyz/wagyourtail/jvmdg/exc/*' \
      && jar -uf out/jvmdg-java-api-mobivm.jar xyz && rm -rf xyz)

    echo "=== [7/8] overwrite transformed jars in clone + install supplies ==="
    for j in "${TRANSFORM[@]}"; do
        cp "$WORK/out/$(basename "$j")" "$CLONE/${j#"$M2"/}"
    done
    MVN_I=(mvn -q --settings "$SETTINGS" install:install-file -Dmaven.repo.local="$CLONE" -Dpackaging=jar)
    "${MVN_I[@]}" -Dfile="$SS_JAR"   -DgroupId=net.sourceforge.streamsupport -DartifactId=streamsupport -Dversion=$SS_VER
    "${MVN_I[@]}" -Dfile="$SSCF_JAR" -DgroupId=net.sourceforge.streamsupport -DartifactId=streamsupport-cfuture -Dversion=$SS_VER
    "${MVN_I[@]}" -Dfile="$WORK/out/jvmdg-java-api-mobivm.jar" -DgroupId=xyz.wagyourtail.jvmdowngrader -DartifactId=jvmdowngrader-java-api -Dversion=$JVMDG_VER-mobivm
    "${MVN_I[@]}" -Dfile="$WORK/java-time-supply.jar" -DgroupId=forge.stubs -DartifactId=java-time-supply -Dversion=1.0
    "${MVN_I[@]}" -Dfile="$NIO_JAR" -DgroupId=forge.stubs -DartifactId=java-nio-supply -Dversion=1.0

    echo "=== [8/8] linkage audit (this report = your porting workload) ==="
    SCAN=$(ls "$WORK"/out/*.jar | tr '\n' ',' | sed 's/,$//')
    java -cp "$TOOLS_CP" MobiVmLinkAudit \
        --rt "$RT,$ROBOVM_OBJC,$ROBOVM_CT,$GDXB,$SS_JAR,$SSCF_JAR,$WORK/out/jvmdg-java-api-mobivm.jar,$WORK/java-time-supply.jar,$NIO_JAR,$KEEP_CS,$SCAN" \
        --scan "$SCAN" > "$WORK/audit-report.txt" 2>&1 || true
    head -1 "$WORK/audit-report.txt"
    echo "full reports: $WORK/bridge-report.txt  $WORK/audit-report.txt"
}

# --------------------------------------------------- compile + transform app
build_module() {
    echo "=== compile forge-gui-ios (against UNtransformed ~/.m2 jars) ==="
    # Source is written for java.util.* types; the bridge below rewrites the
    # compiled classes to match the transformed runtime classpath.
    (cd "$ROOT/forge-gui-ios" && mvn clean compile --settings "$SETTINGS" -DskipTests -q)

    echo "=== transform forge-gui-ios/target/classes (jvmdg + bridge) ==="
    cd "$ROOT/forge-gui-ios/target"
    jar cf gui-ios-raw.jar -C classes .
    java -jar "$JVMDG_JAR" -q -c 52 downgrade -t gui-ios-raw.jar gui-ios-dg.jar \
        -cp "$(tr ':' '\n' < "$CP_FILE" | tr '\n' ':')$SS_JAR:$SSCF_JAR:$NIO_JAR" 2>&1 | grep -v '^\[' || true
    DG_JARS=$(ls "$WORK"/out/*.jar | tr '\n' ',' | sed 's/,$//')
    java -cp "$TOOLS_CP" MobiVmBridge --rules "$PIPE/bridge.cfg" \
        --index "$RT,$ROBOVM_OBJC,$ROBOVM_CT,$GDXB,$SS_JAR,$SSCF_JAR,$WORK/java-time-supply.jar,$NIO_JAR,$DG_JARS,gui-ios-dg.jar" \
        --in gui-ios-dg.jar --out gui-ios-bridged.jar > "$WORK/gui-ios-bridge-report.txt" 2>&1 || true
    rm -rf classes && mkdir classes && (cd classes && jar xf ../gui-ios-bridged.jar && rm -rf META-INF)

    echo "=== audit forge-gui-ios classes ==="
    java -cp "$TOOLS_CP" MobiVmLinkAudit \
        --rt "$RT,$ROBOVM_OBJC,$ROBOVM_CT,$GDXB,$SS_JAR,$SSCF_JAR,$WORK/out/jvmdg-java-api-mobivm.jar,$WORK/java-time-supply.jar,$NIO_JAR,$DG_JARS,gui-ios-bridged.jar" \
        --scan gui-ios-bridged.jar || true
    cd "$ROOT"
}

prep_build() {
    if [ "${SKIP_CACHE_CLEAR:-0}" != "1" ]; then
        rm -rf ~/.robovm/cache
    fi
    NEWEST_TXT=$(find "$ROOT/forge-gui/res/cardsfolder" -name '*.txt' -newer "$ROOT/forge-gui/res/cardsfolder/cardsfolder.zip" 2>/dev/null | head -1)
    if [ ! -f "$ROOT/forge-gui/res/cardsfolder/cardsfolder.zip" ] || [ -n "$NEWEST_TXT" ]; then
        (cd "$ROOT/forge-gui/res/cardsfolder" && bash mkzip.sh)
    fi
    build_module
}

sim() {
    require_env SIM_UDID
    prep_build
    echo "=== robovm ipad-sim build (ignore the wrong-simulator install error) ==="
    (cd "$ROOT/forge-gui-ios" && mvn robovm:ipad-sim --settings "$SETTINGS" \
        -Dmaven.repo.local="$CLONE" -DskipTests 2>&1 | tail -8) || true
    APP="$ROOT/forge-gui-ios/target/robovm.tmp/$APP_EXEC.app"
    [ -f "$APP/$APP_EXEC" ] || { echo "APP BINARY MISSING - build failed"; exit 1; }

    echo "=== install + launch on simulator $SIM_UDID ==="
    xcrun simctl bootstatus "$SIM_UDID" -b || xcrun simctl boot "$SIM_UDID" || true
    xcrun simctl install "$SIM_UDID" "$APP"
    xcrun simctl launch "$SIM_UDID" "$APP_ID"
    echo "logs: xcrun simctl spawn $SIM_UDID log stream --predicate \"process == '$APP_EXEC'\""
}

device() {
    require_env IPAD_UDID SIGN_ID PROFILE TEAM_ID
    prep_build
    echo "=== robovm ios-device build (deploy attempt may fail: >1 iPad) ==="
    (cd "$ROOT/forge-gui-ios" && mvn robovm:ios-device --settings "$SETTINGS" \
        -Dmaven.repo.local="$CLONE" -DskipTests 2>&1 | tail -8) || true
    APP="$ROOT/forge-gui-ios/target/robovm.tmp/$APP_EXEC.app"
    [ -f "$APP/$APP_EXEC" ] || { echo "DEVICE BINARY MISSING - build failed"; exit 1; }

    echo "=== sign ==="
    cp "$PROFILE" "$APP/embedded.mobileprovision"
    cat > /tmp/forge-entitlements.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key>
    <string>${TEAM_ID}.${APP_ID}</string>
    <key>com.apple.developer.team-identifier</key>
    <string>${TEAM_ID}</string>
    <key>get-task-allow</key>
    <true/>
    <key>keychain-access-groups</key>
    <array>
        <string>${TEAM_ID}.*</string>
    </array>
</dict>
</plist>
EOF
    for framework in "$APP"/Frameworks/*.framework; do
        codesign -f -s "$SIGN_ID" "$framework"
    done
    codesign -f -s "$SIGN_ID" --entitlements /tmp/forge-entitlements.plist \
        --generate-entitlement-der "$APP"

    echo "=== install to iPad $IPAD_UDID ==="
    xcrun devicectl device install app --device "$IPAD_UDID" "$APP"
    echo "INSTALLED"
}

bootstrap
case "$MODE" in
    classpath) classpath ;;
    sim)       sim ;;
    device)    device ;;
    *) echo "usage: $0 [classpath|sim|device]"; exit 1 ;;
esac
