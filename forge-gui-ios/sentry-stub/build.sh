#!/bin/bash
# Builds and installs forge.stubs:sentry-stub:1.0 — no-op io.sentry.* classes for the
# RoboVM/iOS build. The real io.sentry SDK is excluded in forge-gui-ios/pom.xml (it doesn't
# link on RoboVM), but shared Forge code calls Sentry telemetry on hot paths (e.g.
# PlayerControllerHuman.chooseEntitiesForEffect when resolving a library search). Without these
# stubs those calls throw NoClassDefFoundError: io/sentry/Sentry at runtime and silently kill the
# game thread (Cultivate / Kodama's Reach / Genesis Hydra "freeze").
#
# Signatures MUST match the real Sentry SDK (the shared .class files are precompiled against it).
# Verify against the real jar:  javap -cp ~/.m2/repository/io/sentry/sentry/8.21.1/sentry-8.21.1.jar io.sentry.Sentry
#
# Run from anywhere; re-run after editing src/ or if ~/.m2 is cleared.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
rm -rf "$DIR/classes" "$DIR/sentry-stub.jar"
mkdir -p "$DIR/classes"
javac --release 8 -d "$DIR/classes" $(find "$DIR/src" -name "*.java")
(cd "$DIR/classes" && jar cf "$DIR/sentry-stub.jar" .)
# run mvn from the repo root: the tracked .mvn/maven.config uses a cwd-relative --settings path
(cd "$ROOT" && mvn install:install-file -q \
  -Dfile="$DIR/sentry-stub.jar" \
  -DgroupId=forge.stubs -DartifactId=sentry-stub -Dversion=1.0 -Dpackaging=jar)
echo "Installed forge.stubs:sentry-stub:1.0"
