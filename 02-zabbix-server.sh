#!/bin/bash
#
# Stage 2: Zabbix server + frontend (Apache) + agent2 + landing page
# Debian 13 (Trixie).  Requires stage 1.  Run as root.  Idempotent.
#
set -euo pipefail

# ###########################################################################
# ##  EDIT PER SITE  ########################################################
# ###########################################################################
TS_HOSTNAME="monitor.example.ts.net"    # this node's MagicDNS FQDN
ZABBIX_TIMEZONE="America/New_York"       # PHP/Zabbix timezone
ZABBIX_MAJOR="8.0"                       # 8.0 LTS track

# Address Apache binds for the Zabbix UI / landing page.
#   "tailscale"  - Tailscale IP only.  UI unreachable from the LAN; correct
#                  for sites administered entirely over the tailnet.
#   "all"        - 0.0.0.0.  Needed when on-site staff open the UI from the
#                  plant/office LAN.  The TLS cert is a Tailscale cert, so
#                  LAN users will see a name mismatch unless they reach the
#                  box by its MagicDNS name.
#   <literal IP> - bind one specific address.
APACHE_BIND="tailscale"
# ###########################################################################
#
# NOTE ON 8.0 AND CHANNELS
# The zabbix-release deb enables both 8.0/release (the GA shelf) and
# 8.0/unstable (serving pre-release builds).  The APT pin below covers
# repo.zabbix.com broadly, so apt simply picks the highest version across
# both channels.  When 8.0.0 GA publishes to the release channel, a plain
# 'apt update && apt upgrade' moves you to it - the tilde in '8.0.0~beta2'
# sorts BELOW '8.0.0', so GA wins automatically.  No repo edits, no
# un-pinning, no hoops.
#
# As of this writing 8.0 has not reached GA and the candidate resolves to a
# pre-release build.  The script prints the resolved version and warns; if
# you need a stable release today, set ZABBIX_MAJOR="7.4".  Note that the
# Zabbix schema upgrades one-way: a database created or upgraded by 8.0
# cannot be served by a 7.x binary.
#

# --- Derived / usually leave alone ---------------------------------------
SITE="$(echo "$TS_HOSTNAME" | cut -d. -f1)"
SITE_UP="$(echo "$SITE" | tr '[:lower:]' '[:upper:]')"   # visible Zabbix name
CRED_FILE="/root/.${SITE}-credentials"
CERT_DIR="/etc/ssl/tailscale"

DEB_VER="debian13"
ZABBIX_RELEASE_DEB="zabbix-release_latest_${ZABBIX_MAJOR}+${DEB_VER}_all.deb"
ZABBIX_RELEASE_URL="https://repo.zabbix.com/zabbix/${ZABBIX_MAJOR}/release/debian/pool/main/z/zabbix-release/${ZABBIX_RELEASE_DEB}"

ZABBIX_SERVER_NAME="${SITE_UP}"
APACHE_VHOST="/etc/apache2/sites-available/${SITE}-ssl.conf"
WEBROOT="/var/www/${SITE}"
WAZUH_PORT="444"
COCKPIT_PORT="9090"

export DEBIAN_FRONTEND=noninteractive

# --- Preflight -----------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then echo "ERROR: must run as root" >&2; exit 1; fi
if [ ! -f "$CRED_FILE" ]; then echo "ERROR: $CRED_FILE not found - run 01 first" >&2; exit 1; fi
. "$CRED_FILE"
if [ ! -s "${CERT_DIR}/${TS_HOSTNAME}.crt" ]; then echo "ERROR: TLS cert missing" >&2; exit 1; fi
TS_IP4="$(tailscale ip -4)"
if [ -z "$TS_IP4" ]; then echo "ERROR: no Tailscale IPv4" >&2; exit 1; fi

# Resolve APACHE_BIND to the address Listen/VirtualHost will use.
case "$APACHE_BIND" in
    tailscale) BIND_ADDR="$TS_IP4" ;;
    all)       BIND_ADDR="0.0.0.0" ;;
    *)         BIND_ADDR="$APACHE_BIND" ;;
