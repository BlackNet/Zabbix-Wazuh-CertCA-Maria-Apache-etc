#!/bin/bash
#
# Stage 3: Wazuh all-in-one (indexer + manager + filebeat + dashboard)
# Debian 13 (Trixie).  Requires stage 1 (Tailscale cert).  Run as root.
#
# FRESH-BOX ONLY.  This script assumes a clean host: it runs
# indexer-security-init.sh (once-per-cluster) and rotates passwords.  Do NOT
# re-run on a box that already completed stage 3 - it will re-rotate and the
# admin:admin wait-check will fail against already-rotated credentials.
#
# The Wazuh host monitors ITSELF as agent 000 (FIM, SCA cis_debian13,
# rootcheck, vuln detection are on by default).  Agent 000 does NOT appear in
# the dashboard's Agents fleet list - that is expected; the manager cannot
# also run the conflicting wazuh-agent package.  Host security data is under
# the SCA / FIM / Vulnerability modules for the manager node.
#
# KEY MATERIAL: this script generates an internal PKI under $WORK
# (/root/wazuh-install) and LEAVES IT THERE.  wazuh-certificates/root-ca.key
# is the CA for the indexer/manager/dashboard certs - it is required to issue
# certs for any node added later, so it must not be deleted, but it is
# unlabelled private key material sitting in /root.  Record it in your key
# inventory and back it up with the same care as any other CA key.
#
set -euo pipefail

# ###########################################################################
# ##  EDIT PER SITE  ########################################################
# ###########################################################################
TS_HOSTNAME="monitor.example.ts.net"    # this node's MagicDNS FQDN
WAZUH_PORT="444"                         # dashboard HTTPS port

# JVM heap for the indexer.  Leave empty to auto-size from installed RAM
# (RAM/4, floor 2g, cap 31g - above ~32g the JVM loses compressed object
# pointers and effectively wastes the extra memory).  RAM/4 rather than the
# usual RAM/2 because MariaDB's InnoDB buffer pool from stage 1 is competing
# for the same memory on an all-in-one box.
# Set explicitly (e.g. "8g") to override.
INDEXER_HEAP=""
# ###########################################################################

# --- Derived / usually leave alone ---------------------------------------
SITE="$(echo "$TS_HOSTNAME" | cut -d. -f1)"
CERT_DIR="/etc/ssl/tailscale"
CRED_FILE="/root/.${SITE}-credentials"
WORK="/root/wazuh-install"
NODE_INDEXER="node-1"; NODE_SERVER="wazuh-1"; NODE_DASH="dashboard"
WAZUH_IP="127.0.0.1"
export DEBIAN_FRONTEND=noninteractive
die() { echo "ERROR: $*" >&2; exit 1; }

# yml_set <file> <key> <value> - set a top-level key, replacing it if present
# (commented or not) and appending it if absent.  Replaces the
# 'grep && sed || echo' idiom, where a failing sed silently falls through to
# the echo and appends a duplicate key.
yml_set() {
    local f="$1" k="$2" v="$3"
    if grep -q "^${k}:" "$f"; then
        sed -i "s|^${k}:.*|${k}: ${v}|" "$f"
    elif grep -q "^# *${k}:" "$f"; then
        sed -i "s|^# *${k}:.*|${k}: ${v}|" "$f"
    else
        echo "${k}: ${v}" >> "$f"
    fi
}

# --- preflight -----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"
grep -q 'VERSION_CODENAME=trixie' /etc/os-release || die "not trixie"
command -v tailscale >/dev/null 2>&1 || die "tailscale not found"
TS_IP4="$(tailscale ip -4)" || die "tailscale not up"
[ -n "$TS_IP4" ] || die "no Tailscale IPv4"
[ -s "${CERT_DIR}/${TS_HOSTNAME}.crt" ] || die "cert missing - run stage 1"
[ -f "$CRED_FILE" ] || die "$CRED_FILE not found - run stage 1"

# Guard against re-run.  Checking wazuh-manager alone leaves a gap: a run
# that dies between indexer-security-init.sh and the manager install would
# not trip it, and re-running would re-initialise the security index on an
# already-initialised cluster.  Check every component, and the indexer
# package independently of whether its service happens to be up.
for _svc in wazuh-indexer wazuh-manager wazuh-dashboard filebeat; do
    if systemctl list-unit-files "${_svc}.service" >/dev/null 2>&1 \
       && systemctl is-active --quiet "$_svc" 2>/dev/null; then
        die "${_svc} is already active - this script is fresh-box only. Refusing to re-run."
    fi
