#!/usr/bin/env bash
#
# setup-spartan.sh
# Combined Zeek + RITA sensor build for host "Spartan" (Debian Trixie / 13).
#
# Architecture (all three read the SAME host log directory):
#   1. docker-zeek  (activecm/zeek, v8 binary wrapper) -> captures on eno1
#   2. Wazuh agent  (native on host) -> tails Zeek current/*.log -> tsims
#   3. RITA v5      (Docker/ClickHouse) -> hourly --rolling import
#
# Versioning: tracks LATEST releases by querying the GitHub API at runtime.
#   - The docker-zeek wrapper pulls its OWN matching image, so wrapper/image
#     cannot drift apart (that drift caused the v8.0.6 restart-loop on first
#     build: old master shell-script wrapper vs :latest image).
#   - To FREEZE versions for change control, set the PIN_* vars below.
#   - Resolved versions are printed in the summary for your records.
#
# Assumes: Tailscale, SSH keys, apache2 already present.
# Style:   LF line endings, documented flags only, no forced reboots.
#
set -euo pipefail

# ==========================================================================
# CONFIG - edit these before running
# ==========================================================================
TS_HOSTNAME="Spartan"

# Capture interface = the free NIC on the SPAN/mirror port.
# From `ifconfig -a`: eno1 (no IP). DO NOT use enp3s0 - that is the live
# management NIC. NOTE: Zeek workers CANNOT bind to eno1 until it has link
# (carrier) from the switch mirror port. Until then Zeek crash-loops - that
# is expected, not a fault. See the eno1 carrier check below.
CAPTURE_IF="eno1"

# Zeek host top-dir. The v8 wrapper manages config INSIDE the image at
# /usr/local/zeek/etc/node.cfg; logs are bind-mounted out to here.
ZEEK_TOP_DIR="/opt/zeek"
ZEEK_LOG_CURRENT="${ZEEK_TOP_DIR}/logs/current"

# Wazuh manager (tsims). Leave as __SET_ME__ to SKIP the agent section
# (tsims admin-VLAN IP not assigned yet). Set it and re-run when ready.
WAZUH_MANAGER="__SET_ME__"          # e.g. tsims admin-VLAN IP
WAZUH_AGENT_GROUP="zeek"

RITA_DATASET="spartan_rolling"

# Non-root user to add to the docker group.
TARGET_USER="${SUDO_USER:-root}"

# ---- Version pinning (OPTIONAL) -----------------------------------------
# Leave empty to track latest. Set to a tag (e.g. "v8.0.6" / "v5.1.2") to
# freeze for change control. Empty = query GitHub API for newest release.
PIN_DOCKER_ZEEK=""     # e.g. v8.0.6
PIN_RITA=""            # e.g. v5.1.2

