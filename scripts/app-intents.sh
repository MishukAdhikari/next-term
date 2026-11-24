#!/bin/bash
# Writes Metadata.appintents into an app's Contents/Resources, so macOS lists Next Term's Spotlight and Shortcuts
# actions (Sources/NextTerm/LauncherIntents.swift). Xcode makes this file in a build phase that `swift build` lacks:
# here the compiler gives the file's constant values, and Xcode's appintentsmetadataprocessor turns them into metadata.
#
#   scripts/app-intents.sh "dist/Next Term.app/Contents/Resources"
#
# Without Xcode (only the Command Line Tools) it says so and writes nothing: the app works the same, without the
# actions. REQUIRE_APP_INTENTS=1 (CI's release build) makes that an error instead.
set -euo pipefail
cd "$(dirname "$0")/.."

RESOURCES="${1:?usage: scripts/app-intents.sh <app>/Contents/Resources}"
SOURCE="Sources/NextTerm/LauncherIntents.swift"
MODULE="NextTerm" # the app's module: the metadata names the intents by their types in it
DEPLOYMENT="13.0"
TRIPLE="arm64-apple-macos$DEPLOYMENT"

if ! PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null)"; then
  if [[ "${REQUIRE_APP_INTENTS:-0}" == 1 ]]; then
    echo "error: appintentsmetadataprocessor not found (it comes with Xcode)" >&2
    exit 1
  fi
  echo "==> No Xcode: the app gets no Spotlight and Shortcuts actions (Metadata.appintents)"
  exit 0
fi

echo "==> Spotlight and Shortcuts actions (Metadata.appintents)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# The protocols whose conformers' constant values the processor reads, as Xcode lists them.
cat > "$WORK/protocols.json" <<'JSON'
["AppIntent", "EntityQuery", "AppEntity", "TransientEntity", "AppEnum", "AppShortcutProviding", "AppShortcutsProvider",
 "AnyResolverProviding", "AppIntentsPackage", "DynamicOptionsProvider", "_IntentValueRepresentable",
 "_AssistantIntentsProvider", "_GenerativeFunctionExtractable", "IntentValueQuery", "Resolver"]
JSON

xcrun swiftc -parse-as-library -c -sdk "$SDK" -target "$TRIPLE" -module-name "$MODULE" "$SOURCE" \
  -emit-const-values-path "$WORK/LauncherIntents.swiftconstvalues" \
  -Xfrontend -const-gather-protocols-file -Xfrontend "$WORK/protocols.json" \
  -o "$WORK/LauncherIntents.o"

echo "$PWD/$SOURCE" > "$WORK/sources.txt"
echo "$WORK/LauncherIntents.swiftconstvalues" > "$WORK/constvalues.txt"
: > "$WORK/metadata.txt"
: > "$WORK/static-metadata.txt"

mkdir -p "$RESOURCES"
"$PROCESSOR" \
  --output "$RESOURCES" \
  --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --module-name "$MODULE" \
  --sdk-root "$SDK" \
  --xcode-version "$(xcodebuild -version | sed -n 's/^Build version //p')" \
  --platform-family macOS \
  --deployment-target "$DEPLOYMENT" \
  --target-triple "$TRIPLE" \
  --source-file-list "$WORK/sources.txt" \
  --swift-const-vals-list "$WORK/constvalues.txt" \
  --metadata-file-list "$WORK/metadata.txt" \
  --static-metadata-file-list "$WORK/static-metadata.txt" \
  --deployment-aware-processing --no-app-shortcuts-localization --force 2>&1 \
  | grep -v "^$" || true

ACTIONS="$RESOURCES/Metadata.appintents/extract.actionsdata"
if [[ ! -s "$ACTIONS" ]]; then
  echo "error: no $ACTIONS was written" >&2
  exit 1
fi
for INTENT in GoToWaitingAgentIntent GoToAnythingIntent OpenProjectIntent StartAgentIntent; do
  grep -q "$INTENT" "$ACTIONS" || { echo "error: $INTENT is missing from $ACTIONS" >&2; exit 1; }
done
echo "    $(ls "$RESOURCES/Metadata.appintents" | tr '\n' ' ')"