done
if dpkg-query -W -f='${Status}' wazuh-indexer 2>/dev/null | grep -q 'install ok installed'; then
    die "wazuh-indexer is already installed (service down). Partial install - clean up before re-running."
fi
if grep -q '^WAZUH_.*_PW=' "$CRED_FILE" 2>/dev/null; then
    die "$CRED_FILE already holds rotated Wazuh passwords - stage 3 has run here before."
fi

# --- indexer heap sizing --------------------------------------------------
if [ -z "$INDEXER_HEAP" ]; then
    RAM_MB="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)"
    HEAP_MB=$(( RAM_MB / 4 ))
    [ "$HEAP_MB" -lt 2048 ]  && HEAP_MB=2048
    [ "$HEAP_MB" -gt 31744 ] && HEAP_MB=31744
    INDEXER_HEAP="$(( HEAP_MB / 1024 ))g"
    echo "==> INDEXER_HEAP auto-sized to ${INDEXER_HEAP} (${RAM_MB} MB RAM installed)"
else
    echo "==> INDEXER_HEAP set explicitly to ${INDEXER_HEAP}"
fi

echo "==> Preflight OK (site ${SITE}, ${TS_HOSTNAME}, ${TS_IP4}, port ${WAZUH_PORT})"

# --- repo + resolve latest 4.x -------------------------------------------
echo "==> Wazuh repo + version resolve"
apt-get install -y curl gnupg apt-transport-https
curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
  | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
  > /etc/apt/sources.list.d/wazuh.list
apt-get update
WAZUH_PKG_VER="$(apt-cache policy wazuh-manager | awk '/Candidate:/{print $2}')"
WAZUH_VER="$(echo "$WAZUH_PKG_VER" | grep -oE '^[0-9]+\.[0-9]+')"
WAZUH_VER_FULL="$(echo "$WAZUH_PKG_VER" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')"
[ -n "$WAZUH_VER" ] && [ -n "$WAZUH_VER_FULL" ] || die "version resolve failed"
echo "    ${WAZUH_PKG_VER} (minor ${WAZUH_VER}, full ${WAZUH_VER_FULL})"

# --- certs ---------------------------------------------------------------
echo "==> Internal certificates"
install -d -m 0700 "$WORK"; cd "$WORK"
curl -fsSL -o wazuh-certs-tool.sh "https://packages.wazuh.com/${WAZUH_VER}/wazuh-certs-tool.sh"
cat > "$WORK/config.yml" <<EOF
nodes:
  indexer:
    - name: ${NODE_INDEXER}
      ip: ${WAZUH_IP}
  server:
    - name: ${NODE_SERVER}
      ip: ${WAZUH_IP}
  dashboard:
    - name: ${NODE_DASH}
      ip: ${WAZUH_IP}
EOF
bash ./wazuh-certs-tool.sh -A
tar -cf "$WORK/wazuh-certificates.tar" -C "$WORK/wazuh-certificates/" .
tar -tf "$WORK/wazuh-certificates.tar" | grep -q "root-ca.pem" || die "cert gen failed"

# --- indexer -------------------------------------------------------------
echo "==> wazuh-indexer"
apt-get install -y wazuh-indexer
sed -i "s|^-Xms.*|-Xms${INDEXER_HEAP}|" /etc/wazuh-indexer/jvm.options
sed -i "s|^-Xmx.*|-Xmx${INDEXER_HEAP}|" /etc/wazuh-indexer/jvm.options
sed -i "s|^network.host:.*|network.host: \"${WAZUH_IP}\"|" /etc/wazuh-indexer/opensearch.yml
install -d -m 0500 /etc/wazuh-indexer/certs
tar -xf "$WORK/wazuh-certificates.tar" -C /etc/wazuh-indexer/certs/ \
  "./${NODE_INDEXER}.pem" "./${NODE_INDEXER}-key.pem" ./admin.pem ./admin-key.pem ./root-ca.pem