# ==========================================================================
# Helpers
# ==========================================================================
# Resolve the latest release tag for an activecm repo, unless pinned.
gh_latest_tag() {
    # $1 = owner/repo
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

# Resolve a browser_download_url from a release, matching a filename pattern.
gh_asset_url() {
    # $1 = owner/repo   $2 = tag   $3 = grep pattern for the asset filename
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
    echo "Run as root (sudo)." >&2
    exit 1
fi

. /etc/os-release
echo "==> Host: ${TS_HOSTNAME} | Distro: ${PRETTY_NAME} | Capture NIC: ${CAPTURE_IF}"
if [[ "${ID}" != "debian" ]]; then
    echo "WARNING: expected Debian, found '${ID}'. Continuing anyway." >&2
fi

if ! ip link show "${CAPTURE_IF}" >/dev/null 2>&1; then
    echo "ERROR: capture interface ${CAPTURE_IF} not found." >&2
    ip -o link show | awk -F': ' '{print "  " $2}' >&2
    exit 1
fi

# Does eno1 have carrier? Zeek workers will not bind without it.
CAPTURE_HAS_LINK=0
if ip link show "${CAPTURE_IF}" | grep -q "LOWER_UP"; then
    CAPTURE_HAS_LINK=1
else
    echo "!! ${CAPTURE_IF} has NO CARRIER (link down)."
    echo "   Zeek workers cannot bind to a link-down NIC and will crash-loop."
    echo "   Patch ${CAPTURE_IF} into the switch SPAN/mirror port first."
fi

ARCH="$(dpkg --print-architecture)"   # amd64 on Spartan

# ==========================================================================
# 1. Docker Engine + Compose plugin (official Docker repo, Trixie)
# ==========================================================================
if ! command -v docker >/dev/null 2>&1; then
    echo "==> Installing Docker Engine (official repo, ${VERSION_CODENAME})"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
else
    echo "==> Docker already present: $(docker --version)"
fi

if [[ "${TARGET_USER}" != "root" ]]; then
    usermod -aG docker "${TARGET_USER}" || true
    echo "   Added ${TARGET_USER} to docker group (re-login required)."
fi

# ==========================================================================
# 2. docker-zeek v8 binary wrapper (version-matched to its own image)
# ==========================================================================
# IMPORTANT: the current docker-zeek wrapper is a compiled Go BINARY shipped
# as a release asset (zeek-linux-<arch>.tar.gz), NOT the master shell script.
# The image enforces a wrapper-version match; using the master script fails.
if [[ -n "${PIN_DOCKER_ZEEK}" ]]; then
    DZ_TAG="${PIN_DOCKER_ZEEK}"
    echo "==> docker-zeek pinned to ${DZ_TAG}"
else
    echo "==> Resolving latest docker-zeek release..."
    DZ_TAG="$(gh_latest_tag activecm/docker-zeek)"
    echo "   latest = ${DZ_TAG}"
fi
[[ -n "${DZ_TAG}" ]] || { echo "ERROR: could not resolve docker-zeek tag." >&2; exit 1; }

DZ_ASSET="zeek-linux-${ARCH}.tar.gz"
DZ_URL="$(gh_asset_url activecm/docker-zeek "${DZ_TAG}" "${DZ_ASSET}")"
[[ -n "${DZ_URL}" ]] || { echo "ERROR: no ${DZ_ASSET} asset in ${DZ_TAG}." >&2; exit 1; }

echo "==> Downloading + verifying docker-zeek wrapper (${DZ_TAG})"
DZ_TMP="$(mktemp -d)"
pushd "${DZ_TMP}" >/dev/null
curl -fsSL -O "${DZ_URL}"
CS_URL="$(gh_asset_url activecm/docker-zeek "${DZ_TAG}" 'checksums.txt')"
if [[ -n "${CS_URL}" ]]; then
    curl -fsSL -O "${CS_URL}"
    # checksums.txt is multi-arch; verifying the whole file fails on the
    # arch we didn't download (missing file). Extract only OUR line and
    # verify just that, so the other-arch entry can't false-fail us.
    if grep -F " ${DZ_ASSET}" checksums.txt > our-checksum.txt \
       && [[ -s our-checksum.txt ]] \
       && sha256sum -c our-checksum.txt >/dev/null 2>&1; then
        echo "   checksum OK for ${DZ_ASSET}"
    else
        echo "ERROR: checksum FAILED for ${DZ_ASSET}. Refusing to install." >&2
        echo "   expected: $(grep -F " ${DZ_ASSET}" checksums.txt || echo '<line not found>')" >&2
        echo "   actual  : $(sha256sum "${DZ_ASSET}" 2>/dev/null || echo '<hash failed>')" >&2
        popd >/dev/null; rm -rf "${DZ_TMP}"; exit 1
    fi
else
    echo "!! No checksums.txt in release - proceeding without verification."
fi

tar -xzf "${DZ_ASSET}"          # extracts a bare 'zeek' binary
install -m 0755 zeek /usr/local/bin/zeek
popd >/dev/null
rm -rf "${DZ_TMP}"
echo "   installed: $(file -b /usr/local/bin/zeek | cut -d, -f1)"

# ==========================================================================
# 3. Start Zeek (wrapper pulls its own matching image, runs the wizard)
# ==========================================================================
export zeek_top_dir="${ZEEK_TOP_DIR}"

# Pre-create host dirs (the wizard needs the bind-mount source to exist).
mkdir -p "${ZEEK_TOP_DIR}/logs" "${ZEEK_TOP_DIR}/spool" \
         "${ZEEK_TOP_DIR}/etc"  "${ZEEK_TOP_DIR}/manual-logs"
chmod 0755 "${ZEEK_TOP_DIR}/logs" "${ZEEK_TOP_DIR}/spool"

if [[ "${CAPTURE_HAS_LINK}" -eq 1 ]]; then
    echo "==> Starting Zeek on ${CAPTURE_IF} (has carrier)"
    echo "    The wizard will prompt for the interface - choose ${CAPTURE_IF}."
    zeek start || echo "!! zeek start returned non-zero - check: docker logs zeek"
    zeek status || true
else
    echo "==> SKIPPING 'zeek start' - ${CAPTURE_IF} has no carrier."
    echo "    Wrapper installed and ready. Once ${CAPTURE_IF} is patched to the"
    echo "    mirror port and shows LOWER_UP, run:  zeek start"
    echo "    (the wizard will ask for the interface - pick ${CAPTURE_IF})."
fi

# ==========================================================================
# 4. Wazuh agent (native) -> forward Zeek JSON logs to tsims
# ==========================================================================
if [[ "${WAZUH_MANAGER}" == "__SET_ME__" ]]; then
    echo "!! WAZUH_MANAGER not set - skipping Wazuh agent (as intended until"
    echo "   the admin-VLAN scheme / tsims IP exists). Set it and re-run."
else
    if [[ ! -x /var/ossec/bin/wazuh-control ]]; then
        echo "==> Installing Wazuh agent -> ${WAZUH_MANAGER}"
        curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
            | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
        echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
            > /etc/apt/sources.list.d/wazuh.list
        apt-get update
        WAZUH_MANAGER="${WAZUH_MANAGER}" \
        WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP}" \
        apt-get install -y wazuh-agent
    else
        echo "==> Wazuh agent already installed."
    fi

    OSSEC_CONF="/var/ossec/etc/ossec.conf"
    if ! grep -q "${ZEEK_LOG_CURRENT}" "${OSSEC_CONF}" 2>/dev/null; then
        echo "==> Adding Zeek localfile stanzas to ossec.conf"
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
    systemctl enable wazuh-agent
    systemctl restart wazuh-agent
    echo "==> Wazuh agent -> ${WAZUH_MANAGER} (group: ${WAZUH_AGENT_GROUP})"
fi

# ==========================================================================
# 5. RITA v5 (Docker / ClickHouse) - latest release, asset resolved at runtime
# ==========================================================================
if [[ -n "${PIN_RITA}" ]]; then
    RITA_TAG="${PIN_RITA}"
    echo "==> RITA pinned to ${RITA_TAG}"
else
    echo "==> Resolving latest RITA release..."
    RITA_TAG="$(gh_latest_tag activecm/rita)"
    echo "   latest = ${RITA_TAG}"
fi

if [[ -z "${RITA_TAG}" ]]; then
    echo "!! Could not resolve RITA tag - skipping RITA. Install manually later."
else
    # The installer ships as an -installer.tar.gz asset; resolve its real name
    # from the API rather than guessing (a guessed name is what 404'd before).
    RITA_URL="$(gh_asset_url activecm/rita "${RITA_TAG}" 'installer.tar.gz')"
    if [[ -z "${RITA_URL}" ]]; then
        echo "!! No installer asset found in ${RITA_TAG}. Assets available:"
        curl -fsSL "https://api.github.com/repos/activecm/rita/releases/tags/${RITA_TAG}" \
            | grep browser_download_url || true
        echo "   Skipping RITA - grab the right asset manually."
    else
        echo "==> Installing RITA ${RITA_TAG}"
        echo "    NOTE: RITA v5 officially supports Ubuntu 22.04/24.04 + RHEL 9."
        echo "    Debian Trixie is NOT listed. If install_rita.sh errors on distro"
        echo "    detection, STOP and report the message - do not force it."
        RITA_HOME="/opt/rita-installer"
        mkdir -p "${RITA_HOME}"; cd "${RITA_HOME}"
        curl -fsSL -O "${RITA_URL}"
        tar -xzf "$(basename "${RITA_URL}")"
        INSTALLER_DIR="$(find . -maxdepth 1 -type d -name 'rita-*installer' | head -n1)"
        if [[ -n "${INSTALLER_DIR}" && -x "${INSTALLER_DIR}/install_rita.sh" ]]; then
            ( cd "${INSTALLER_DIR}" && ./install_rita.sh localhost ) \
                || echo "!! RITA installer returned non-zero (likely Debian distro check)."
        else
            echo "!! install_rita.sh not found after extract - inspect ${RITA_HOME}."
        fi
    fi
fi

# ==========================================================================
# 6. Hourly rolling import cron (only if rita installed cleanly)
# ==========================================================================
if command -v rita >/dev/null 2>&1; then
    echo "==> Installing hourly RITA rolling-import cron"
    cat > /etc/cron.d/rita-rolling-import << CRON
# RITA hourly rolling import of Spartan Zeek logs (runs at :05)
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
5 * * * * root rita import --rolling --database=${RITA_DATASET} --logs=${ZEEK_LOG_CURRENT} >> /var/log/rita-import.log 2>&1
CRON
    chmod 0644 /etc/cron.d/rita-rolling-import
    echo "   cron: hourly rita import --rolling --database=${RITA_DATASET}"
else
    echo "!! rita not on PATH - cron not installed. Add after RITA installs:"
    echo "   5 * * * * root rita import --rolling --database=${RITA_DATASET} --logs=${ZEEK_LOG_CURRENT}"
fi

# ==========================================================================
# 7. Summary (records the versions actually deployed)
# ==========================================================================
echo ""
echo "============================================================"
echo " ${TS_HOSTNAME} setup complete (review any !! warnings above)."
echo "   docker-zeek : ${DZ_TAG}   (wrapper + matching image)"
echo "   RITA        : ${RITA_TAG:-<not installed>}"
echo "   Capture NIC : ${CAPTURE_IF} $( [[ ${CAPTURE_HAS_LINK} -eq 1 ]] && echo '(link up)' || echo '(NO CARRIER - patch to mirror port, then: zeek start)')"
echo "   Zeek logs   : ${ZEEK_LOG_CURRENT}/"
echo "   node.cfg    : /usr/local/zeek/etc/node.cfg (inside image)"
echo "   Wazuh mgr   : ${WAZUH_MANAGER}"
echo "   RITA dataset: ${RITA_DATASET} (hourly rolling)"
echo ""
echo " Verify:"
echo "   ip link show ${CAPTURE_IF}          # want LOWER_UP once patched"
echo "   zeek status ; docker ps             # Up (healthy), not Restarting"
echo "   docker logs zeek 2>&1 | tail        # worker bind errors if NIC down"
echo "   ls -l ${ZEEK_LOG_CURRENT}/           # logs appear once capturing"
echo "   rita view ${RITA_DATASET}            # hunt UI, after first import"
echo "============================================================"
