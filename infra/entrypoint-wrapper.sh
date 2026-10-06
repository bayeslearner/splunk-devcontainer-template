#!/bin/bash
# entrypoint-wrapper.sh — Wraps the official Splunk entrypoint to skip
# Ansible re-provisioning on subsequent starts. On first run (or when
# FORCE_PROVISION=true), delegates to the stock entrypoint. On later
# starts, starts splunkd directly (~15s vs 60-120s).
#
# Marker file: /opt/splunk/var/.provisioned (persists in splunk-var volume)

set -e

MARKER_FILE="/opt/splunk/var/.provisioned"
STOCK_ENTRYPOINT="/sbin/entrypoint.sh"
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"

# ── Graceful shutdown ────────────────────────────────────────────────
teardown() {
    echo "entrypoint-wrapper: caught signal, stopping splunkd..."
    if [ "$(whoami)" != "${SPLUNK_USER}" ]; then
        sudo -u "${SPLUNK_USER}" bash -c "export SPLUNK_HOME=${SPLUNK_HOME}; ${SPLUNK_HOME}/bin/splunk stop" 2>/dev/null || true
    else
        "${SPLUNK_HOME}/bin/splunk" stop 2>/dev/null || true
    fi
    exit 0
}
trap teardown SIGINT SIGTERM

