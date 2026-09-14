#!/bin/sh
# install-host.sh - kept so old habits and notes still work. setup.sh does this now.
exec "$(dirname "$(readlink -f "$0")")/setup.sh" --no-extras "$@"