esac
echo "==> Apache will bind ${BIND_ADDR} (APACHE_BIND=${APACHE_BIND})"

# --- Apache + PHP (explicit) ---------------------------------------------
echo "==> Installing Apache and PHP explicitly"
apt-get update
apt-get install -y apache2 libapache2-mod-php php php-mysql php-gd \
    php-bcmath php-mbstring php-xml php-ldap php-curl

# --- Zabbix repository (fixed _latest_ filename, not a dir scrape) -------
echo "==> Fetching ${ZABBIX_RELEASE_DEB}"
TMPDEB="$(mktemp --suffix=.deb)"
trap 'rm -f "$TMPDEB"' EXIT
if ! curl -fSL -o "$TMPDEB" "${ZABBIX_RELEASE_URL}"; then
    echo "ERROR: could not download zabbix-release from ${ZABBIX_RELEASE_URL}" >&2; exit 1
fi
if ! dpkg-deb --info "$TMPDEB" >/dev/null 2>&1; then
    echo "ERROR: downloaded file is not a valid Debian package" >&2
    head -c 200 "$TMPDEB" >&2; exit 1
fi
dpkg -i "$TMPDEB"

# The 8.0 release deb manages zabbix-release/-tools/-unstable .sources, but a
# prior 7.x install leaves an orphaned zabbix.sources behind that it does not
# own.  Remove it so only the current deb's sources are active.
if [ -f /etc/apt/sources.list.d/zabbix.sources ]; then
    echo "==> Removing orphaned zabbix.sources from a prior release"
    rm -f /etc/apt/sources.list.d/zabbix.sources
fi

# --- APT pin -------------------------------------------------------------
# Purpose: keep Debian's bundled zabbix (7.0, priority 500) from ever winning.
# It deliberately does NOT lock a channel or version - every repo.zabbix.com
# source gets 1001, so apt freely picks the highest version available.  That
# means 'apt update && apt upgrade' carries beta -> GA with no intervention.
echo "==> Pinning zabbix* packages to repo.zabbix.com"
cat > /etc/apt/preferences.d/99-zabbix-upstream <<'PINEOF'
Package: zabbix*
Pin: origin "repo.zabbix.com"
Pin-Priority: 1001
PINEOF
chmod 0644 /etc/apt/preferences.d/99-zabbix-upstream

apt-get update

echo "==> Verifying candidate resolves to upstream ${ZABBIX_MAJOR}"
CANDVER="$(apt-cache policy zabbix-server-mysql | awk '/Candidate:/{print $2}')"
# Accepts 8.0.0~beta2 now and plain 8.0.x at GA - both match "8.0".
if echo "$CANDVER" | grep -q "${ZABBIX_MAJOR}\."; then
    echo "    OK - candidate ${CANDVER}"
    case "$CANDVER" in
        *~alpha*|*~beta*|*~rc*)
            echo "    NOTE: this is a PRE-RELEASE build. GA will supersede it"
            echo "          automatically on a later 'apt upgrade'."
            echo "          The Zabbix schema upgrades one-way - take a dump"
            echo "          before any major-version start." ;;
    esac
else
    echo "ERROR: candidate is not upstream ${ZABBIX_MAJOR}:" >&2
    apt-cache policy zabbix-server-mysql >&2; exit 1
fi

# --- Zabbix packages -----------------------------------------------------
echo "==> Installing Zabbix server, frontend, agent2"
apt-get install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf \
    zabbix-sql-scripts zabbix-agent2 zabbix-agent2-plugin-mongodb \
    zabbix-agent2-plugin-mssql zabbix-agent2-plugin-postgresql

