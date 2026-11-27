#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
project=$(pwd -P)
if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
    printf '%s\n' 'Use an arm64 macOS runner with the Xcode 26 SDK.' >&2
    exit 1
fi
xcodebuild -version
xcrun --sdk macosx --show-sdk-version

/usr/bin/python3 -B "$project/Scripts/setup-workspace-leases.py"
lease_dir=$(dirname -- "$project")/合并迁移-2026-11-02
lease="$lease_dir/build_lease.py"
export GAO_BUILD_LEASE_OWNER="macos-verification-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$"
receipt=$(/usr/bin/python3 -B "$lease" acquire --owner "$GAO_BUILD_LEASE_OWNER" --purpose 'Compile macOS components and test synthetic workflows')
GAO_BUILD_LEASE_TOKEN=$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' <<< "$receipt")
export GAO_BUILD_LEASE_TOKEN
trap '/usr/bin/python3 -B "$lease" release >/dev/null' EXIT

/bin/zsh "$project/Scripts/build.sh" --compile-only
/bin/zsh "$project/Scripts/test.sh" --swift-only --build18-targeted
