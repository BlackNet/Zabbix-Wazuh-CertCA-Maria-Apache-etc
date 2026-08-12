#!/bin/bash
#
# net-tuning.sh - network tuning applied to server codename loki, 2026-08-10
#
# WHY THIS EXISTS
# ---------------
# A 940 GB Active Backup transfer from loki to a Synology NAS
#  over Tailscale was running at 863 KB/s. The path was capable of
# ~250 Mbit/s. Two problems, both on the sending side:
#
#   1. CUBIC congestion control. The link had ~0.1% packet loss from a marginal
#      switch port. CUBIC treats any loss as congestion and halves its window,
#      so it had convinced itself the path was worth ~3 Mbit/s. On an 85 ms
#      round trip that math is brutal:  MSS / (RTT x sqrt(loss)).
#      BBR models actual bottleneck bandwidth and round-trip time instead, and
#      ignores non-congestive loss. cwnd went from 41 to 3052 segments.
#
#   2. Send buffer too small. Even with BBR the socket was "sndbuf_limited"
#      45% of the time - the app had data ready and the kernel had nowhere to
#      put it. At 85 ms RTT you need ~8.5 MB in flight to sustain 100 MB/s;
#      Debian's default tcp_wmem tops out at 4 MB.
#
#   Result: 863 KB/s -> 27.6 MB/s sustained. Same wire, same loss.
#
# Also included: the NIC ring buffers were at the driver default of 256 out of
# a possible 4096, producing rx_missed_errors under burst traffic.
#
# BBR helps any long-haul or lossy path, so this also improves page delivery to
# distant website visitors - not just backups.
#
# USAGE
#   ./net-tuning.sh              apply sysctl settings (safe, no disruption)
#   ./net-tuning.sh --with-nic   also raise NIC ring buffers (BRIEF LINK RESET)
#   ./net-tuning.sh --check      show current values, change nothing
#   ./net-tuning.sh --revert     remove everything this script installed
#
# NOTES
#   * sysctl changes affect NEW sockets only. Existing connections keep the
#     algorithm they were created with - restart the relevant service to pick
#     BBR up. This is why nothing here drops traffic.
#   * --with-nic resets the interface for 1-2 seconds. Do not run it over the
#     interface you are administering unless you can tolerate that.
#

set -uo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-network-tuning.conf"
NIC_UNIT="/etc/systemd/system/nic-tuning.service"
RING_SIZE=4096

MODE="apply"
WITH_NIC=0

for arg in "$@"; do
    case "$arg" in
        --with-nic) WITH_NIC=1 ;;
        --check)    MODE="check" ;;
        --revert)   MODE="revert" ;;
        -h|--help)  sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "Must run as root." >&2; exit 1; }

# Primary interface = whatever carries the default route
IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')

say()  { printf '%s\n' "$*"; }
head2() { printf '\n== %s\n' "$*"; }

show_state() {
    head2 "Current state"
    printf '  %-34s %s\n' "congestion control:" \
        "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    printf '  %-34s %s\n' "available:" \
        "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
    printf '  %-34s %s\n' "tcp_wmem (min/def/max):" \
        "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | tr '\t' ' ')"
    printf '  %-34s %s\n' "tcp_rmem (min/def/max):" \
        "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | tr '\t' ' ')"
    printf '  %-34s %s\n' "core.wmem_max:" \
        "$(sysctl -n net.core.wmem_max 2>/dev/null)"
    printf '  %-34s %s\n' "core.rmem_max:" \
        "$(sysctl -n net.core.rmem_max 2>/dev/null)"
    printf '  %-34s %s\n' "tcp_mtu_probing:" \
        "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
    printf '  %-34s %s\n' "default qdisc:" \
        "$(sysctl -n net.core.default_qdisc 2>/dev/null)"

    if [ -n "$IFACE" ] && command -v ethtool >/dev/null 2>&1; then
        printf '  %-34s %s\n' "interface:" "$IFACE"
        printf '  %-34s %s\n' "NIC ring RX / max:" \
            "$(ethtool -g "$IFACE" 2>/dev/null | awk '/^RX:/{print $2; exit}')/$(ethtool -g "$IFACE" 2>/dev/null | awk '/^Pre-set/{p=1} p&&/^RX:/{print $2; exit}')"
    fi

    printf '  %-34s %s\n' "config file present:" \
        "$([ -f "$SYSCTL_FILE" ] && echo yes || echo no)"
    printf '  %-34s %s\n' "NIC unit present:" \
        "$([ -f "$NIC_UNIT" ] && echo yes || echo no)"
    echo
}

