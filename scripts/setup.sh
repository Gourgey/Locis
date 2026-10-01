#!/bin/bash
# One-time setup on a new Mac: creates the pipeline's Python environment.
set -euo pipefail
cd "$(dirname "$0")/../pipeline"

PYTHON="${PYTHON:-python3}"
"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11 or newer is required"'
"$PYTHON" -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet -e ".[dev]"
echo "Pipeline ready. Try: pipeline/.venv/bin/locis demo"
