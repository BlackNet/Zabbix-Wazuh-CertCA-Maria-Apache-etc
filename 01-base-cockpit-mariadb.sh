#!/bin/bash
#
# Stage 1: base packages + Cockpit + MariaDB + Zabbix DB
# Debian 13 (Trixie).  Run as root.  Idempotent.  Run order: 01 -> 02 -> 03
#
set -euo pipefail

# ###########################################################################
# ##  EDIT PER SITE  ########################################################
# ###########################################################################
TS_HOSTNAME="monitor.example.ts.net"    # this node's MagicDNS FQDN

# MariaDB sizing.  Defaults suit a small box (<25 agents, 8-16GB RAM).
# Rule of thumb: buffer pool ~1/3 of RAM.  A 32GB host running Zabbix +
# Wazuh alongside wants ~10G here, not the whole third - the Wazuh indexer
# heap competes for the same memory.
INNODB_BUFFER_POOL="1G"                 # 10G on a 32GB Zabbix+Wazuh host
INNODB_LOG_FILE="256M"                  # 1G for write-heavy fleets (100+ agents)
# Zabbix is monitoring data: losing <=1s of writes on power loss is an
# acceptable trade for the throughput gain.  Set to 1 for strict ACID.
INNODB_FLUSH_LOG="2"
# ###########################################################################

# --- Derived / usually leave alone ---------------------------------------
# SITE is the short hostname (e.g. "monitor") - used for file/service naming
# so nothing is hardcoded to one site.
SITE="$(echo "$TS_HOSTNAME" | cut -d. -f1)"
TS_IFACE="tailscale0"
COCKPIT_PORT="9090"
CRED_FILE="/root/.${SITE}-credentials"
CERT_DIR="/etc/ssl/tailscale"
RENEW_SH="/usr/local/sbin/${SITE}-cert-renew.sh"
RENEW_UNIT="${SITE}-cert-renew"
MARIADB_CNF="/etc/mysql/mariadb.conf.d/99-${SITE}.cnf"
ZABBIX_DB_NAME="zabbix"
ZABBIX_DB_USER="zabbix"
export DEBIAN_FRONTEND=noninteractive

# --- Preflight -----------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then echo "ERROR: must run as root" >&2; exit 1; fi
if ! grep -q 'VERSION_CODENAME=trixie' /etc/os-release; then
    echo "ERROR: targets Debian 13 (trixie)" >&2; exit 1; fi
if ! command -v tailscale >/dev/null 2>&1; then echo "ERROR: tailscale not found" >&2; exit 1; fi
if ! ip link show "$TS_IFACE" >/dev/null 2>&1; then
    echo "ERROR: $TS_IFACE not present - is tailscaled up?" >&2; exit 1; fi

# --- Base tooling --------------------------------------------------------
# NOTE: sudo is included deliberately.  Debian minimal installs omit it, and
# downstream tooling (Zabbix agent2 UserParameters, Wazuh SCA checks) assumes
# it exists even when everything here runs as root.
echo "==> apt-get update"
apt-get update
echo "==> Installing base tooling"
apt-get install -y ca-certificates curl gnupg apt-transport-https joe openssl sudo

# --- Credentials ---------------------------------------------------------
if [ -f "$CRED_FILE" ]; then
    echo "==> Using existing credentials"
    . "$CRED_FILE"
else
    echo "==> Generating MariaDB credentials -> $CRED_FILE"
    MARIADB_ROOT_PW="$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-28)"
    ZABBIX_DB_PW="$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-28)"
    # umask is scoped to this subshell so it cannot leak into later file
    # creation.  A stray 'umask 077' here silently makes every subsequent
    # bare 'cat >' root-only - including the MariaDB config, which mysqld
    # (running as user mysql) then cannot read and skips WITHOUT logging.
    ( umask 077
      cat > "$CRED_FILE" <<EOF
# ${SITE} generated credentials - $(date -Iseconds)
# ---- MariaDB ----
MARIADB_ROOT_PW='${MARIADB_ROOT_PW}'
ZABBIX_DB_NAME='${ZABBIX_DB_NAME}'
ZABBIX_DB_USER='${ZABBIX_DB_USER}'
ZABBIX_DB_PW='${ZABBIX_DB_PW}'
EOF
    )
    chmod 0600 "$CRED_FILE"
fi

