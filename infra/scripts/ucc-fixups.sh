#!/usr/bin/env bash
# Post-build fixups for a ucc-gen output directory, shared by `task ucc:build` and CI so the
# local build and the released package get the same treatment.
#
#   infra/scripts/ucc-fixups.sh <app_dir> [fragments_dir]
#
# PYTHON_REQUIRED (default 3.9) is the value written as python.required beside every
# python.version line in restmap.conf and inputs.conf; Splunk 10.2+ reads it and AppInspect
# expects it. Idempotent: a conf that already carries python.required is left alone.
set -eu
APP="${1:?ucc-gen output app directory}"
FRAGMENTS="${2:-}"
PYTHON_REQUIRED="${PYTHON_REQUIRED:-3.9}"
[ -d "${APP}" ] || { echo "ucc-fixups: no such directory: ${APP}"; exit 2; }

# Dev-time and test residue the shipped package never has.
find "${APP}" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
find "${APP}" -name ".*" -not -name ".gitkeep" -delete 2>/dev/null || true
if [ -d "${APP}/lib" ]; then
    find "${APP}/lib" -type d \( -name tests -o -name test \) -exec rm -rf {} + 2>/dev/null || true
    rm -rf "${APP}/lib/bin"
    # Pure Python only: a compiled wheel built here is for one platform, and Splunk Cloud is x86_64.
    find "${APP}/lib" -name "*.so" -delete
fi

# Custom conf fragments appended to what ucc-gen generated (package/default/ would overwrite it).
if [ -n "${FRAGMENTS}" ] && [ -d "${FRAGMENTS}" ]; then
    for frag in "${FRAGMENTS}"/*.conf; do
        [ -f "${frag}" ] || continue
        target="${APP}/default/$(basename "${frag}")"
        marker="# merged from default.d/$(basename "${frag}")"
        # ucc-gen --overwrite regenerates the output each build, but a second run of this
        # script on the same output must not append the fragment again.
        if [ -f "${target}" ] && grep -qxF "${marker}" "${target}"; then
            continue
        fi
        { echo ""; echo "${marker}"; cat "${frag}"; } >> "${target}"
        echo "ucc-fixups: merged fragment $(basename "${frag}")"
    done
fi

# python.required beside python.version. awk rather than `sed -i '/re/a text'`, which is GNU-only.
for conf in "${APP}/default/restmap.conf" "${APP}/default/inputs.conf"; do
    [ -f "${conf}" ] || continue
    if grep -q '^python\.required[[:space:]]*=' "${conf}"; then
        continue
    fi
    awk -v req="${PYTHON_REQUIRED}" '{ print } /^python\.version[[:space:]]*=/ { print "python.required = " req }' \
        "${conf}" > "${conf}.tmp" && mv "${conf}.tmp" "${conf}"
    echo "ucc-fixups: python.required = ${PYTHON_REQUIRED} in $(basename "${conf}")"
done

# local/ and local.meta are created when the dev Splunk runs the app; they fail AppInspect.
rm -rf "${APP}/local" "${APP}/metadata/local.meta"
echo "ucc-fixups: done for ${APP}"