# --- Schema import (only if empty) ---------------------------------------
TABLE_COUNT="$(mariadb --protocol=socket -uroot -N -B -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${ZABBIX_DB_NAME}';")"
if [ "$TABLE_COUNT" -eq 0 ]; then
    echo "==> Importing Zabbix schema"
    echo "    (slow on spinning disks - watch the table count from another"
    echo "     shell if you need reassurance it is progressing)"
    mariadb --protocol=socket -uroot -e "SET GLOBAL log_bin_trust_function_creators = 1;"
    if ! zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz \
        | mariadb --default-character-set=utf8mb4 \
            -u"${ZABBIX_DB_USER}" -p"${ZABBIX_DB_PW}" "${ZABBIX_DB_NAME}"; then
        mariadb --protocol=socket -uroot -e "SET GLOBAL log_bin_trust_function_creators = 0;"
        echo "ERROR: schema import failed" >&2; exit 1
    fi
    mariadb --protocol=socket -uroot -e "SET GLOBAL log_bin_trust_function_creators = 0;"

    # The stock schema names its self-monitoring host "Zabbix server", but
    # the agent2 config below announces itself as ${SITE_UP}.  Without this
    # rename the server logs 'host not found' for every heartbeat and active
    # check request.  Guarded inside the fresh-import branch so a restored
    # or migrated database is never touched.
    echo "==> Renaming built-in host 'Zabbix server' -> ${SITE_UP}"
    mariadb --protocol=socket -uroot "${ZABBIX_DB_NAME}" <<SQL
UPDATE hosts SET host='${SITE_UP}', name='${SITE_UP}'
 WHERE host='Zabbix server';
SQL
else
    echo "==> Schema already present (${TABLE_COUNT} tables) - skipping import"
    echo "    NOTE: not renaming the self-monitoring host on an existing"
    echo "          database.  If agent2 logs 'host [${SITE_UP}] not found',"
    echo "          either rename the host in the UI or set Hostname= in"
    echo "          /etc/zabbix/zabbix_agent2.conf to match it."
fi

# --- Zabbix server config ------------------------------------------------
# set_conf <file> <key> <value> - handles set, commented-out, and absent.
set_conf() {
    local f="$1" k="$2" v="$3"
    if grep -q "^${k}=" "$f"; then
        sed -i "s|^${k}=.*|${k}=${v}|" "$f"
    elif grep -q "^# *${k}=" "$f"; then
        sed -i "s|^# *${k}=.*|${k}=${v}|" "$f"
    else
        echo "${k}=${v}" >> "$f"
    fi
}

echo "==> Configuring zabbix_server.conf"
# DBName/DBUser are set explicitly rather than relying on the package
# defaults - stage 1 exposes them as variables, so they can legitimately
# differ from 'zabbix'.
set_conf /etc/zabbix/zabbix_server.conf DBName     "${ZABBIX_DB_NAME}"
set_conf /etc/zabbix/zabbix_server.conf DBUser     "${ZABBIX_DB_USER}"
set_conf /etc/zabbix/zabbix_server.conf DBPassword "${ZABBIX_DB_PW}"
chown root:zabbix /etc/zabbix/zabbix_server.conf
chmod 0640 /etc/zabbix/zabbix_server.conf

# --- Frontend config -----------------------------------------------------
echo "==> Writing frontend zabbix.conf.php"
install -d -m 0755 /etc/zabbix/web
cat > /etc/zabbix/web/zabbix.conf.php <<PHPEOF
<?php
\$DB['TYPE']      = 'MYSQL';
\$DB['SERVER']    = 'localhost';
\$DB['PORT']      = '0';
\$DB['DATABASE']  = '${ZABBIX_DB_NAME}';
\$DB['USER']      = '${ZABBIX_DB_USER}';
\$DB['PASSWORD']  = '${ZABBIX_DB_PW}';
\$DB['SCHEMA']    = '';
\$DB['ENCRYPTION']= false;
\$DB['VAULT']     = '';
\$DB['DOUBLE_IEEE754'] = true;
\$ZBX_SERVER_NAME = '${ZABBIX_SERVER_NAME}';
\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
PHPEOF
chown www-data:www-data /etc/zabbix/web/zabbix.conf.php
chmod 0640 /etc/zabbix/web/zabbix.conf.php

