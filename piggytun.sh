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

optimize_system() {

echo "Applying optimization..."

cp -f "$CFG" "${CFG}.bak.$(date +%s)" 2>/dev/null || true

cat > /etc/haproxy/haproxy.cfg <<'EOF'
global
    daemon
    maxconn 500000
    nbthread 2
    cpu-map auto:1/1-2 0-1
    tune.bufsize 32768
    tune.maxrewrite 4096
    tune.rcvbuf.client 262144
    tune.rcvbuf.server 262144
    tune.sndbuf.client 262144
    tune.sndbuf.server 262144

defaults
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 1h
    timeout server 1h
    timeout tunnel 1h

# KEEP YOUR EXISTING FRONTENDS AND BACKENDS BELOW THIS LINE
EOF

grep -q "PIGGYTUN OPTIMIZATION" /etc/sysctl.conf || cat >> /etc/sysctl.conf <<'EOF'

# PIGGYTUN OPTIMIZATION
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 262144 67108864
net.ipv4.tcp_wmem = 4096 262144 67108864
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_congestion_control = bbr
net.core.netdev_max_backlog = 250000
net.core.default_qdisc = fq

EOF

sysctl -p

if [[ -f "$CFG" ]]; then
    sed -i 's/bind \*/bind * reuseport/g' "$CFG"
fi

systemctl daemon-reexec
systemctl restart haproxy
systemctl enable haproxy >/dev/null 2>&1 || true

echo "Optimization applied successfully"
}

init_cfg_if_needed() {
  if [[ ! -f "$CFG" ]] || ! grep -q "$MARK GLOBAL" "$CFG"; then
    cat > "$CFG" <<EOF
global
    daemon
    maxconn 500000

defaults
    mode tcp
    timeout connect 10s
    timeout client 1m
    timeout server 1m

$MARK GLOBAL
EOF
  fi
}

ask() {
  read -rp "$1: " v
  echo "$v"
}

restart_haproxy() {
  haproxy -c -f "$CFG"
  systemctl restart haproxy
  systemctl enable haproxy >/dev/null 2>&1 || true
}

add_tunnel_iran() {

main_port=$(ask "Main listen port")
range_start=$(ask "Port range start")
count=$(ask "Port count")
kharej_ip=$(ask "Kharej IP")

id="IRAN_${main_port}_${range_start}_${count}"

cat >> "$CFG" <<EOF

$MARK START $id

frontend main_$id
    bind *:$main_port reuseport
    default_backend balance_$id

backend balance_$id
    balance roundrobin
EOF

for ((i=0;i<count;i++)); do
p=$((range_start+i))
echo "    server s${p}_$id 127.0.0.1:$p check" >> "$CFG"
done

for ((i=0;i<count;i++)); do
p=$((range_start+i))

cat >> "$CFG" <<EOF

frontend f${p}_$id
    bind *:$p reuseport
    default_backend b${p}_$id

backend b${p}_$id
    server target $kharej_ip:$p check
EOF

done

echo "$MARK END $id" >> "$CFG"

restart_haproxy

echo "Tunnel added: $id"
}

add_tunnel_kharej() {

range_start=$(ask "Port range start")
count=$(ask "Port count")
dest_port=$(ask "Destination local port")

id="KHAREJ_${range_start}_${count}_${dest_port}"

cat >> "$CFG" <<EOF

$MARK START $id
EOF

for ((i=0;i<count;i++)); do
p=$((range_start+i))

cat >> "$CFG" <<EOF

frontend f${p}_$id
    bind *:$p reuseport
    default_backend b${p}_$id

backend b${p}_$id
    server target 127.0.0.1:$dest_port check
EOF

done

echo "$MARK END $id" >> "$CFG"

restart_haproxy

echo "Tunnel added: $id"
}

list_tunnels() {
grep "$MARK START" "$CFG" | nl
}

remove_tunnel() {

list_tunnels

num=$(ask "Enter number to remove")

id=$(grep "$MARK START" "$CFG" | sed -n "${num}p" | awk '{print $4}')

sed -i "/$MARK START $id/,/$MARK END $id/d" "$CFG"

restart_haproxy

echo "Removed: $id"
}

remove_all() {

systemctl stop haproxy || true
rm -f "$CFG"

read -rp "Remove haproxy package too? (y/n): " r

if [[ "$r" == "y" ]]; then
  apt purge -y haproxy 2>/dev/null || yum remove -y haproxy 2>/dev/null || dnf remove -y haproxy 2>/dev/null
fi

echo "All removed"
exit 0
}

iran_menu() {

while true; do
echo
echo "IRAN MENU"
echo "1) Install HAProxy"
echo "2) Add Tunnel"
echo "3) List Tunnels"
echo "4) Remove Tunnel"
echo "5) Optimize"
echo "6) Back"

c=$(ask "Choice")

case $c in
1) install_haproxy; init_cfg_if_needed ;;
2) install_haproxy; init_cfg_if_needed; add_tunnel_iran ;;
3) list_tunnels ;;
4) remove_tunnel ;;
5) optimize_system ;;
6) break ;;
esac

done
}

kharej_menu() {

while true; do
echo
echo "KHAREJ MENU"
echo "1) Install HAProxy"
echo "2) Add Tunnel"
echo "3) List Tunnels"
echo "4) Remove Tunnel"
echo "5) Optimize"
echo "6) Back"

c=$(ask "Choice")

case $c in
1) install_haproxy; init_cfg_if_needed ;;
2) install_haproxy; init_cfg_if_needed; add_tunnel_kharej ;;
3) list_tunnels ;;
4) remove_tunnel ;;
5) optimize_system ;;
6) break ;;
esac

done
}

echo
echo "MAIN MENU"
echo "1) IRAN SERVER"
echo "2) KHAREJ SERVER"
echo "3) REMOVE ALL"

main=$(ask "Select")

case $main in
1) iran_menu ;;
2) kharej_menu ;;
3) remove_all ;;
*) echo "Invalid" ;;
esac

echo "Done"
