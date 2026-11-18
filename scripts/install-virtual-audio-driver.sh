#!/bin/zsh
set -euo pipefail

# Neutral public entry point. Keep the historical script name as the
# implementation target so existing automation and installers remain compatible.
ROOT="${0:A:h:h}"
exec "$ROOT/scripts/install-doubao-driver.sh" "$@"