mv -n "/etc/wazuh-indexer/certs/${NODE_INDEXER}.pem"     /etc/wazuh-indexer/certs/indexer.pem
mv -n "/etc/wazuh-indexer/certs/${NODE_INDEXER}-key.pem" /etc/wazuh-indexer/certs/indexer-key.pem
chmod 400 /etc/wazuh-indexer/certs/*
chown -R wazuh-indexer:wazuh-indexer /etc/wazuh-indexer/certs
systemctl daemon-reload; systemctl enable --now wazuh-indexer
/usr/share/wazuh-indexer/bin/indexer-security-init.sh
# admin:admin is correct here - passwords are not rotated until the end.
for _ in $(seq 1 30); do curl -sk -u admin:admin "https://${WAZUH_IP}:9200/" >/dev/null 2>&1 && break; sleep 2; done
curl -sk -u admin:admin "https://${WAZUH_IP}:9200/" >/dev/null 2>&1 || die "indexer not up on 9200"
echo "    indexer OK (heap ${INDEXER_HEAP})"

# --- manager -------------------------------------------------------------
echo "==> wazuh-manager"
apt-get install -y wazuh-manager
systemctl daemon-reload; systemctl enable --now wazuh-manager
systemctl is-active --quiet wazuh-manager || die "manager failed"
echo "    manager OK"

# --- filebeat ------------------------------------------------------------
echo "==> filebeat"
apt-get install -y filebeat
curl -fsSL -o /etc/filebeat/filebeat.yml "https://packages.wazuh.com/${WAZUH_VER}/tpl/wazuh/filebeat/filebeat.yml"
sed -i "s|hosts:.*|hosts: [\"${WAZUH_IP}:9200\"]|" /etc/filebeat/filebeat.yml
filebeat keystore create --force 2>/dev/null || filebeat keystore create
echo admin | filebeat keystore add username --stdin --force
echo admin | filebeat keystore add password --stdin --force
curl -fsSL -o /etc/filebeat/wazuh-template.json \
  "https://raw.githubusercontent.com/wazuh/wazuh/v${WAZUH_VER_FULL}/extensions/elasticsearch/7.x/wazuh-template.json"
[ -s /etc/filebeat/wazuh-template.json ] || die "template empty - tag v${WAZUH_VER_FULL} missing"
chmod go+r /etc/filebeat/wazuh-template.json
curl -fsSL https://packages.wazuh.com/4.x/filebeat/wazuh-filebeat-0.4.tar.gz | tar -xz -C /usr/share/filebeat/module
install -d -m 0500 /etc/filebeat/certs
tar -xf "$WORK/wazuh-certificates.tar" -C /etc/filebeat/certs/ \
  "./${NODE_SERVER}.pem" "./${NODE_SERVER}-key.pem" ./root-ca.pem
mv -n "/etc/filebeat/certs/${NODE_SERVER}.pem"     /etc/filebeat/certs/filebeat.pem
mv -n "/etc/filebeat/certs/${NODE_SERVER}-key.pem" /etc/filebeat/certs/filebeat-key.pem
chmod 400 /etc/filebeat/certs/*
chown -R root:root /etc/filebeat/certs
systemctl daemon-reload; systemctl enable --now filebeat
filebeat test output 2>&1 | grep -qi 'talk to server... OK' || die "filebeat cannot reach indexer"
echo "    filebeat OK"

# --- dashboard -----------------------------------------------------------
echo "==> wazuh-dashboard"
apt-get install -y wazuh-dashboard
install -d -m 0500 /etc/wazuh-dashboard/certs
tar -xf "$WORK/wazuh-certificates.tar" -C /etc/wazuh-dashboard/certs/ \
  "./${NODE_DASH}.pem" "./${NODE_DASH}-key.pem" ./root-ca.pem
mv -n "/etc/wazuh-dashboard/certs/${NODE_DASH}.pem"     /etc/wazuh-dashboard/certs/dashboard.pem
mv -n "/etc/wazuh-dashboard/certs/${NODE_DASH}-key.pem" /etc/wazuh-dashboard/certs/dashboard-key.pem
cp "$CERT_DIR/$TS_HOSTNAME.crt" /etc/wazuh-dashboard/certs/tailscale.pem
cp "$CERT_DIR/$TS_HOSTNAME.key" /etc/wazuh-dashboard/certs/tailscale-key.pem
chmod 400 /etc/wazuh-dashboard/certs/*
chown -R wazuh-dashboard:wazuh-dashboard /etc/wazuh-dashboard/certs
DASH=/etc/wazuh-dashboard/opensearch_dashboards.yml
yml_set "$DASH" "server.host"             "\"${TS_IP4}\""
yml_set "$DASH" "server.port"             "${WAZUH_PORT}"
yml_set "$DASH" "opensearch.hosts"        "https://${WAZUH_IP}:9200"
yml_set "$DASH" "server.ssl.enabled"      "true"
yml_set "$DASH" "server.ssl.certificate"  "/etc/wazuh-dashboard/certs/tailscale.pem"
yml_set "$DASH" "server.ssl.key"          "/etc/wazuh-dashboard/certs/tailscale-key.pem"
# Ports below 1024 need the capability; ${WAZUH_PORT} may or may not be one.
setcap 'cap_net_bind_service=+ep' /usr/share/wazuh-dashboard/node/bin/node || true
systemctl daemon-reload; systemctl enable --now wazuh-dashboard
for _ in $(seq 1 20); do ss -tlnp 2>/dev/null | grep -q ":${WAZUH_PORT}" && break; sleep 3; done
ss -tlnp 2>/dev/null | grep -q ":${WAZUH_PORT}" || die "dashboard not listening on ${WAZUH_PORT}"
echo "    dashboard OK"

# --- password rotation ---------------------------------------------------
echo "==> Rotating internal passwords"
PWTOOL=/usr/share/wazuh-indexer/plugins/opensearch-security/tools/wazuh-passwords-tool.sh
ROT="$(mktemp)"
"$PWTOOL" -a > "$ROT" 2>&1 || true
{
  echo ""
  echo "# ---- Wazuh internal users (rotated $(date -Iseconds)) ----"
  grep 'The password for user' "$ROT" | sed -E "s/.*user ([a-zA-Z0-9_]+) is (.*)$/WAZUH_\U\1\E_PW='\2'/"
} >> "$CRED_FILE"
chmod 0600 "$CRED_FILE"
GOT="$(grep -c '^WAZUH_.*_PW=' "$CRED_FILE" || true)"
# 7 internal users is what current 4.x ships.  The count is not load-bearing -
# a future point release adding or removing a user should not abort an
# otherwise healthy install, so warn rather than die.  admin and kibanaserver
# ARE load-bearing: the summary and the dashboard config below need them.
if [ "$GOT" -ne 7 ]; then
  echo "    NOTE: captured ${GOT} passwords (expected 7 for current 4.x)." >&2
  echo "          Verify ${CRED_FILE} lists the users you expect:" >&2
  grep -o "^WAZUH_[A-Z0-9_]*_PW" "$CRED_FILE" | sed 's/^/            /' >&2
fi
shred -u "$ROT"
echo "    ${GOT} passwords captured"
. "$CRED_FILE"
[ -n "${WAZUH_ADMIN_PW:-}" ]        || die "admin password not captured - check $CRED_FILE"
[ -n "${WAZUH_KIBANASERVER_PW:-}" ] || die "kibanaserver password not captured - check $CRED_FILE"
yml_set "$DASH" "opensearch.username" "kibanaserver"
yml_set "$DASH" "opensearch.password" "${WAZUH_KIBANASERVER_PW}"
systemctl restart filebeat wazuh-dashboard

# --- final health --------------------------------------------------------
echo "==> Final health check"
sleep 8
FAIL=0
for s in wazuh-indexer wazuh-manager filebeat wazuh-dashboard; do
  if systemctl is-active --quiet "$s"; then echo "    OK   $s"; else echo "    FAIL $s" >&2; FAIL=1; fi
done
# This also proves the rotation did not orphan filebeat's stored credentials.
filebeat test output 2>&1 | grep -qi 'talk to server... OK' || { echo "    FAIL filebeat->indexer" >&2; FAIL=1; }
[ "$FAIL" -eq 0 ] || die "services unhealthy after rotation"

# NOTE: the password is deliberately NOT expanded below - printing it here
# would put it in the terminal scrollback and any captured install log.
cat <<EOF

===========================================================
Stage 3 complete.  (site: ${SITE})
  Dashboard  https://${TS_HOSTNAME}:${WAZUH_PORT}
  Login      user 'admin', password in ${CRED_FILE}
             (variable WAZUH_ADMIN_PW)
  Version    ${WAZUH_PKG_VER}
  Heap       ${INDEXER_HEAP}

  The host self-monitors as agent 000 (SCA/FIM/vuln modules).
  It will not appear in the Agents fleet list - expected.

  ${WORK}/wazuh-certificates/ holds the internal CA key needed to
  issue certs for any node added later.  Keep it, back it up, and
  record it in your key inventory.
===========================================================
EOF
