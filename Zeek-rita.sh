#!/usr/bin/env bash
#
# deploy-zeek-rita.sh
# Deploy an Active Countermeasures network-monitoring sensor:
#   docker-zeek (capture) + RITA v5 (C2/beacon analysis) + optional Wazuh
#   agent forwarding. Tested on Debian 13 (Trixie); should work on any
#   Debian/Ubuntu with Docker.
#
# Design notes (learned the hard way, encoded so you don't repeat them):
#   * The docker-zeek wrapper is a COMPILED BINARY release asset
#     (zeek-linux-<arch>.tar.gz), NOT the legacy master shell script. The
#     image enforces a wrapper/image version match; the wrapper pulls its
#     own matching image so they cannot drift.
#   * Versions are resolved from the GitHub API at runtime (latest), or
#     pinned via --zeek-tag / --rita-tag for change control. Asset names are
#     read from the API, never guessed.
#   * Zeek workers CANNOT bind to a link-down capture NIC; they crash-loop.
#     The script refuses to start Zeek until the NIC has carrier (override
#     with --force-start).
#   * RITA v5.1.1+ no longer modifies the host distro or forces reboots, so
#     it installs cleanly on Debian despite the docs listing Ubuntu/RHEL.
#
# Usage:
#   sudo ./deploy-zeek-rita.sh --iface eno1 [options]
#
# Style: LF line endings, documented flags only, no forced reboots.
#
set -uo pipefail   # NOTE: no -e; stages handle their own errors and report,
                   # so one failing stage cannot silently kill the rest.

# ==========================================================================
# Defaults (override via flags or environment)
# ==========================================================================
CAPTURE_IF="${CAPTURE_IF:-}"                 # required: SPAN/mirror NIC
ZEEK_TOP_DIR="${ZEEK_TOP_DIR:-/opt/zeek}"
WAZUH_MANAGER="${WAZUH_MANAGER:-__SET_ME__}" # set to enable Wazuh forwarding
WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP:-zeek}"
RITA_DATASET="${RITA_DATASET:-rolling}"
PIN_ZEEK_TAG="${PIN_ZEEK_TAG:-}"             # e.g. v8.0.6 (empty = latest)
PIN_RITA_TAG="${PIN_RITA_TAG:-}"             # e.g. v5.1.2 (empty = latest)
INSTALL_RITA=1
INSTALL_WAZUH=1
FORCE_START=0
CRON_MINUTE="${CRON_MINUTE:-5}"

ZEEK_LOG_CURRENT="${ZEEK_TOP_DIR}/logs/current"

usage() {
    cat <<USAGE
Deploy a Zeek + RITA network monitoring sensor.

Required:
  --iface NAME           Capture interface (SPAN/mirror port NIC, e.g. eno1)

Options:
  --wazuh-manager HOST   Wazuh manager IP/hostname (enables agent forwarding)
  --wazuh-group NAME     Wazuh agent group           (default: ${WAZUH_AGENT_GROUP})
  --zeek-top DIR         Zeek host top dir            (default: ${ZEEK_TOP_DIR})
  --dataset NAME         RITA rolling dataset name    (default: ${RITA_DATASET})
  --zeek-tag TAG         Pin docker-zeek version      (default: latest)
  --rita-tag TAG         Pin RITA version             (default: latest)
  --cron-minute N        Minute for hourly import     (default: ${CRON_MINUTE})
  --no-rita              Skip RITA install
  --no-wazuh             Skip Wazuh agent install
  --force-start          Start Zeek even if the NIC has no carrier
  -h, --help             Show this help

Environment variables mirror the flags (CAPTURE_IF, WAZUH_MANAGER, etc.).
USAGE
}

# ==========================================================================
# Arg parsing
# ==========================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iface)          CAPTURE_IF="$2"; shift 2 ;;
        --wazuh-manager)  WAZUH_MANAGER="$2"; shift 2 ;;
        --wazuh-group)    WAZUH_AGENT_GROUP="$2"; shift 2 ;;
        --zeek-top)       ZEEK_TOP_DIR="$2"; ZEEK_LOG_CURRENT="${ZEEK_TOP_DIR}/logs/current"; shift 2 ;;
        --dataset)        RITA_DATASET="$2"; shift 2 ;;
        --zeek-tag)       PIN_ZEEK_TAG="$2"; shift 2 ;;
        --rita-tag)       PIN_RITA_TAG="$2"; shift 2 ;;
        --cron-minute)    CRON_MINUTE="$2"; shift 2 ;;
        --no-rita)        INSTALL_RITA=0; shift ;;
        --no-wazuh)       INSTALL_WAZUH=0; shift ;;
        --force-start)    FORCE_START=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# ==========================================================================
