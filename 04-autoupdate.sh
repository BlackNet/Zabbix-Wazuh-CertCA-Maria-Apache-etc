#!/bin/bash
#
# Stage 4: unattended security updates + mail relay + AppArmor status
# Debian 13 (Trixie).  Run as root.  Idempotent - safe to re-run.
#
# Run order: 01 -> 02 -> 03 -> 04.  Nothing here depends on stages 1-3, so it
# is equally safe on a plain Debian box (Loki, Spartan, a sensor node) that
# never ran the monitoring stack.
#
# SCOPE: Debian security updates only.  The Zabbix, Wazuh and Smallstep
# repositories are deliberately EXCLUDED - see the Origins-Pattern and
# Package-Blacklist below for why.
#
# This script never reboots and never configures automatic reboots.
#
set -euo pipefail

# ###########################################################################
# ##  EDIT PER SITE  ########################################################
# ###########################################################################
TS_HOSTNAME="monitor.example.ts.net"    # this node's MagicDNS FQDN

# --- Where update / smartd / cron mail goes -------------------------------
MAIL_TO="admin@example.com"              # destination for all system mail
MAIL_RELAY="mail.example.com"            # smarthost to relay through
MAIL_PORT="587"                          # 587 submission, 465 smtps, 25 plain
MAIL_TLS="on"                            # on | off
MAIL_STARTTLS="on"                       # on for 587, off for 465 and 25
MAIL_FROM=""                             # blank = <site>@<relay domain>

# Relay authentication.  Leave MAIL_AUTH_USER blank for an unauthenticated
# relay (e.g. a smarthost that accepts by source IP or over a tailnet).
# The password is NEVER placed in this script - point MAIL_AUTH_PASS_FILE at
# a root-only file containing it on a single line.
MAIL_AUTH_USER=""
MAIL_AUTH_PASS_FILE=""                   # e.g. /root/.msmtp-relay-pass

# --- Section toggles ------------------------------------------------------
DO_MAIL="yes"                            # msmtp + msmtp-mta as the sendmail
DO_UNATTENDED="yes"                      # unattended-upgrades
DO_APPARMOR="yes"                        # verify/report only, changes nothing

# Reboot policy.  Left as a variable so the choice is explicit and auditable,
# but "false" is the only value this script is written to defend: a monitoring
# host that reboots itself at 04:00 takes the entire fleet's visibility with
# it, and does so at the hour nobody is watching.  Set the reboot window in
# your change process, not here.
UNATTENDED_REBOOT="false"
# ###########################################################################

# --- Derived / usually leave alone ---------------------------------------
SITE="$(echo "$TS_HOSTNAME" | cut -d. -f1)"
export DEBIAN_FRONTEND=noninteractive
die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "    WARNING: $*" >&2; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
grep -q 'VERSION_CODENAME=trixie' /etc/os-release || die "targets Debian 13 (trixie)"

echo "==> Stage 4 on ${SITE} (mail -> ${MAIL_TO} via ${MAIL_RELAY}:${MAIL_PORT})"

# ===========================================================================
# Mail relay (msmtp)
# ===========================================================================
if [ "$DO_MAIL" = "yes" ]; then
    echo "==> Installing msmtp + msmtp-mta"
    # msmtp-mta provides /usr/sbin/sendmail, which is what unattended-upgrades,
    # smartd and cron actually call.  Without it they fail silently.
    apt-get install -y msmtp msmtp-mta bsd-mailx

    [ -n "$MAIL_FROM" ] || MAIL_FROM="${SITE}@${MAIL_RELAY#*.}"

    MSMTP_AUTH_BLOCK=""
    if [ -n "$MAIL_AUTH_USER" ]; then
        [ -n "$MAIL_AUTH_PASS_FILE" ] || die "MAIL_AUTH_USER set but MAIL_AUTH_PASS_FILE is empty"
        [ -s "$MAIL_AUTH_PASS_FILE" ] || die "MAIL_AUTH_PASS_FILE ($MAIL_AUTH_PASS_FILE) missing or empty"
        chmod 0600 "$MAIL_AUTH_PASS_FILE"
        MSMTP_AUTH_BLOCK="auth           on
user           ${MAIL_AUTH_USER}
passwordeval   cat ${MAIL_AUTH_PASS_FILE}"
    else
        MSMTP_AUTH_BLOCK="auth           off"
    fi

    cat > /etc/msmtprc <<EOF