# ── Auto-discover baked-in apps (/tmp/apps/*.tgz) ──────────────────
# Appends any .tgz files to SPLUNK_APPS_URL so Ansible installs them
# on first provision. Works for both dev (stage/ bind-mount) and
# staging (COPY'd into image). No-op if /tmp/apps/ is empty.
discover_apps() {
    local apps_dir="/tmp/apps"
    [ -d "${apps_dir}" ] || return
    local apps_list=""
    for tgz in "${apps_dir}"/*.tgz; do
        [ -f "$tgz" ] || continue
        if [ -n "$apps_list" ]; then
            apps_list="${apps_list},${tgz}"
        else
            apps_list="${tgz}"
        fi
    done
    if [ -n "$apps_list" ]; then
        export SPLUNK_APPS_URL="${SPLUNK_APPS_URL:+${SPLUNK_APPS_URL},}${apps_list}"
        echo "entrypoint-wrapper: SPLUNK_APPS_URL=${SPLUNK_APPS_URL}"
    fi
}

discover_apps

# ── Decide: provision or skip ────────────────────────────────────────
should_skip_provision() {
    # Only skip for start/start-service commands (the default CMD)
    case "${1:-start-service}" in
        start|start-service) ;;
        *) return 1 ;;  # non-start commands always go to stock entrypoint
    esac

    # Force provision if requested
    if [ "${FORCE_PROVISION}" = "true" ]; then
        echo "entrypoint-wrapper: FORCE_PROVISION=true — running full provisioning"
        return 1
    fi

    # Skip only if marker exists AND Splunk was actually provisioned
    # (splunk-launch.conf is created by Ansible; if missing, container was
    # recreated with a fresh filesystem but the volume retained the marker)
    if [ -f "${MARKER_FILE}" ] && [ -f "${SPLUNK_HOME}/etc/splunk-launch.conf" ]; then
        return 0
    fi

    # Stale marker — remove it so we don't keep checking
    if [ -f "${MARKER_FILE}" ] && [ ! -f "${SPLUNK_HOME}/etc/splunk-launch.conf" ]; then
        echo "entrypoint-wrapper: stale marker (container recreated) — will re-provision"
        rm -f "${MARKER_FILE}" 2>/dev/null || true
    fi

    return 1
}

# ── Skip-provision path: start splunkd directly ──────────────────────
start_without_provision() {
    echo "entrypoint-wrapper: marker found — skipping Ansible provisioning"
    echo "entrypoint-wrapper: starting splunkd directly..."

    # Start splunkd (run as splunk user if we're not already)
    # Note: sudo env_reset strips env vars and su is not available in the
    # minimal Splunk image, so we pass SPLUNK_HOME inline via bash -c.
    if [ "$(whoami)" != "${SPLUNK_USER}" ]; then
        sudo -u "${SPLUNK_USER}" bash -c "export SPLUNK_HOME=${SPLUNK_HOME}; ${SPLUNK_HOME}/bin/splunk start --accept-license --answer-yes --no-prompt"
    else
        "${SPLUNK_HOME}/bin/splunk" start --accept-license --answer-yes --no-prompt
    fi

    # Write container state so Docker healthcheck (/sbin/checkstate.sh) passes
    STATE_DIR="${CONTAINER_ARTIFACT_DIR:-/opt/container_artifact}"
    mkdir -p "${STATE_DIR}" 2>/dev/null || true
    echo "started" > "${STATE_DIR}/splunk-container.state" 2>/dev/null || true

    echo "entrypoint-wrapper: splunkd started, tailing stderr log"

    # Tail the log (same behavior as stock entrypoint's watch_for_failure)
    TAIL_FILE="${SPLUNK_TAIL_FILE:-${SPLUNK_HOME}/var/log/splunk/splunkd_stderr.log}"
    if [ "$(whoami)" != "${SPLUNK_USER}" ]; then
        sudo -u "${SPLUNK_USER}" tail -n 0 -F "${TAIL_FILE}" &
    else
        tail -n 0 -F "${TAIL_FILE}" &
    fi
    wait
}

# ── Full provision path: delegate to stock entrypoint + write marker ─
start_with_provision() {
    echo "entrypoint-wrapper: no marker (or forced) — delegating to stock entrypoint"

    # Run the stock entrypoint in background so we can write the marker after
    # The stock entrypoint handles everything: setup, Ansible, watch_for_failure
    "${STOCK_ENTRYPOINT}" "$@" &
    STOCK_PID=$!

    # Wait for Splunk to become healthy (poll the state file)
    STATE_FILE="${CONTAINER_ARTIFACT_DIR:-/opt/container_artifact}/splunk-container.state"
    TIMEOUT=300
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        if [ -f "${STATE_FILE}" ]; then
            STATE=$(cat "${STATE_FILE}" 2>/dev/null || echo "")
            if [ "${STATE}" = "started" ]; then
                echo "entrypoint-wrapper: provisioning complete — writing marker"
                if [ "$(whoami)" != "${SPLUNK_USER}" ]; then
                    sudo -u "${SPLUNK_USER}" touch "${MARKER_FILE}"
                else
                    touch "${MARKER_FILE}"
                fi
                break
            fi
        fi
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done

    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "entrypoint-wrapper: WARNING — timed out waiting for provisioning (${TIMEOUT}s)"
        echo "entrypoint-wrapper: marker NOT written; next start will re-provision"
    fi

    # Wait for the stock entrypoint process (it tails logs indefinitely)
    wait $STOCK_PID
}

# ── Emulated CPU: skip the upgrade precheck ──────────────────────────
# On Apple Silicon the amd64 image runs under emulation with no AVX, and the
# second start on an existing etc volume runs Splunk's upgrade precheck, which
# fails on "CPU Info" and leaves the container restart-looping. The setting
# has to be in splunk-launch.conf: the compose environment does not reach
# `splunk start` under Ansible, and sudo's env_reset strips it on the direct
# path. Written only when the compose file sets the variable, and only once
# Ansible has created the file (first boot is a fresh install, no precheck).
ensure_cpu_check_skip() {
    local key="SPLUNK_SKIP_PREINSTALL_CPU_CHECKS_CORRUPTING_DATA_IF_UNSUPPORTED"
    local conf="${SPLUNK_HOME}/etc/splunk-launch.conf"
    [ "${!key:-}" = "1" ] || return 0
    [ -f "${conf}" ] || return 0
    if grep -q "^${key}=" "${conf}"; then
        return 0
    fi
    echo "entrypoint-wrapper: writing ${key}=1 to splunk-launch.conf"
    # A file without a trailing newline would glue the setting onto its last line.
    local script="[ -n \"\$(tail -c1 '${conf}')\" ] && echo >> '${conf}'; echo '${key}=1' >> '${conf}'"
    if [ "$(whoami)" != "${SPLUNK_USER}" ]; then
        sudo -u "${SPLUNK_USER}" bash -c "${script}"
    else
        bash -c "${script}"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────
CMD="${1:-start-service}"
ensure_cpu_check_skip

if should_skip_provision "$CMD"; then
    start_without_provision
else
    start_with_provision "$@"
fi