# Helpers
# ==========================================================================
log()  { echo "==> $*"; }
warn() { echo "!! $*" >&2; }

gh_latest_tag() {
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

gh_asset_url() {
    # $1 owner/repo  $2 tag  $3 grep pattern
    curl -fsSL "https://api.github.com/repos/$1/releases/tags/$2" \
        | grep 'browser_download_url' \
        | grep "$3" \
        | head -n1 \
        | sed -E 's/.*"(https[^"]+)".*/\1/'
}

# ==========================================================================
# Guards
# ==========================================================================
if [[ $EUID -ne 0 ]]; then
    warn "Run as root (sudo)."; exit 1
fi
if [[ -z "${CAPTURE_IF}" ]]; then
    warn "No capture interface set. Use --iface NAME (see --help)."
    ip -o link show | awk -F': ' '{print "   " $2}' >&2
    exit 1
fi

. /etc/os-release 2>/dev/null || true
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
log "Host: $(hostname) | Distro: ${PRETTY_NAME:-unknown} | Arch: ${ARCH} | NIC: ${CAPTURE_IF}"

if ! ip link show "${CAPTURE_IF}" >/dev/null 2>&1; then
    warn "Capture interface ${CAPTURE_IF} not found. Available:"
    ip -o link show | awk -F': ' '{print "   " $2}' >&2
    exit 1
fi

CAPTURE_HAS_LINK=0
if ip link show "${CAPTURE_IF}" | grep -q "LOWER_UP"; then
    CAPTURE_HAS_LINK=1
else
    warn "${CAPTURE_IF} has NO CARRIER. Zeek workers cannot bind to a"
    warn "link-down NIC and will crash-loop. Patch it to the SPAN/mirror"
    warn "port first, or pass --force-start to try anyway."
fi

TARGET_USER="${SUDO_USER:-root}"

# ==========================================================================
# 1. Docker Engine + Compose plugin
# ==========================================================================
if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker Engine (official repo, ${VERSION_CODENAME:-stable})"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    DIST_ID="${ID:-debian}"
    curl -fsSL "https://download.docker.com/linux/${DIST_ID}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DIST_ID} ${VERSION_CODENAME:-stable} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
else
    log "Docker already present: $(docker --version)"
fi

if [[ "${TARGET_USER}" != "root" ]]; then
    usermod -aG docker "${TARGET_USER}" 2>/dev/null \
        && log "Added ${TARGET_USER} to docker group (re-login required)."
fi

# ==========================================================================
# 2. docker-zeek binary wrapper (version-matched to its own image)
# ==========================================================================
if [[ -n "${PIN_ZEEK_TAG}" ]]; then
    DZ_TAG="${PIN_ZEEK_TAG}"; log "docker-zeek pinned to ${DZ_TAG}"
else
    log "Resolving latest docker-zeek release..."
    DZ_TAG="$(gh_latest_tag activecm/docker-zeek)"
    log "latest = ${DZ_TAG:-<none>}"
fi

if [[ -z "${DZ_TAG}" ]]; then
    warn "Could not resolve docker-zeek tag (API rate-limit?). Skipping Zeek."
else
    DZ_ASSET="zeek-linux-${ARCH}.tar.gz"
    DZ_URL="$(gh_asset_url activecm/docker-zeek "${DZ_TAG}" "${DZ_ASSET}")"
    if [[ -z "${DZ_URL}" ]]; then
        warn "No ${DZ_ASSET} asset in ${DZ_TAG}. Skipping Zeek wrapper install."
    else
        log "Downloading + verifying docker-zeek wrapper (${DZ_TAG})"
        DZ_TMP="$(mktemp -d)"
        (
            cd "${DZ_TMP}"
            curl -fsSL -O "${DZ_URL}"
            CS_URL="$(gh_asset_url activecm/docker-zeek "${DZ_TAG}" 'checksums.txt')"
            OK=1
            if [[ -n "${CS_URL}" ]]; then
                curl -fsSL -O "${CS_URL}"
                # Multi-arch checksums file: verify ONLY our line, else the
                # absent other-arch file makes sha256sum -c fail spuriously.
                grep -F " ${DZ_ASSET}" checksums.txt > our-checksum.txt || true
                if [[ -s our-checksum.txt ]] && sha256sum -c our-checksum.txt >/dev/null 2>&1; then
                    echo "   checksum OK for ${DZ_ASSET}"
                else
                    echo "!! checksum FAILED for ${DZ_ASSET}; refusing to install." >&2
                    echo "   expected: $(cat our-checksum.txt 2>/dev/null || echo '<none>')" >&2
                    echo "   actual  : $(sha256sum "${DZ_ASSET}" 2>/dev/null)" >&2
                    OK=0
                fi
            else
                echo "!! No checksums.txt; proceeding without verification." >&2
            fi
            if [[ "${OK}" -eq 1 ]]; then
                tar -xzf "${DZ_ASSET}"
                install -m 0755 zeek /usr/local/bin/zeek
                echo "   installed: $(file -b /usr/local/bin/zeek | cut -d, -f1)"
            fi
        )
        rm -rf "${DZ_TMP}"
    fi
fi

# ==========================================================================
# 3. Start Zeek (only if wrapper installed AND NIC has carrier)
# ==========================================================================
if command -v zeek >/dev/null 2>&1 && file -b /usr/local/bin/zeek | grep -q ELF; then
    export zeek_top_dir="${ZEEK_TOP_DIR}"
    mkdir -p "${ZEEK_TOP_DIR}/logs" "${ZEEK_TOP_DIR}/spool" \
             "${ZEEK_TOP_DIR}/etc"  "${ZEEK_TOP_DIR}/manual-logs"
    chmod 0755 "${ZEEK_TOP_DIR}/logs" "${ZEEK_TOP_DIR}/spool"

    # Idempotency: skip start if the container is already healthy/running.
    if docker ps --filter 'name=^zeek$' --filter 'status=running' \
        --format '{{.Names}}' | grep -q '^zeek$'; then
        log "Zeek container already running - leaving it (use 'zeek restart' to reconfigure)."
    elif [[ "${CAPTURE_HAS_LINK}" -eq 1 || "${FORCE_START}" -eq 1 ]]; then
        [[ "${CAPTURE_HAS_LINK}" -eq 0 ]] && warn "Forcing start on a link-down NIC (--force-start)."
        log "Starting Zeek (wizard will prompt for the interface: choose ${CAPTURE_IF})"
        zeek start || warn "zeek start returned non-zero - check: docker logs zeek"
        zeek status || true
    else
        log "SKIPPING 'zeek start' - ${CAPTURE_IF} has no carrier."
        log "Once patched to the mirror port (LOWER_UP), run: zeek start"
    fi
else
    warn "Zeek wrapper not installed - skipping start."
fi

# ==========================================================================
# 4. Wazuh agent (optional) -> forward Zeek JSON logs
# ==========================================================================
if [[ "${INSTALL_WAZUH}" -eq 0 ]]; then
    log "Wazuh install disabled (--no-wazuh)."
elif [[ "${WAZUH_MANAGER}" == "__SET_ME__" || -z "${WAZUH_MANAGER}" ]]; then
    warn "WAZUH_MANAGER not set - skipping Wazuh agent."
    warn "Re-run with --wazuh-manager HOST when the manager is reachable."
else
    if [[ ! -x /var/ossec/bin/wazuh-control ]]; then
        log "Installing Wazuh agent -> ${WAZUH_MANAGER}"
        curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
            | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
        echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
            > /etc/apt/sources.list.d/wazuh.list
        apt-get update
        WAZUH_MANAGER="${WAZUH_MANAGER}" \
        WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP}" \
        apt-get install -y wazuh-agent
    else
        log "Wazuh agent already installed."
    fi

    OSSEC_CONF="/var/ossec/etc/ossec.conf"
    if [[ -f "${OSSEC_CONF}" ]] && ! grep -q "${ZEEK_LOG_CURRENT}" "${OSSEC_CONF}"; then
        log "Adding Zeek localfile stanzas to ossec.conf"
        TMP="$(mktemp)"
        awk -v d="${ZEEK_LOG_CURRENT}" '
            /<\/ossec_config>/ && !done {
                split("conn dns http ssl notice", f, " ")
                for (i in f) {
                    print "  <localfile>"
                    print "    <log_format>json</log_format>"
                    print "    <location>" d "/" f[i] ".log</location>"
                    print "  </localfile>"
                }
                done=1
            }
            { print }
        ' "${OSSEC_CONF}" > "${TMP}" && cat "${TMP}" > "${OSSEC_CONF}" && rm -f "${TMP}"
    fi

    systemctl daemon-reload
    systemctl enable wazuh-agent 2>/dev/null || true
    systemctl restart wazuh-agent
    log "Wazuh agent -> ${WAZUH_MANAGER} (group: ${WAZUH_AGENT_GROUP})"
    if ! getent hosts "${WAZUH_MANAGER}" >/dev/null 2>&1 \
        && ! [[ "${WAZUH_MANAGER}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "'${WAZUH_MANAGER}' does not resolve yet - agent will wait until it does."
    fi
fi

# ==========================================================================
# 5. RITA v5 (optional, Docker/ClickHouse)
# ==========================================================================
if [[ "${INSTALL_RITA}" -eq 0 ]]; then
    log "RITA install disabled (--no-rita)."
elif command -v rita >/dev/null 2>&1; then
    log "RITA already installed: $(rita --version 2>/dev/null | head -n1)"
else
    if [[ -n "${PIN_RITA_TAG}" ]]; then
        RITA_TAG="${PIN_RITA_TAG}"; log "RITA pinned to ${RITA_TAG}"
    else
        log "Resolving latest RITA release..."
        RITA_TAG="$(gh_latest_tag activecm/rita)"
        log "latest = ${RITA_TAG:-<none>}"
    fi

    if [[ -z "${RITA_TAG}" ]]; then
        warn "Could not resolve RITA tag (API rate-limit?). Skipping RITA."
    else
        # Asset is rita-<tag>.tar.gz, extracting to rita-<tag>-installer/.
        RITA_URL="$(gh_asset_url activecm/rita "${RITA_TAG}" "rita-${RITA_TAG}.tar.gz")"
        if [[ -z "${RITA_URL}" ]]; then
            RITA_URL="$(curl -fsSL "https://api.github.com/repos/activecm/rita/releases/tags/${RITA_TAG}" \
                | grep 'browser_download_url' | grep '\.tar\.gz' \
                | grep -v 'checksum' | head -n1 \
                | sed -E 's/.*"(https[^"]+)".*/\1/')"
        fi
        if [[ -z "${RITA_URL}" ]]; then
            warn "No RITA tarball asset found in ${RITA_TAG}. Assets:"
            curl -fsSL "https://api.github.com/repos/activecm/rita/releases/tags/${RITA_TAG}" \
                | grep browser_download_url >&2 || true
        else
            log "Installing RITA ${RITA_TAG}"
            RITA_HOME="/opt/rita-installer"
            mkdir -p "${RITA_HOME}"; cd "${RITA_HOME}"
            curl -fsSL -O "${RITA_URL}"
            tar -xzf "$(basename "${RITA_URL}")"
            INSTALLER_DIR="$(find . -maxdepth 1 -type d -name 'rita-*installer' | head -n1)"
            if [[ -n "${INSTALLER_DIR}" && -x "${INSTALLER_DIR}/install_rita.sh" ]]; then
                ( cd "${INSTALLER_DIR}" && ./install_rita.sh localhost ) \
                    || warn "RITA installer returned non-zero - review output above."
            else
                warn "install_rita.sh not found after extract - inspect ${RITA_HOME}."
            fi
        fi
    fi
fi

# ==========================================================================
# 6. Hourly rolling-import cron (if RITA present)
# ==========================================================================
if command -v rita >/dev/null 2>&1; then
    log "Installing hourly RITA rolling-import cron (minute :${CRON_MINUTE})"
    cat > /etc/cron.d/rita-rolling-import <<CRON
# RITA hourly rolling import of Zeek logs
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
${CRON_MINUTE} * * * * root rita import --rolling --database=${RITA_DATASET} --logs=${ZEEK_LOG_CURRENT} >> /var/log/rita-import.log 2>&1
CRON
    chmod 0644 /etc/cron.d/rita-rolling-import
else
    warn "rita not on PATH - cron not installed."
fi

# ==========================================================================
# 7. Summary
# ==========================================================================
echo ""
echo "============================================================"
echo " Sensor deployment finished (review any !! warnings above)."
echo "   Host        : $(hostname)"
echo "   docker-zeek : ${DZ_TAG:-<skipped>}"
echo "   RITA        : $(command -v rita >/dev/null 2>&1 && rita --version 2>/dev/null | head -n1 || echo '<not installed>')"
echo "   Capture NIC : ${CAPTURE_IF} $( [[ ${CAPTURE_HAS_LINK} -eq 1 ]] && echo '(link up)' || echo '(NO CARRIER - patch to mirror port, then: zeek start)')"
echo "   Zeek logs   : ${ZEEK_LOG_CURRENT}/"
echo "   Wazuh mgr   : ${WAZUH_MANAGER}"
echo "   RITA dataset: ${RITA_DATASET} (hourly rolling import)"
echo ""
echo " Verify:"
echo "   ip link show ${CAPTURE_IF}         # want LOWER_UP once patched"
echo "   zeek status ; docker ps            # Up (healthy), not Restarting"
echo "   docker logs zeek 2>&1 | tail       # worker bind errors if NIC down"
echo "   ls -l ${ZEEK_LOG_CURRENT}/          # logs appear once capturing"
echo "   rita view ${RITA_DATASET}           # hunt UI, after first import"
echo "============================================================"
