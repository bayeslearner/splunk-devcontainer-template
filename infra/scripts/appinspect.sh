#!/usr/bin/env bash
# Run Splunk AppInspect on an app directory the way Cloud vetting will, and exit non-zero on
# any failure or error. Called by `task ucc:appinspect` and by CI, so there is one gate.
#
#   infra/scripts/appinspect.sh <app_dir> [extra appinspect args]
#
# Inspects a clean copy: the dev Splunk runs the output dir through a symlink and writes
# __pycache__ into it during inspection, and local/ config never ships. Tags: cloud,
# private_app and aarch64_compatibility; the cloud set alone does not include the ARM
# binary check, and Splunk Cloud runs x86_64 while this template builds on Apple Silicon.
set -u
APP_DIR="${1:?app directory}"; shift || true
[ -d "${APP_DIR}" ] || { echo "appinspect: no such directory: ${APP_DIR}"; exit 2; }
APPINSPECT="${APPINSPECT_BIN:-splunk-appinspect}"
# libmagic on macOS (harmless elsewhere)
export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:-/opt/homebrew/lib}"

WORK=$(mktemp -d); trap 'rm -rf "${WORK}"' EXIT
COPY="${WORK}/$(basename "${APP_DIR}")"
mkdir -p "${COPY}"
rsync -a --exclude '__pycache__/' --exclude '*.pyc' --exclude '.git/' \
      --exclude 'bin/lib/site-packages/' --exclude 'local/' --exclude 'metadata/local.meta' \
      "${APP_DIR}/" "${COPY}/"
mkdir -p "${COPY}/bin/lib/site-packages"

REPORT="${WORK}/report.txt"
echo "appinspect: ${APPINSPECT} on ${COPY} (cloud, private_app, aarch64_compatibility)"
"${APPINSPECT}" inspect "${COPY}" --mode precert \
    --included-tags cloud --included-tags private_app --included-tags aarch64_compatibility "$@" \
    2>&1 | tee "${REPORT}"
# A missing or crashed binary leaves no summary; counting zero failures in an empty report
# is a false green, so the summary line is required.
if ! grep -q 'Total:' "${REPORT}"; then
    echo "appinspect: no report produced (binary missing or crashed): FAILING"
    exit 1
fi
count() { grep -E "^ *$1: *[0-9]+" "${REPORT}" | tail -1 | grep -oE '[0-9]+$'; }
FAILURES=$(count failure); ERRORS=$(count error)
echo "appinspect: failures=${FAILURES:-?} errors=${ERRORS:-?}"
if [ "${FAILURES:-1}" -gt 0 ] || [ "${ERRORS:-1}" -gt 0 ]; then
    grep -B1 -A3 -E 'FAILURE:|^ERROR:' "${REPORT}" || true
    exit 1
fi
echo "appinspect: passed"
