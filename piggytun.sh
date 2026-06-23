#!/usr/bin/env bash
set -euo pipefail

CFG="/etc/haproxy/haproxy.cfg"
MARK="# PIGGYTUN"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

install_haproxy() {
  if ! command -v haproxy >/dev/null 2>&1; then
    echo "Installing HAProxy..."
    if command -v apt >/dev/null; then
      apt update -y
      apt install -y haproxy
    elif command -v yum >/dev/null; then
      yum install -y haproxy
    elif command -v dnf >/dev/null; then
      dnf install -y haproxy
    fi
  fi
}

optimize_tcp() {
  echo "Optimizing TCP settings..."
  cat > /etc/sysctl.d/99-piggytun.conf <<'SYSCTL'
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_max_syn_backlog=65536
net.core.somaxconn=65536
net.ipv4.ip_local_port_range=1024 65535
net.netfilter.nf_conntrack_max=2097152
SYSCTL
  sysctl -p /etc/sysctl.d/99-piggytun.conf >/dev/null 2>&1 || true
}

init_cfg_if_needed() {
  if [[ ! -f "$CFG" ]] || ! grep -q "$MARK GLOBAL" "$CFG"; then
    echo "Creating base config..."
    cat > "$CFG" <<'EOF'
global
    daemon
    maxconn 200000
    tune.bufsize 65536
    tune.maxrewrite 4096
    spread-checks 5
    description "LB"

defaults
    mode tcp
    option tcp-smart-accept
    option tcp-smart-connect
    option dontlognull
    option redispatch
    retries 3
    timeout connect 5s
    timeout client 3m
    timeout server 3m
    timeout client-fin 30s
    timeout server-fin 30s
    timeout tunnel 2h
    timeout check 10s

# PIGGYTUN GLOBAL
EOF
  fi
}

ask() {
  read -rp "$1: " v
  echo "$v"
}

restart_haproxy() {
  if haproxy -c -f "$CFG" 2>&1; then
    systemctl restart haproxy
    systemctl enable haproxy >/dev/null 2>&1 || true
    echo "HAProxy restarted successfully."
  else
    echo "ERROR: HAProxy config is invalid! Fix before restarting."
    exit 1
  fi
}

# ── PRNG: تولید پورت رندوم تکرارپذیر ──
generate_ports() {
  local seed=$1
  local count=$2
  local current_seed=$seed
  ports=()

  for ((i=0; i<count; i++)); do
    while true; do
      current_seed=$(( (current_seed * 1103515245 + 12345) % 2147483648 ))
      p=$(( (current_seed % 55000) + 10000 ))

      exists=0
      for ep in "${ports[@]+"${ports[@]}"}"; do
        if [[ "$ep" == "$p" ]]; then exists=1; break; fi
      done
      if [[ $exists -eq 0 ]]; then
        ports+=("$p")
        break
      fi
    done
  done
}

add_tunnel_iran() {
  main_port=$(ask "Main listen port (for load balancing)")
  count=$(ask "Number of random ports (e.g., 10)")
  kharej_ip=$(ask "Kharej IP")
  seed=$(ask "Shared Secret Seed (Number, remember for Kharej!)")
  rate_limit=$(ask "Max concurrent connections per IP (recommend 100-200)")

  generate_ports "$seed" "$count"

  id="IRAN_${seed}_${count}"

  cat >> "$CFG" <<EOF

$MARK START $id

# ── Main Load-Balance Frontend ──
frontend main_$id
    bind *:$main_port
    mode tcp
    stick-table type ip size 200k expire 60s store conn_cur
    tcp-request connection track-sc1 src
    tcp-request connection reject if { sc1_conn_cur gt $rate_limit }
    default_backend balance_$id

backend balance_$id
    mode tcp
    balance roundrobin
    option redispatch
    retries 3
EOF

  for p in "${ports[@]}"; do
    echo "    server s${p}_$id 127.0.0.1:$p check inter 10s fall 5 rise 2 maxconn 500" >> "$CFG"
  done

  # ── Individual Port Frontends ──
  for p in "${ports[@]}"; do
    cat >> "$CFG" <<EOF

frontend f${p}_$id
    bind *:$p
    mode tcp
    stick-table type ip size 200k expire 60s store conn_cur
    tcp-request connection track-sc1 src
    tcp-request connection reject if { sc1_conn_cur gt $rate_limit }
    default_backend b${p}_$id

backend b${p}_$id
    mode tcp
    server target $kharej_ip:$p check inter 10s fall 5 rise 2 maxconn 500

EOF
  done

  echo "$MARK END $id" >> "$CFG"

  optimize_tcp
  restart_haproxy

  echo ""
  echo "========================================="
  echo " Tunnel added successfully!"
  echo " Generated ports: ${ports[*]}"
  echo " Use SEED=$seed COUNT=$count on Kharej"
  echo "========================================="
}

