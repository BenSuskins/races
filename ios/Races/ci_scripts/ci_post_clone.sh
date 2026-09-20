#!/bin/sh
# Xcode Cloud post-clone hook.
#
# Location matters: Xcode Cloud looks for ci_scripts/ in the directory containing
# the Xcode project, NOT at the repository root. Hence ios/Races/ci_scripts/.
#
# There are no secrets to inject. Both the Racing API and Betfair credentials are
# entered by the user at runtime and held in the Keychain, never in the binary,
# so this script exists only to stamp the build number and to undo the shallow
# clone that would otherwise defeat any git-derived versioning.
set -eu

REPO="${CI_PRIMARY_REPOSITORY_PATH:-}"
if [ -z "$REPO" ]; then
    echo "Not running in Xcode Cloud; nothing to do."
    exit 0
fi

cd "$REPO"

# Xcode Cloud clones shallow. Deepen so `git log` and `git describe` work if a
# build ever wants them. Not fatal if it fails.
git fetch --unshallow --quiet 2>/dev/null \
    || git fetch --deepen=200 --quiet 2>/dev/null \
    || echo "Could not deepen the clone; continuing."

if [ -n "${CI_BUILD_NUMBER:-}" ]; then
    echo "Stamping CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER}"
    cd "$REPO/ios/Races"
    # Requires VERSIONING_SYSTEM = "apple-generic" in the project build settings.
    # Without it agvtool silently does nothing, so keep that setting in place.
    xcrun agvtool new-version -all "$CI_BUILD_NUMBER"
fi

echo "Post-clone complete."
