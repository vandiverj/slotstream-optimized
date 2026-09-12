#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile="${1:-78gb}"
case "$profile" in
  78gb) engine="$PWD" ;;
  30gb) engine="$PWD/engines/30gb" ;;
  *) echo 'Usage: scripts/build.sh [78gb|30gb]' >&2; exit 2 ;;
esac
# Package.resolved pins dependencies; never run swift package update here.
swift build --package-path "$engine" --disable-automatic-resolution --skip-update -c release --jobs 4
Tools/fetch_metallib.sh
cp Tools/lib/mlx-0.31.1.metallib "$engine/.build/release/mlx.metallib"
echo "Built $profile: $engine/.build/release/slotstream"
