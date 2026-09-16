#!/bin/bash
# Export system-visible intent metadata from the SwiftPM compiler output.
set -euo pipefail
CONFIGURATION="${1:-Release}"
OUTPUT="${2:?usage: build-app-intents.sh Debug|Release output-resources}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$ROOT" "$CONFIGURATION" "$WORK" <<'PY'
from pathlib import Path
import sys
root, configuration, work = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
values = sorted(root.glob(f'.build/out/Intermediates.noindex/Muses.build/{configuration}/Muses-p.build/Objects-normal/*/*.swiftconstvalues'))
if not values:
    raise SystemExit('App Intents compiler metadata is missing. Build with the Xcode SwiftPM backend before packaging.')
(work / 'values').write_text('\n'.join(map(str, values)) + '\n')
(work / 'sources').write_text('\n'.join(map(str, sorted((root / 'Sources/Muses').rglob('*.swift')))) + '\n')
PY
mkdir -p "$OUTPUT"
xcrun appintentsmetadataprocessor \
    --output "$OUTPUT" \
    --toolchain-dir "$(dirname "$(dirname "$(xcrun --find swiftc)")")" \
    --module-name Muses --sdk-root "$(xcrun --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
    --platform-family macOS --deployment-target 14.0 \
    --target-triple "$(uname -m)-apple-macos14.0" \
    --source-file-list "$WORK/sources" --swift-const-vals-list "$WORK/values"
test -d "$OUTPUT/Metadata.appintents"

for localization in "$ROOT"/Sources/Muses/Resources/AppIntentsLocalization/*.lproj; do
    ditto "$localization" "$OUTPUT/$(basename "$localization")"
done
