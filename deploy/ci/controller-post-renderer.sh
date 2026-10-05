#!/bin/sh
# The pinned chart does not expose Deployment strategy; never silently ignore values.
set -eu
test "$#" -eq 2
ci_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
umask 077
ci_render=$(mktemp)
trap 'rm -f "$ci_render"' EXIT HUP INT TERM
kubectl create --dry-run=client --validate=false -f - -o json > "$ci_render"
python3 "$ci_dir/render_controller.py" "$1" "$2" < "$ci_render"
