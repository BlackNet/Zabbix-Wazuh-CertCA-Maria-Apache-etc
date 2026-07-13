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
set -euo pipefail

# ###########################################################################
# ##  EDIT PER SITE  ########################################################
# ###########################################################################
TS_HOSTNAME="ssgc.taile9333.ts.net"     # this node's MagicDNS FQDN
WAZUH_PORT="444"                         # dashboard HTTPS port
INDEXER_HEAP="2g"                        # <=half of RAM; 2g suits <25 agents
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

# --- preflight -----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"
grep -q 'VERSION_CODENAME=trixie' /etc/os-release || die "not trixie"
command -v tailscale >/dev/null 2>&1 || die "tailscale not found"
TS_IP4="$(tailscale ip -4)" || die "tailscale not up"
[ -n "$TS_IP4" ] || die "no Tailscale IPv4"
[ -s "${CERT_DIR}/${TS_HOSTNAME}.crt" ] || die "cert missing - run stage 1"
[ -f "$CRED_FILE" ] || die "$CRED_FILE not found - run stage 1"
# Guard against accidental re-run on a completed box.
if [ -d /var/lib/wazuh-indexer ] && systemctl list-unit-files wazuh-manager.service >/dev/null 2>&1 \
   && systemctl is-active --quiet wazuh-manager 2>/dev/null; then
    die "wazuh-manager already active - this script is fresh-box only. Refusing to re-run."
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
echo "    indexer OK"

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
sed -i "s|^server.host:.*|server.host: \"${TS_IP4}\"|" "$DASH"
sed -i "s|^server.port:.*|server.port: ${WAZUH_PORT}|" "$DASH"
sed -i "s|^opensearch.hosts:.*|opensearch.hosts: https://${WAZUH_IP}:9200|" "$DASH"
grep -q '^server.ssl.enabled' "$DASH" && sed -i "s|^server.ssl.enabled:.*|server.ssl.enabled: true|" "$DASH" || echo "server.ssl.enabled: true" >> "$DASH"
grep -q '^server.ssl.certificate' "$DASH" && sed -i "s|^server.ssl.certificate:.*|server.ssl.certificate: /etc/wazuh-dashboard/certs/tailscale.pem|" "$DASH" || echo "server.ssl.certificate: /etc/wazuh-dashboard/certs/tailscale.pem" >> "$DASH"
grep -q '^server.ssl.key' "$DASH" && sed -i "s|^server.ssl.key:.*|server.ssl.key: /etc/wazuh-dashboard/certs/tailscale-key.pem|" "$DASH" || echo "server.ssl.key: /etc/wazuh-dashboard/certs/tailscale-key.pem" >> "$DASH"
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
if [ "$GOT" -lt 7 ]; then
  echo "ERROR: expected 7 passwords, got ${GOT}. Raw output:" >&2; cat "$ROT" >&2
  shred -u "$ROT"; die "rotation incomplete"
fi
shred -u "$ROT"
echo "    ${GOT} passwords captured"
. "$CRED_FILE"
grep -q '^opensearch.username' "$DASH" || echo "opensearch.username: kibanaserver" >> "$DASH"
grep -q '^opensearch.password' "$DASH" && sed -i "s|^opensearch.password:.*|opensearch.password: ${WAZUH_KIBANASERVER_PW}|" "$DASH" || echo "opensearch.password: ${WAZUH_KIBANASERVER_PW}" >> "$DASH"
systemctl restart filebeat wazuh-dashboard

# --- final health --------------------------------------------------------
echo "==> Final health check"
sleep 8
FAIL=0
for s in wazuh-indexer wazuh-manager filebeat wazuh-dashboard; do
  if systemctl is-active --quiet "$s"; then echo "    OK   $s"; else echo "    FAIL $s" >&2; FAIL=1; fi
done
filebeat test output 2>&1 | grep -qi 'talk to server... OK' || { echo "    FAIL filebeat->indexer" >&2; FAIL=1; }
[ "$FAIL" -eq 0 ] || die "services unhealthy after rotation"

cat <<EOF

===========================================================
Stage 3 complete.  (site: ${SITE})
  Dashboard  https://${TS_HOSTNAME}:${WAZUH_PORT}
  Login      admin / \$WAZUH_ADMIN_PW  (in ${CRED_FILE})
  Version    ${WAZUH_PKG_VER}

  The host self-monitors as agent 000 (SCA/FIM/vuln modules).
  It will not appear in the Agents fleet list - expected.
===========================================================
EOF