# --- Tailscale TLS certificate (shared by Apache, Wazuh, Cockpit) --------
echo "==> Issuing Tailscale TLS certificate for ${TS_HOSTNAME}"
echo "    (requires HTTPS Certificates enabled in the Tailscale admin console)"
install -d -m 0755 "$CERT_DIR"
( cd "$CERT_DIR" && tailscale cert "$TS_HOSTNAME" )
if [ ! -s "${CERT_DIR}/${TS_HOSTNAME}.crt" ]; then
    echo "ERROR: cert issuance failed" >&2; exit 1; fi
chmod 0644 "${CERT_DIR}/${TS_HOSTNAME}.crt"
chmod 0600 "${CERT_DIR}/${TS_HOSTNAME}.key"

# --- Cockpit (port 9090, bound to Tailscale IP) --------------------------
echo "==> Installing Cockpit"
apt-get install -y cockpit cockpit-storaged cockpit-networkmanager

echo "==> Binding Cockpit to ${TS_HOSTNAME}:${COCKPIT_PORT}"
# systemd ListenStream needs an IP, not an interface name.
COCKPIT_TS_IP="$(tailscale ip -4)"
[ -n "$COCKPIT_TS_IP" ] || { echo "ERROR: no Tailscale IPv4" >&2; exit 1; }
install -d -m 0755 /etc/systemd/system/cockpit.socket.d
cat > /etc/systemd/system/cockpit.socket.d/listen.conf <<EOF
[Socket]
ListenStream=
ListenStream=${COCKPIT_TS_IP}:${COCKPIT_PORT}
FreeBind=yes
EOF
chmod 0644 /etc/systemd/system/cockpit.socket.d/listen.conf

install -d -m 0755 /etc/cockpit
cat > /etc/cockpit/cockpit.conf <<EOF
[WebService]
Origins = https://${TS_HOSTNAME}:${COCKPIT_PORT}
ProtocolHeader = X-Forwarded-Proto
EOF
# No secrets here, and cockpit-ws may drop privileges before reading it.
chmod 0644 /etc/cockpit/cockpit.conf

install -d -m 0755 /etc/cockpit/ws-certs.d
cp "${CERT_DIR}/${TS_HOSTNAME}.crt" /etc/cockpit/ws-certs.d/50-tailscale.cert
cp "${CERT_DIR}/${TS_HOSTNAME}.key" /etc/cockpit/ws-certs.d/50-tailscale.key
# Trixie's Cockpit ships without a cockpit-ws group; root:root is correct then.
if getent group cockpit-ws >/dev/null 2>&1; then
    chown root:cockpit-ws /etc/cockpit/ws-certs.d/50-tailscale.*
else
    chown root:root /etc/cockpit/ws-certs.d/50-tailscale.*
fi
chmod 0640 /etc/cockpit/ws-certs.d/50-tailscale.*

systemctl daemon-reload
systemctl enable cockpit.socket
systemctl restart cockpit.socket

# --- MariaDB -------------------------------------------------------------
echo "==> Installing MariaDB"
apt-get install -y mariadb-server mariadb-client

# The config is written only if absent.  Re-running this script on a tuned
# host must not silently revert hand-adjusted sizing back to the defaults
# at the top of this file.
if [ -f "$MARIADB_CNF" ]; then
    echo "==> ${MARIADB_CNF} exists - leaving as-is (delete it to regenerate)"
else
    echo "==> Applying MariaDB tuning for Zabbix"
    cat > "$MARIADB_CNF" <<EOF
[mysqld]
bind-address                 = 127.0.0.1
skip-name-resolve
character-set-server         = utf8mb4
collation-server             = utf8mb4_bin
innodb_default_row_format    = dynamic
innodb_buffer_pool_size      = ${INNODB_BUFFER_POOL}
innodb_log_file_size         = ${INNODB_LOG_FILE}
innodb_flush_log_at_trx_commit = ${INNODB_FLUSH_LOG}
EOF
fi
# mysqld runs as user mysql and silently SKIPS config files it cannot read.
chmod 0644 "$MARIADB_CNF"

systemctl enable mariadb
systemctl restart mariadb

# Fail loudly if the tuning did not take - a 128M buffer pool means the
# config was ignored, and the only symptom otherwise is bad performance
# months later.
ACTUAL_POOL="$(mariadb -N -B -e "SELECT @@innodb_buffer_pool_size;" 2>/dev/null || echo 0)"
if [ "$ACTUAL_POOL" -le 134217728 ]; then
    echo "WARNING: innodb_buffer_pool_size is ${ACTUAL_POOL} bytes (default)." >&2
    echo "         ${MARIADB_CNF} is not being read - check permissions." >&2