# ---------------------------------------------------------------- check ----
if [ "$MODE" = "check" ]; then
    show_state
    exit 0
fi

# --------------------------------------------------------------- revert ----
if [ "$MODE" = "revert" ]; then
    head2 "Reverting"

    if [ -f "$SYSCTL_FILE" ]; then
        rm -f "$SYSCTL_FILE"
        say "  removed $SYSCTL_FILE"
    fi

    if [ -f "$NIC_UNIT" ]; then
        systemctl disable --now nic-tuning.service >/dev/null 2>&1
        rm -f "$NIC_UNIT"
        systemctl daemon-reload
        say "  removed $NIC_UNIT"
    fi

    # Put the runtime back to the kernel defaults Debian ships
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 16384 4194304" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 131072 6291456" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_mtu_probing=0 >/dev/null 2>&1
    say "  runtime values reset to defaults"
    say "  NIC ring buffers unchanged - reboot or set manually if needed"

    show_state
    exit 0
fi

# ---------------------------------------------------------------- apply ----
head2 "Before"
show_state

# BBR lives in a module on stock Debian kernels
if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    say "Loading tcp_bbr module..."
    modprobe tcp_bbr 2>/dev/null
    grep -qxF 'tcp_bbr' /etc/modules-load.d/bbr.conf 2>/dev/null \
        || echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf
fi

if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    echo "ERROR: BBR not available on this kernel. Nothing applied." >&2
    exit 1
fi

[ -f "$SYSCTL_FILE" ] && cp -a "$SYSCTL_FILE" "${SYSCTL_FILE}.bak-$(date +%F-%H%M%S)"

cat > "$SYSCTL_FILE" <<'EOF'
# Network tuning - see /usr/local/sbin/net-tuning.sh for the reasoning.
# Applied 2026-08-10 after diagnosing a long-haul transfer stuck at 863 KB/s.

# Congestion control. BBR measures bottleneck bandwidth and RTT rather than
# inferring congestion from packet loss, so a lossy long-distance link does
# not collapse the send window. This was worth roughly 30x on an 85 ms path
# carrying 0.1% loss.
net.ipv4.tcp_congestion_control = bbr

# Socket buffer ceilings. Bandwidth-delay product at 85 ms RTT needs several
# MB in flight; the stock 4 MB tcp_wmem ceiling caps throughput well below
# line rate. These are ceilings for auto-tuning, not allocations - short-lived
# web connections stay small.
net.core.rmem_max  = 67108864
net.core.wmem_max  = 67108864
net.ipv4.tcp_rmem  = 4096 87380 67108864
net.ipv4.tcp_wmem  = 4096 65536 67108864

# Recover from PMTU black holes instead of stalling. Relevant when traffic
# rides a tunnel (Tailscale uses a 1280 byte MTU).
net.ipv4.tcp_mtu_probing = 1
EOF

say "wrote $SYSCTL_FILE"
sysctl --system >/dev/null 2>&1
say "applied"

# ------------------------------------------------------------- NIC rings ---
if [ "$WITH_NIC" -eq 1 ]; then
    if [ -z "$IFACE" ]; then
        echo "WARNING: could not determine the default-route interface; skipping NIC tuning." >&2
    elif ! command -v ethtool >/dev/null 2>&1; then
        echo "WARNING: ethtool not installed; skipping NIC tuning. (apt install ethtool)" >&2
    else
        MAXRX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/^Pre-set/{p=1} p&&/^RX:/{print $2; exit}')
        WANT=$RING_SIZE
        [ -n "$MAXRX" ] && [ "$MAXRX" -lt "$WANT" ] && WANT="$MAXRX"

        head2 "NIC ring buffers on $IFACE -> $WANT (brief link reset)"
        ethtool -G "$IFACE" rx "$WANT" tx "$WANT" 2>/dev/null \
            && say "  applied" \
            || say "  driver rejected the change (some NICs do not support it)"

        cat > "$NIC_UNIT" <<EOF
[Unit]
Description=NIC ring buffer tuning
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
    fi
fi

head2 "After"
show_state

cat <<'EOF'
Reminder: these apply to NEW sockets. Long-lived connections keep whatever
algorithm they started with. To make a running service benefit:

    systemctl restart <service>

Verify a specific connection is actually on BBR:

    ss -ti | grep -A2 '<dest-ip>:<port>' | grep -E 'bbr:|cubic|cwnd|sndbuf_limited'

You want 'bbr', a large cwnd, and sndbuf_limited near zero. If sndbuf_limited
stays high after this, the application is setting SO_SNDBUF itself and the
kernel ceiling no longer applies.
EOF