# --- PHP timezone (Trixie ships PHP 8.4) ---------------------------------
echo "==> Setting PHP timezone -> ${ZABBIX_TIMEZONE}"
PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_INI="/etc/php/${PHP_VER}/apache2/php.ini"
if [ -f "$PHP_INI" ]; then
    if grep -q '^;\?date.timezone' "$PHP_INI"; then
        sed -i "s|^;\?date.timezone.*|date.timezone = ${ZABBIX_TIMEZONE}|" "$PHP_INI"
    else
        echo "date.timezone = ${ZABBIX_TIMEZONE}" >> "$PHP_INI"
    fi
else
    echo "WARNING: ${PHP_INI} not found - set date.timezone manually" >&2
fi

# --- Landing page --------------------------------------------------------
echo "==> Deploying landing page"
install -d -m 0755 "$WEBROOT"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/index.html" ]; then
    sed -e "s|@@HOST@@|${TS_HOSTNAME}|g" \
        -e "s|@@WAZUH_PORT@@|${WAZUH_PORT}|g" \
        -e "s|@@COCKPIT_PORT@@|${COCKPIT_PORT}|g" \
        "${SCRIPT_DIR}/index.html" > "${WEBROOT}/index.html"
else
    cat > "${WEBROOT}/index.html" <<HTMLEOF
<!doctype html><meta charset="utf-8"><title>${SITE_UP}</title>
<h1>${SITE_UP}</h1>
<ul>
<li><a href="https://${TS_HOSTNAME}/zabbix">Zabbix</a></li>
<li><a href="https://${TS_HOSTNAME}:${WAZUH_PORT}">Wazuh</a></li>
<li><a href="https://${TS_HOSTNAME}:${COCKPIT_PORT}">Cockpit</a></li>
</ul>
HTMLEOF
fi
chown -R www-data:www-data "$WEBROOT"

# --- Apache vhost --------------------------------------------------------
echo "==> Configuring Apache vhost"
a2enmod ssl headers rewrite alias

# ports.conf is a dpkg conffile.  Keep the packaged original the first time
# it is replaced so the upgrade prompt on future apache2 updates can be
# answered from evidence rather than memory.
if [ -f /etc/apache2/ports.conf ] && [ ! -f /etc/apache2/ports.conf.dpkg-orig ]; then
    cp -a /etc/apache2/ports.conf /etc/apache2/ports.conf.dpkg-orig
    echo "    (original ports.conf saved as ports.conf.dpkg-orig)"
fi
cat > /etc/apache2/ports.conf <<PORTSEOF
Listen ${BIND_ADDR}:80
Listen ${BIND_ADDR}:443
PORTSEOF

cat > "$APACHE_VHOST" <<VHOSTEOF
<VirtualHost ${BIND_ADDR}:80>
    ServerName ${TS_HOSTNAME}
    Redirect permanent / https://${TS_HOSTNAME}/
</VirtualHost>

<VirtualHost ${BIND_ADDR}:443>
    ServerName ${TS_HOSTNAME}
    DocumentRoot ${WEBROOT}

    SSLEngine on
    SSLCertificateFile      ${CERT_DIR}/${TS_HOSTNAME}.crt
    SSLCertificateKeyFile   ${CERT_DIR}/${TS_HOSTNAME}.key
    SSLProtocol             -all +TLSv1.2 +TLSv1.3
    SSLHonorCipherOrder     off
    SSLSessionTickets       off

    Header always set Strict-Transport-Security "max-age=63072000"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"

    Alias /zabbix /usr/share/zabbix/ui
    <Directory /usr/share/zabbix/ui>
        Options FollowSymLinks
        AllowOverride None
        Require all granted
        DirectoryIndex index.php
    </Directory>

    ErrorLog  \${APACHE_LOG_DIR}/${SITE}-error.log
    CustomLog \${APACHE_LOG_DIR}/${SITE}-access.log combined