fi

echo "==> Securing MariaDB"
mariadb --protocol=socket -uroot <<SQL
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${MARIADB_ROOT_PW}');
DELETE FROM mysql.global_priv WHERE User='';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

echo "==> Creating Zabbix database and user"
mariadb --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS ${ZABBIX_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${ZABBIX_DB_USER}'@'localhost' IDENTIFIED BY '${ZABBIX_DB_PW}';
GRANT ALL PRIVILEGES ON ${ZABBIX_DB_NAME}.* TO '${ZABBIX_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# --- Shared cert renewal (guarded; hooks no-op until their service exists) -
echo "==> Installing guarded cert renewal service + timer (${RENEW_UNIT})"
cat > "$RENEW_SH" <<EOF
#!/bin/bash
set -euo pipefail
CERT_DIR="${CERT_DIR}"
TS_HOSTNAME="${TS_HOSTNAME}"
cd "\$CERT_DIR"
/usr/bin/tailscale cert "\$TS_HOSTNAME"
chmod 0644 "\$CERT_DIR/\$TS_HOSTNAME.crt"
chmod 0600 "\$CERT_DIR/\$TS_HOSTNAME.key"
if [ -d /etc/cockpit/ws-certs.d ]; then
    cp "\$CERT_DIR/\$TS_HOSTNAME.crt" /etc/cockpit/ws-certs.d/50-tailscale.cert
    cp "\$CERT_DIR/\$TS_HOSTNAME.key" /etc/cockpit/ws-certs.d/50-tailscale.key
    if getent group cockpit-ws >/dev/null 2>&1; then
        chown root:cockpit-ws /etc/cockpit/ws-certs.d/50-tailscale.* || true
    else
        chown root:root /etc/cockpit/ws-certs.d/50-tailscale.* || true
    fi
    chmod 0640 /etc/cockpit/ws-certs.d/50-tailscale.*
    systemctl restart cockpit.socket || true
fi
if systemctl list-unit-files apache2.service >/dev/null 2>&1 \\
   && systemctl is-enabled apache2 >/dev/null 2>&1; then
    systemctl reload apache2 || systemctl restart apache2 || true
fi
if [ -d /etc/wazuh-dashboard/certs ] \\
   && systemctl list-unit-files wazuh-dashboard.service >/dev/null 2>&1; then
    cp "\$CERT_DIR/\$TS_HOSTNAME.crt" /etc/wazuh-dashboard/certs/tailscale.pem
    cp "\$CERT_DIR/\$TS_HOSTNAME.key" /etc/wazuh-dashboard/certs/tailscale-key.pem
    chown wazuh-dashboard:wazuh-dashboard /etc/wazuh-dashboard/certs/tailscale*.pem || true
    chmod 0400 /etc/wazuh-dashboard/certs/tailscale*.pem
    systemctl restart wazuh-dashboard || true
fi
EOF
chmod 0750 "$RENEW_SH"

cat > "/etc/systemd/system/${RENEW_UNIT}.service" <<EOF
[Unit]
Description=Renew shared Tailscale TLS certificate and redistribute (${SITE})
After=tailscaled.service
Wants=tailscaled.service

[Service]
Type=oneshot
ExecStart=${RENEW_SH}
EOF
chmod 0644 "/etc/systemd/system/${RENEW_UNIT}.service"

cat > "/etc/systemd/system/${RENEW_UNIT}.timer" <<EOF
[Unit]
Description=Daily Tailscale certificate renewal check (${SITE})

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
chmod 0644 "/etc/systemd/system/${RENEW_UNIT}.timer"

systemctl daemon-reload
systemctl enable "${RENEW_UNIT}.timer"
systemctl start "${RENEW_UNIT}.timer"

cat <<EOF

===========================================================
Stage 1 complete.  (site: ${SITE})
  Cockpit    https://${TS_HOSTNAME}:${COCKPIT_PORT}
  MariaDB    127.0.0.1:3306 (loopback, tuned for Zabbix)
             buffer pool ${INNODB_BUFFER_POOL} / log ${INNODB_LOG_FILE}
  Zabbix DB  ${ZABBIX_DB_NAME} / user ${ZABBIX_DB_USER}
  Cert       ${CERT_DIR}/${TS_HOSTNAME}.crt (shared)
  Renewal    ${RENEW_UNIT}.timer (guarded)
Credentials in ${CRED_FILE} (mode 0600).
Next: 02-zabbix-server.sh
===========================================================
EOF