# Managed by 04-autoupdate.sh - regenerated on each run.
defaults
port           ${MAIL_PORT}
tls            ${MAIL_TLS}
tls_starttls   ${MAIL_STARTTLS}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        ${SITE}
host           ${MAIL_RELAY}
from           ${MAIL_FROM}
${MSMTP_AUTH_BLOCK}

account default : ${SITE}
EOF
    # msmtp refuses to run if a config containing a password is group- or
    # world-readable.  0600 also means only root-initiated mail works, which
    # covers unattended-upgrades, smartd and root's cron - the senders that
    # matter here.
    chown root:root /etc/msmtprc
    chmod 0600 /etc/msmtprc
    : > /var/log/msmtp.log
    chmod 0640 /var/log/msmtp.log

    # Route root's mail onward rather than letting it pool locally unread.
    if [ -f /etc/aliases ]; then
        sed -i '/^root:/d' /etc/aliases
    fi
    echo "root: ${MAIL_TO}" >> /etc/aliases

    cat > /etc/logrotate.d/msmtp <<'EOF'
/var/log/msmtp.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF
    chmod 0644 /etc/logrotate.d/msmtp
    echo "    msmtp configured (from ${MAIL_FROM})"
fi

# ===========================================================================
# Unattended upgrades
# ===========================================================================
if [ "$DO_UNATTENDED" = "yes" ]; then
    echo "==> Installing unattended-upgrades"
    apt-get install -y unattended-upgrades apt-listchanges

    # Origins-Pattern below admits ONLY the Debian security suites.  Third
    # party repositories are excluded by omission, deliberately:
    #   zabbix   - the APT pin tracks the highest available version, which on
    #              a pre-release channel means an unattended beta bump on the
    #              host monitoring the whole fleet.
    #   wazuh    - a manager version bump can require matching agent updates
    #              across the estate; that is a planned change, not a 4am one.
    #   step-ca  - small package, but it is the CA.
    #   mariadb  - Debian's own security updates for it ARE admitted (they
    #              come from the security suite); upstream MariaDB repos, if
    #              ever added, would not be.
    # The Package-Blacklist is belt-and-braces: it makes the intent explicit
    # to anyone reading the config, and holds even if an origin is added later.
    echo "==> Writing /etc/apt/apt.conf.d/50unattended-upgrades"
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
// Managed by 04-autoupdate.sh - regenerated on each run.

Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=\${distro_codename},label=Debian-Security";
        "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
};

// Never auto-upgrade the monitoring stack or the CA.
Unattended-Upgrade::Package-Blacklist {
        "^zabbix";
        "^wazuh";
        "^step-ca";
        "^filebeat";
        "^opensearch";
};

// Keep /boot from filling with old kernels.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";

// Mail on change only - a nightly "nothing to do" message trains you to
// ignore the sender, which is the opposite of what an alert is for.
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailReport "on-change";

// Retry a failed unattended run once on the next cycle rather than waiting
// a full day.
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";

// This host does not reboot itself.  See UNATTENDED_REBOOT in the script.
Unattended-Upgrade::Automatic-Reboot "${UNATTENDED_REBOOT}";