</VirtualHost>
VHOSTEOF
a2ensite "${SITE}-ssl"
a2dissite 000-default 2>/dev/null || true
a2disconf zabbix 2>/dev/null || true
apache2ctl configtest

# --- Boot ordering: Apache binds the Tailscale IP, which does not exist
# until tailscaled is up.  Without this, apache2 fails at boot.
echo "==> Allowing bind to not-yet-present addresses (ip_nonlocal_bind)"
cat > /etc/sysctl.d/99-nonlocal-bind.conf <<'SYSCTLEOF'
# Let services bind an address before the interface is up (Tailscale IP at
# boot).  Cockpit's socket uses FreeBind=yes for the same reason; Apache and
# the Wazuh dashboard have no equivalent, so this is set kernel-wide.
# NOTE: this is a host-wide relaxation - record it in your config baseline
# if the box is subject to a hardening audit.
net.ipv4.ip_nonlocal_bind = 1
SYSCTLEOF
chmod 0644 /etc/sysctl.d/99-nonlocal-bind.conf
sysctl -q -p /etc/sysctl.d/99-nonlocal-bind.conf

echo "==> Ordering apache2 after tailscaled"
install -d -m 0755 /etc/systemd/system/apache2.service.d
cat > /etc/systemd/system/apache2.service.d/tailscale.conf <<'APEOF'
[Unit]
After=tailscaled.service network-online.target
Wants=tailscaled.service network-online.target
APEOF
chmod 0644 /etc/systemd/system/apache2.service.d/tailscale.conf
systemctl daemon-reload

# --- Agent2 --------------------------------------------------------------
echo "==> Configuring zabbix-agent2"
set_conf /etc/zabbix/zabbix_agent2.conf Server       "127.0.0.1"
set_conf /etc/zabbix/zabbix_agent2.conf ServerActive "127.0.0.1"
set_conf /etc/zabbix/zabbix_agent2.conf Hostname     "${ZABBIX_SERVER_NAME}"

# --- Start services ------------------------------------------------------
echo "==> Starting services"
systemctl enable zabbix-server zabbix-agent2 apache2
systemctl restart zabbix-server zabbix-agent2 apache2

# Zabbix 8.0 takes longer than a few seconds to come up, especially on
# rotational storage - poll rather than sleeping a fixed interval.
echo "==> Waiting for zabbix-server to bind :10051"
for _ in $(seq 1 30); do
    ss -lnt 2>/dev/null | grep -q ':10051 ' && break
    sleep 2
done
if ! systemctl is-active --quiet zabbix-server; then
    echo "WARNING: zabbix-server not active. Check:" >&2
    echo "  journalctl -u zabbix-server -n 50 --no-pager" >&2
    echo "  tail -50 /var/log/zabbix/zabbix_server.log" >&2
elif ! ss -lnt 2>/dev/null | grep -q ':10051 '; then
    echo "WARNING: zabbix-server is running but :10051 is not listening yet." >&2
    echo "  tail -50 /var/log/zabbix/zabbix_server.log" >&2
fi

cat <<DONEEOF

===========================================================
Stage 2 complete.  (site: ${SITE})
  Version   ${CANDVER}
  Landing   https://${TS_HOSTNAME}/
  Zabbix    https://${TS_HOSTNAME}/zabbix
  Bind      ${BIND_ADDR} (APACHE_BIND=${APACHE_BIND})
  Login     Admin / zabbix     <-- CHANGE IMMEDIATELY
Next: 03-wazuh-allinone.sh  (Wazuh on :${WAZUH_PORT})

Restarting MariaDB stops zabbix-server too (the HA manager stands the
node down when the database goes away).  Stop zabbix-server first, then
restart MariaDB, then start zabbix-server.
===========================================================
DONEEOF
