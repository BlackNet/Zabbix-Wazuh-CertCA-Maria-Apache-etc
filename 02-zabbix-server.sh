#!/bin/bash
#
# Stage 2: Zabbix 7.4 server + frontend (Apache) + agent2 + landing page
# Debian 13 (Trixie).  Requires stage 1.  Run as root.  Idempotent.
#
set -euo pipefail

# ###########################################################################
# ##  EDIT PER SITE  ########################################################
# ###########################################################################
TS_HOSTNAME="ssgc.taile9333.ts.net"     # this node's MagicDNS FQDN
ZABBIX_TIMEZONE="America/New_York"       # PHP/Zabbix timezone (Eastern here)
# ###########################################################################

# --- Derived / usually leave alone ---------------------------------------
SITE="$(echo "$TS_HOSTNAME" | cut -d. -f1)"
SITE_UP="$(echo "$SITE" | tr '[:lower:]' '[:upper:]')"   # visible Zabbix name
CRED_FILE="/root/.${SITE}-credentials"
CERT_DIR="/etc/ssl/tailscale"

ZABBIX_MAJOR="7.4"
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

# --- APT pin: force zabbix* from upstream, ends the 7.0-vs-7.4 fight -----
echo "==> Pinning zabbix* packages to repo.zabbix.com"
cat > /etc/apt/preferences.d/99-zabbix-upstream <<'PINEOF'
Package: zabbix*
Pin: origin "repo.zabbix.com"
Pin-Priority: 1001
PINEOF

apt-get update

echo "==> Verifying candidate resolves to upstream ${ZABBIX_MAJOR}"
if apt-cache policy zabbix-server-mysql | awk '/Candidate:/{print $2}' | grep -q "${ZABBIX_MAJOR}\."; then
    CANDVER="$(apt-cache policy zabbix-server-mysql | awk '/Candidate:/{print $2}')"
    echo "    OK - candidate ${CANDVER}"
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
    mariadb --protocol=socket -uroot -e "SET GLOBAL log_bin_trust_function_creators = 1;"
    if ! zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz \
        | mariadb --default-character-set=utf8mb4 \
            -u"${ZABBIX_DB_USER}" -p"${ZABBIX_DB_PW}" "${ZABBIX_DB_NAME}"; then
        mariadb --protocol=socket -uroot -e "SET GLOBAL log_bin_trust_function_creators = 0;"
        echo "ERROR: schema import failed" >&2; exit 1
    fi
    mariadb --protocol=socket -uroot -e "SET GLOBAL log_bin_trust_function_creators = 0;"
else
    echo "==> Schema already present (${TABLE_COUNT} tables) - skipping"
fi

# --- Zabbix server config ------------------------------------------------
echo "==> Configuring zabbix_server.conf"
if grep -q '^DBPassword=' /etc/zabbix/zabbix_server.conf; then
    sed -i "s|^DBPassword=.*|DBPassword=${ZABBIX_DB_PW}|" /etc/zabbix/zabbix_server.conf
elif grep -q '^# DBPassword=' /etc/zabbix/zabbix_server.conf; then
    sed -i "s|^# DBPassword=.*|DBPassword=${ZABBIX_DB_PW}|" /etc/zabbix/zabbix_server.conf
else
    echo "DBPassword=${ZABBIX_DB_PW}" >> /etc/zabbix/zabbix_server.conf
fi
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
cat > /etc/apache2/ports.conf <<PORTSEOF
Listen ${TS_IP4}:80
Listen ${TS_IP4}:443
PORTSEOF
cat > "$APACHE_VHOST" <<VHOSTEOF
<VirtualHost ${TS_IP4}:80>
    ServerName ${TS_HOSTNAME}
    Redirect permanent / https://${TS_HOSTNAME}/
</VirtualHost>

<VirtualHost ${TS_IP4}:443>
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

# --- Agent2 --------------------------------------------------------------
echo "==> Configuring zabbix-agent2"
sed -i 's|^Server=.*|Server=127.0.0.1|'             /etc/zabbix/zabbix_agent2.conf
sed -i 's|^ServerActive=.*|ServerActive=127.0.0.1|' /etc/zabbix/zabbix_agent2.conf
sed -i "s|^Hostname=.*|Hostname=${ZABBIX_SERVER_NAME}|" /etc/zabbix/zabbix_agent2.conf

# --- Start services ------------------------------------------------------
echo "==> Starting services"
systemctl enable zabbix-server zabbix-agent2 apache2
systemctl restart zabbix-server zabbix-agent2 apache2
sleep 3
systemctl is-active --quiet zabbix-server || {
    echo "WARNING: zabbix-server not active. Check:" >&2
    echo "  journalctl -u zabbix-server -n 50 --no-pager" >&2
    echo "  tail -50 /var/log/zabbix/zabbix_server.log" >&2
}

cat <<DONEEOF

===========================================================
Stage 2 complete.  (site: ${SITE})
  Landing   https://${TS_HOSTNAME}/
  Zabbix    https://${TS_HOSTNAME}/zabbix
  Login     Admin / zabbix     <-- CHANGE IMMEDIATELY
Next: 03-wazuh-allinone.sh  (Wazuh on :${WAZUH_PORT})
===========================================================
DONEEOF