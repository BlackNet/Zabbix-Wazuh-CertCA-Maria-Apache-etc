#!/bin/bash
#
# net-tuning.sh - TCP + NIC tuning, with a real rollback.
# loki.street-tek.com, applied 2026-08-10. Revised 2026-08-14.
#
# ============================================================================
# WHY THIS EXISTS
# ============================================================================
# A 940 GB Active Backup transfer from loki (Teterboro NJ) to a Synology NAS
# (Irvine CA) over Tailscale ran at 863 KB/s on a path capable of ~250 Mbit/s.
# Two sender-side problems:
#
#   1. CUBIC congestion control. The link carried ~0.1% packet loss from a
#      marginal switch port. CUBIC reads any loss as congestion and halves its
#      window, so it had settled on ~3 Mbit/s. On an 85 ms round trip the
#      Mathis approximation - MSS / (RTT * sqrt(loss)) - predicts almost
#      exactly the observed rate, so this was textbook rather than a fault.
#      BBR models bottleneck bandwidth and RTT directly and ignores
#      non-congestive loss. cwnd went from 41 to 3052 segments.
#
#   2. Send buffer ceiling. Even on BBR the socket reported sndbuf_limited
#      45% of the time - data ready, nowhere to put it. Sustaining 100 MB/s at
#      85 ms RTT needs ~8.5 MB in flight; Debian's tcp_wmem tops out at 4 MB.
#
#   Result: 863 KB/s -> 27.6 MB/s. Same wire, same loss.
#
# Also raises NIC ring buffers, which sat at the driver default of 256 of a
# possible 4096 and produced rx_missed_errors under burst traffic.
#
# BBR helps any long-haul or lossy path, so this also improves page delivery
# to distant website visitors, not just backups.
#
# ============================================================================
# ROLLBACK DESIGN
# ============================================================================
# An earlier version "reverted" to hardcoded Debian defaults, which is a guess
# dressed as a rollback. This version instead captures real state at apply
# time, into /var/lib/net-tuning/:
#
#   * the actual current value of every sysctl key it touches
#   * current NIC ring sizes, and the driver maximum
#   * whether tcp_bbr was already loaded / already set to autoload
#   * copies of every file it creates or overwrites
#   * a list of OTHER sysctl files that set the same keys (conflicts)
#
# --revert replays that snapshot. It restores prior values verbatim, puts back
# archived files, removes files this script created, and resets ring buffers.
# If no snapshot exists it refuses to act rather than guessing.
#
# ============================================================================
# USAGE
#   ./net-tuning.sh --check              show state and conflicts, change nothing
#   ./net-tuning.sh                      apply sysctls (no disruption)
#   ./net-tuning.sh --with-nic           also raise NIC rings (BRIEF LINK RESET)
#   ./net-tuning.sh --revert             roll back using the newest snapshot
#   ./net-tuning.sh --revert --state F   roll back using a specific snapshot
#   ./net-tuning.sh --list-states        show captured snapshots
#
# NOTES
#   * sysctl changes affect NEW sockets only. Existing connections keep the
#     algorithm they were created with. Restart a service for it to benefit.
#     This is why applying never drops traffic.
#   * --with-nic resets the interface for 1-2 seconds.
#   * Run --check first. It reports conflicting sysctl files, which is the
#     usual reason a setting "does not stick" after reboot.
# ============================================================================

set -uo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-network-tuning.conf"
MODULE_FILE="/etc/modules-load.d/tcp-bbr.conf"
NIC_UNIT="/etc/systemd/system/nic-tuning.service"
STATE_DIR="/var/lib/net-tuning"
RING_TARGET=4096

# Every key this script manages. Revert restores exactly these.
KEYS=(
    net.ipv4.tcp_congestion_control
    net.core.rmem_max
    net.core.wmem_max
    net.ipv4.tcp_rmem
    net.ipv4.tcp_wmem
    net.ipv4.tcp_mtu_probing
)

MODE="apply"
WITH_NIC=0
STATE_PICK=""

while [ $# -gt 0 ]; do
    case "$1" in
        --with-nic)    WITH_NIC=1 ;;
        --check)       MODE="check" ;;
        --revert)      MODE="revert" ;;
        --list-states) MODE="list" ;;
        --state)       shift; STATE_PICK="${1:-}" ;;
        -h|--help)     sed -n '2,60p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || { echo "Must run as root." >&2; exit 1; }

IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')

hdr() { printf '\n== %s\n' "$*"; }
say() { printf '%s\n' "$*"; }

# sysctl values can contain tabs (tcp_rmem). Normalise to single spaces so the
# snapshot round-trips cleanly.
getval() { sysctl -n "$1" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/ *$//'; }

ring_now() { [ -n "$IFACE" ] && ethtool -g "$IFACE" 2>/dev/null | awk '/^Current/{c=1} c&&/^RX:/{print $2; exit}'; }
ring_max() { [ -n "$IFACE" ] && ethtool -g "$IFACE" 2>/dev/null | awk '/^Pre-set/{p=1} p&&/^RX:/{print $2; exit}'; }
ring_now_tx() { [ -n "$IFACE" ] && ethtool -g "$IFACE" 2>/dev/null | awk '/^Current/{c=1} c&&/^TX:/{print $2; exit}'; }

# Other files setting our keys - the usual cause of "it did not stick".
find_conflicts() {
    local f k
    for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /run/sysctl.d/*.conf; do
        [ -f "$f" ] || continue
        [ "$f" = "$SYSCTL_FILE" ] && continue
        for k in "${KEYS[@]}"; do
            if grep -Eq "^[[:space:]]*${k//./\\.}[[:space:]]*=" "$f" 2>/dev/null; then
                echo "$f"
                break
            fi
        done
    done
}

show_state() {
    hdr "Runtime values"
    local k
    for k in "${KEYS[@]}"; do
        printf '  %-34s %s\n' "$k" "$(getval "$k")"
    done
    printf '  %-34s %s\n' "net.core.default_qdisc" "$(getval net.core.default_qdisc)"
    printf '  %-34s %s\n' "available congestion control" \
        "$(getval net.ipv4.tcp_available_congestion_control)"

    hdr "Interface"
    if [ -n "$IFACE" ] && command -v ethtool >/dev/null 2>&1; then
        printf '  %-34s %s\n' "device" "$IFACE"
        printf '  %-34s %s / %s\n' "ring RX current / max" "$(ring_now)" "$(ring_max)"
        printf '  %-34s %s\n' "ring TX current" "$(ring_now_tx)"
    else
        printf '  %-34s %s\n' "device" "${IFACE:-unknown} (ethtool not available)"
    fi

    hdr "Files"
    printf '  %-34s %s\n' "$SYSCTL_FILE" "$([ -f "$SYSCTL_FILE" ] && echo present || echo absent)"
    printf '  %-34s %s\n' "$MODULE_FILE"  "$([ -f "$MODULE_FILE" ]  && echo present || echo absent)"
    printf '  %-34s %s\n' "$NIC_UNIT"     "$([ -f "$NIC_UNIT" ]     && echo present || echo absent)"

    local conflicts; conflicts=$(find_conflicts)
    hdr "Conflicting sysctl files"
    if [ -n "$conflicts" ]; then
        say "  These also set keys this script manages. Later files win, so a"
        say "  leftover file can silently override what you apply here:"
        printf '    %s\n' $conflicts
    else
        say "  none"
    fi
    echo
}

latest_state() { ls -1t "$STATE_DIR"/state-*.env 2>/dev/null | head -1; }

# ------------------------------------------------------------------- list ---
if [ "$MODE" = "list" ]; then
    hdr "Snapshots in $STATE_DIR"
    if ls -1t "$STATE_DIR"/state-*.env >/dev/null 2>&1; then
        for f in $(ls -1t "$STATE_DIR"/state-*.env); do
            printf '  %s   (%s)\n' "$f" "$(grep -m1 '^CAPTURED=' "$f" | cut -d= -f2-)"
        done
    else
        say "  none - nothing has been applied by this script"
    fi
    echo
    exit 0
fi

# ------------------------------------------------------------------ check ---
if [ "$MODE" = "check" ]; then
    show_state
    s=$(latest_state)
    [ -n "$s" ] && say "Newest snapshot: $s" || say "No snapshot captured yet."
    exit 0
fi

# ----------------------------------------------------------------- revert ---
if [ "$MODE" = "revert" ]; then
    STATE="${STATE_PICK:-$(latest_state)}"
    if [ -z "$STATE" ] || [ ! -f "$STATE" ]; then
        echo "ERROR: no snapshot found in $STATE_DIR." >&2
        echo "Refusing to guess at previous values. Nothing changed." >&2
        exit 1
    fi

    hdr "Reverting from $STATE"
    # shellcheck disable=SC1090
    . "$STATE"

    # 1. restore sysctl values exactly as captured
    for k in "${KEYS[@]}"; do
        var="PRE_$(echo "$k" | tr '.' '_')"
        val="${!var-}"
        if [ -n "${val:-}" ]; then
            sysctl -w "$k=$val" >/dev/null 2>&1 \
                && say "  restored $k = $val" \
                || say "  WARNING could not restore $k"
        else
            say "  no captured value for $k - left as is"
        fi
    done

    # 2. remove files this script created; restore any it overwrote
    for pair in "SYSCTL_FILE:$SYSCTL_FILE" "MODULE_FILE:$MODULE_FILE" "NIC_UNIT:$NIC_UNIT"; do
        tag="${pair%%:*}"; path="${pair#*:}"
        existed_var="PRE_${tag}_EXISTED"
        archive="$STATE_ARCHIVE/$(basename "$path")"
        if [ "${!existed_var-no}" = "yes" ] && [ -f "$archive" ]; then
            cp -a "$archive" "$path" && say "  restored original $path"
        elif [ -f "$path" ]; then
            rm -f "$path" && say "  removed $path"
        fi
    done
    systemctl daemon-reload 2>/dev/null
    systemctl disable nic-tuning.service >/dev/null 2>&1

    # 3. restore NIC ring buffers
    if [ -n "${PRE_RING_RX:-}" ] && [ -n "$IFACE" ] && command -v ethtool >/dev/null 2>&1; then
        if [ "$(ring_now)" != "$PRE_RING_RX" ]; then
            say "  restoring NIC rings to rx=$PRE_RING_RX tx=${PRE_RING_TX:-$PRE_RING_RX} (brief link reset)"
            ethtool -G "$IFACE" rx "$PRE_RING_RX" tx "${PRE_RING_TX:-$PRE_RING_RX}" 2>/dev/null \
                || say "  WARNING driver rejected ring restore"
        else
            say "  NIC rings already at captured value"
        fi
    fi

    # 4. unload bbr only if we were the ones who loaded it
    if [ "${PRE_BBR_LOADED:-yes}" = "no" ]; then
        modprobe -r tcp_bbr 2>/dev/null && say "  unloaded tcp_bbr module"
    fi

    say ""
    say "Reverted. Note that sysctl --system on next boot re-reads all files;"
    say "if a conflicting file listed by --check sets these keys, it wins."
    show_state
    exit 0
fi

# ------------------------------------------------------------------ apply ---
hdr "Before"
show_state

CONFLICTS=$(find_conflicts)
if [ -n "$CONFLICTS" ]; then
    say "WARNING: other files already set keys managed here:"
    printf '  %s\n' $CONFLICTS
    say ""
    say "Load order decides the winner, so leaving these in place makes the"
    say "effective configuration ambiguous. They are recorded in the snapshot"
    say "but NOT modified - consolidate them by hand once you have reviewed."
    say ""
fi

mkdir -p "$STATE_DIR" || { echo "cannot create $STATE_DIR" >&2; exit 1; }
chmod 700 "$STATE_DIR"

STAMP=$(date +%Y%m%d-%H%M%S)
STATE="$STATE_DIR/state-$STAMP.env"
ARCHIVE="$STATE_DIR/archive-$STAMP"
mkdir -p "$ARCHIVE"

{
    echo "# net-tuning.sh state snapshot"
    echo "CAPTURED='$(date -Is)'"
    echo "HOSTNAME='$(hostname -f 2>/dev/null || hostname)'"
    echo "KERNEL='$(uname -r)'"
    echo "IFACE='${IFACE:-}'"
    echo "STATE_ARCHIVE='$ARCHIVE'"
    for k in "${KEYS[@]}"; do
        echo "PRE_$(echo "$k" | tr '.' '_')='$(getval "$k")'"
    done
    echo "PRE_RING_RX='$(ring_now)'"
    echo "PRE_RING_TX='$(ring_now_tx)'"
    echo "PRE_RING_MAX='$(ring_max)'"
    echo "PRE_BBR_LOADED='$(lsmod 2>/dev/null | grep -q '^tcp_bbr' && echo yes || echo no)'"
    echo "PRE_SYSCTL_FILE_EXISTED='$([ -f "$SYSCTL_FILE" ] && echo yes || echo no)'"
    echo "PRE_MODULE_FILE_EXISTED='$([ -f "$MODULE_FILE" ] && echo yes || echo no)'"
    echo "PRE_NIC_UNIT_EXISTED='$([ -f "$NIC_UNIT" ] && echo yes || echo no)'"
    echo "PRE_CONFLICTS='$(echo $CONFLICTS)'"
} > "$STATE"
chmod 600 "$STATE"

# archive anything we are about to overwrite, plus the conflicting files
for p in "$SYSCTL_FILE" "$MODULE_FILE" "$NIC_UNIT"; do
    [ -f "$p" ] && cp -a "$p" "$ARCHIVE/"
done
for p in $CONFLICTS; do
    cp -a "$p" "$ARCHIVE/conflict-$(basename "$p")" 2>/dev/null
done

say "snapshot: $STATE"
say "archive:  $ARCHIVE"

# BBR module
if ! getval net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
    modprobe tcp_bbr 2>/dev/null
fi
if ! getval net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
    echo "ERROR: BBR unavailable on kernel $(uname -r). Nothing applied." >&2
    rm -rf "$ARCHIVE"; rm -f "$STATE"
    exit 1
fi
echo 'tcp_bbr' > "$MODULE_FILE"

cat > "$SYSCTL_FILE" <<'EOF'
# Managed by /usr/local/sbin/net-tuning.sh - see that file for the reasoning.
# Snapshot of prior values is under /var/lib/net-tuning/.

# BBR measures bottleneck bandwidth and RTT rather than inferring congestion
# from packet loss, so a lossy long-distance path does not collapse the send
# window. Worth ~30x on an 85 ms path carrying 0.1% loss.
net.ipv4.tcp_congestion_control = bbr

# Socket buffer CEILINGS for auto-tuning, not allocations. Bandwidth-delay
# product at 85 ms needs several MB in flight; the stock 4 MB tcp_wmem cap
# limits throughput well below line rate. Short-lived web connections are
# unaffected - auto-tuning only grows buffers that are actually used.
net.core.rmem_max  = 67108864
net.core.wmem_max  = 67108864
net.ipv4.tcp_rmem  = 4096 87380 67108864
net.ipv4.tcp_wmem  = 4096 65536 67108864

# Recover from PMTU black holes rather than stalling. Relevant when traffic
# rides a tunnel - Tailscale uses a 1280 byte MTU.
net.ipv4.tcp_mtu_probing = 1
EOF

say "wrote $SYSCTL_FILE"
sysctl --system >/dev/null 2>&1
say "applied"

# ------------------------------------------------------------- NIC rings ---
if [ "$WITH_NIC" -eq 1 ]; then
    if [ -z "$IFACE" ]; then
        say "WARNING: no default-route interface found; skipping NIC tuning."
    elif ! command -v ethtool >/dev/null 2>&1; then
        say "WARNING: ethtool not installed; skipping NIC tuning (apt install ethtool)."
    else
        MAX=$(ring_max); WANT=$RING_TARGET
        [ -n "$MAX" ] && [ "$MAX" -lt "$WANT" ] 2>/dev/null && WANT="$MAX"

        hdr "NIC rings on $IFACE -> $WANT (brief link reset)"
        if ethtool -G "$IFACE" rx "$WANT" tx "$WANT" 2>/dev/null; then
            say "  applied"
            cat > "$NIC_UNIT" <<EOF
[Unit]
Description=NIC ring buffer tuning (net-tuning.sh)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -G $IFACE rx $WANT tx $WANT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable nic-tuning.service >/dev/null 2>&1
            say "  installed $NIC_UNIT (persists across reboots)"
        else
            say "  driver rejected the change - some NICs do not support it"
        fi
    fi
fi

hdr "After"
show_state

cat <<EOF
Rollback
    $0 --revert                 uses $STATE
    $0 --list-states            show all snapshots

These apply to NEW sockets. A running service keeps whatever it started with:

    systemctl restart <service>

Verify a specific connection:

    ss -ti | grep -A2 '<dest-ip>:<port>' | grep -E 'bbr:|cubic|cwnd|sndbuf_limited'

Want 'bbr', a large cwnd, and sndbuf_limited near zero. If sndbuf_limited
stays high, the application sets SO_SNDBUF itself and the kernel ceiling no
longer applies.
EOF