add_tunnel_kharej() {
  dest_port=$(ask "Destination local port (e.g., V2Ray port)")
  count=$(ask "Number of random ports (must match Iran)")
  seed=$(ask "Shared Secret Seed (must match Iran)")

  generate_ports "$seed" "$count"

  id="KHAREJ_${seed}_${count}"

  cat >> "$CFG" <<EOF

$MARK START $id
EOF

  for p in "${ports[@]}"; do
    cat >> "$CFG" <<EOF

frontend f${p}_$id
    bind *:$p
    mode tcp
    default_backend b${p}_$id

backend b${p}_$id
    mode tcp
    server target 127.0.0.1:$dest_port check inter 10s fall 5 rise 2 maxconn 500

EOF
  done

  echo "$MARK END $id" >> "$CFG"

  optimize_tcp
  restart_haproxy

  echo ""
  echo "Tunnel added. Generated ports: ${ports[*]}"
}

list_tunnels() {
  echo ""
  echo "Active tunnels:"
  grep "$MARK START" "$CFG" | nl || echo "(none)"
}

remove_tunnel() {
  list_tunnels
  num=$(ask "Enter number to remove")
  id=$(grep "$MARK START" "$CFG" | sed -n "${num}p" | awk '{print $4}')
  if [[ -z "$id" ]]; then
    echo "Invalid selection"
    return 1
  fi
  sed -i "/$MARK START $id/,/$MARK END $id/d" "$CFG"
  restart_haproxy
  echo "Removed: $id"
}

remove_all() {
  systemctl stop haproxy 2>/dev/null || true
  rm -f "$CFG"
  read -rp "Remove haproxy package too? (y/n): " r
  if [[ "$r" == "y" ]]; then
    if command -v apt >/dev/null; then
      apt purge -y haproxy && apt autoremove -y
    elif command -v yum >/dev/null; then
      yum remove -y haproxy
    elif command -v dnf >/dev/null; then
      dnf remove -y haproxy
    fi
  fi
  rm -f /etc/sysctl.d/99-piggytun.conf
  sysctl -p >/dev/null 2>&1 || true
  echo "All removed"
  exit 0
}

iran_menu() {
  while true; do
    echo ""
    echo "═══ IRAN MENU ═══"
    echo "1) Install HAProxy & Optimize TCP"
    echo "2) Add Tunnel"
    echo "3) List Tunnels"
    echo "4) Remove Tunnel"
    echo "5) Back"
    c=$(ask "Choice")
    case $c in
      1) install_haproxy; init_cfg_if_needed; optimize_tcp;;
      2) install_haproxy; init_cfg_if_needed; add_tunnel_iran;;
      3) list_tunnels;;
      4) remove_tunnel;;
      5) break;;
    esac
  done
}

kharej_menu() {
  while true; do
    echo ""
    echo "═══ KHAREJ MENU ═══"
    echo "1) Install HAProxy & Optimize TCP"
    echo "2) Add Tunnel"
    echo "3) List Tunnels"
    echo "4) Remove Tunnel"
    echo "5) Back"
    c=$(ask "Choice")
    case $c in
      1) install_haproxy; init_cfg_if_needed; optimize_tcp;;
      2) install_haproxy; init_cfg_if_needed; add_tunnel_kharej;;
      3) list_tunnels;;
      4) remove_tunnel;;
      5) break;;
    esac
  done
}

echo ""
echo "═══ PIGGYTUN MAIN MENU ═══"
echo "1) IRAN SERVER"
echo "2) KHAREJ SERVER"
echo "3) REMOVE ALL"
main=$(ask "Select")
case $main in
  1) iran_menu;;
  2) kharej_menu;;
  3) remove_all;;
  *) echo "Invalid";;
esac
echo "Done"
