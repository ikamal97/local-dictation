#!/bin/zsh
# Runs the test suite with only the Command Line Tools installed (no Xcode), which
# don't put Swift Testing on the default search paths.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=/Library/Developer/CommandLineTools/Library/Developer
swift test \
    -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
    -Xlinker -F -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