// Conffile handling: keep the local version and report the conflict rather
// than silently overwriting.  Several files here are hand-tuned
// (ports.conf, 99-<site>.cnf, opensearch_dashboards.yml).
Dpkg::Options {
        "--force-confdef";
        "--force-confold";
};
EOF
    chmod 0644 /etc/apt/apt.conf.d/50unattended-upgrades

    echo "==> Writing /etc/apt/apt.conf.d/20auto-upgrades"
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Managed by 04-autoupdate.sh - regenerated on each run.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    chmod 0644 /etc/apt/apt.conf.d/20auto-upgrades

    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
    systemctl enable unattended-upgrades >/dev/null 2>&1 || true

    # -------------------------------------------------------------------
    # network-online.target
    # -------------------------------------------------------------------
    # apt-daily.service and apt-daily-upgrade.service order themselves After=
    # network-online.target.  If the active network stack's wait-online unit
    # never reaches "online", that target is never hit and the timers fire
    # into a dependency that is still waiting - so the upgrade silently never
    # runs.  The usual cause is systemd-networkd being enabled with no .network
    # files (nothing to wait for, so it waits the full timeout and fails).
    echo "==> Checking network-online.target reachability"
    NETSTACK=""
    for u in NetworkManager systemd-networkd networking; do
        if systemctl is-active --quiet "$u" 2>/dev/null; then
            NETSTACK="${NETSTACK}${NETSTACK:+, }${u}"
        fi
    done
    echo "    active network stack: ${NETSTACK:-none detected}"

    if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        if ! ls /etc/systemd/network/*.network >/dev/null 2>&1; then
            warn "systemd-networkd is active but /etc/systemd/network/ has no"
            warn ".network files - systemd-networkd-wait-online will time out"
            warn "and apt-daily-upgrade will never run.  Masking that unit."
            systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 || true
        fi
    fi

    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        if systemctl is-enabled --quiet NetworkManager-wait-online.service 2>/dev/null; then
            echo "    NetworkManager-wait-online is enabled (expected)"
        else
            warn "NetworkManager is active but NetworkManager-wait-online is not"
            warn "enabled - network-online.target may never be reached."
            warn "Enable it with: systemctl enable NetworkManager-wait-online.service"
        fi
    fi

    if ! systemctl is-active --quiet network-online.target 2>/dev/null; then
        warn "network-online.target is not currently active.  Verify after the"
        warn "next reboot with: systemctl status network-online.target"
    fi
fi

# ===========================================================================
# AppArmor (verify and report - this section changes nothing)
# ===========================================================================
if [ "$DO_APPARMOR" = "yes" ]; then
    echo "==> AppArmor status"
    # Debian has shipped AppArmor enabled by default since Buster, so this is
    # a verification step rather than an install.  Profiles are deliberately
    # NOT moved into enforce mode here: MariaDB, Apache and the OpenSearch JVM
    # all touch paths that stock profiles do not anticipate (a relocated
    # datadir, an NVMe-mounted index store), and flipping them to enforce
    # unattended is a good way to break a working stack at 4am.  Promote
    # individual profiles deliberately, after time in complain mode.
    apt-get install -y apparmor apparmor-utils

    if ! systemctl is-active --quiet apparmor 2>/dev/null; then
        warn "apparmor.service is not active"
    fi

    if [ -d /sys/kernel/security/apparmor ]; then
        echo "    kernel support: present"
        if command -v aa-status >/dev/null 2>&1; then
            AA_ENF="$(aa-status --enforced 2>/dev/null || echo '?')"
            AA_CMP="$(aa-status --complaining 2>/dev/null || echo '?')"
            echo "    profiles enforcing:  ${AA_ENF}"
            echo "    profiles complaining: ${AA_CMP}"
            echo "    (full detail: aa-status)"
        fi
    else
        warn "AppArmor not enabled in the running kernel."
        warn "Add 'apparmor=1 security=apparmor' to GRUB_CMDLINE_LINUX in"
        warn "/etc/default/grub, run update-grub, and reboot when convenient."
    fi
fi

# ===========================================================================
# Verification
# ===========================================================================
echo "==> Verification"

if [ "$DO_MAIL" = "yes" ]; then
    echo "    Sending test message to ${MAIL_TO}"
    if printf 'Subject: [%s] stage 4 test\n\nMail relay configured %s.\nRelay: %s:%s\n' \
        "$SITE" "$(date -Iseconds)" "$MAIL_RELAY" "$MAIL_PORT" \
        | /usr/sbin/sendmail -t "$MAIL_TO" 2>/dev/null; then
        echo "    sendmail accepted the message - confirm it ARRIVED before"
        echo "    trusting any of the alerting below.  On failure, check:"
        echo "      tail /var/log/msmtp.log"
    else
        warn "sendmail rejected the test message - check /var/log/msmtp.log"
    fi
fi

if [ "$DO_UNATTENDED" = "yes" ]; then
    echo "    Dry-run (no packages will be installed):"
    unattended-upgrade --dry-run 2>&1 | sed 's/^/      /' || \
        warn "dry-run reported a problem - investigate before relying on this"
    echo
    echo "    Timers:"
    systemctl list-timers --no-pager 'apt-daily*' 2>/dev/null | sed 's/^/      /'
fi

cat <<EOF

===========================================================
Stage 4 complete.  (site: ${SITE})
  Mail       ${MAIL_TO} via ${MAIL_RELAY}:${MAIL_PORT}
  Updates    Debian security suite only
  Excluded   zabbix, wazuh, step-ca, filebeat, opensearch
  Reboot     automatic reboot = ${UNATTENDED_REBOOT}

  CONFIRM THE TEST MAIL ARRIVED.  Everything else here reports
  by mail; if that path is broken the box will fail quietly.

  Useful checks:
    unattended-upgrade --dry-run --debug
    systemctl list-timers 'apt-daily*'
    tail /var/log/unattended-upgrades/unattended-upgrades.log
    tail /var/log/msmtp.log
    aa-status

  Not included yet - smartd, auditd, backups.
===========================================================
EOF
