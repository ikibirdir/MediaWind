#!/bin/bash
# Runs the unit tests for MediaWindCore.
#
# With only the Command Line Tools installed, Swift Testing ships outside the
# compiler's default search paths, so point the compiler and linker at it.
# With full Xcode selected this falls through to a plain `swift test`.
set -euo pipefail
cd "$(dirname "$0")"

DEV_DIR="$(xcode-select -p)"
FRAMEWORKS="$DEV_DIR/Library/Developer/Frameworks"
LIBS="$DEV_DIR/Library/Developer/usr/lib"

if [ -d "$FRAMEWORKS/Testing.framework" ]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$LIBS" \
        "$@"
else
    exec swift test "$@"
fi
