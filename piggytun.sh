#!/usr/bin/env bash
set -euo pipefail

CFG="/etc/haproxy/haproxy.cfg"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

install_haproxy() {
  if command -v apt >/dev/null; then
    apt update -y
    apt install -y haproxy
  elif command -v yum >/dev/null; then
    yum install -y haproxy
  elif command -v dnf >/dev/null; then
    dnf install -y haproxy
  fi
}

remove_haproxy() {

echo "Removing HAProxy tunnel..."

systemctl stop haproxy 2>/dev/null || true
systemctl disable haproxy 2>/dev/null || true

if [[ -f "$CFG" ]]; then
    rm -f "$CFG"
    echo "Config removed"
fi

# optional uninstall
read -rp "Remove haproxy package too? (y/n): " r

if [[ "$r" == "y" ]]; then

    if command -v apt >/dev/null; then
        apt purge -y haproxy
        apt autoremove -y
    elif command -v yum >/dev/null; then
        yum remove -y haproxy
    elif command -v dnf >/dev/null; then
        dnf remove -y haproxy
    fi

    echo "HAProxy uninstalled"
fi

echo "Cleanup done"
exit 0

}

ask() {
  read -rp "$1: " v
  echo "$v"
}

write_global() {

cat > $CFG <<EOF
global
    daemon
    maxconn 500000

defaults
    mode tcp
    timeout connect 10s
    timeout client 1m
    timeout server 1m
EOF

}

setup_iran() {

echo "=== IRAN SERVER SETUP ==="

main_port=$(ask "پورت ورودی اصلی")
range_start=$(ask "شروع بازه پورت")
count=$(ask "تعداد پورت")
kharej_ip=$(ask "IP سرور خارج")

write_global

cat >> $CFG <<EOF

frontend main_in
    bind *:$main_port
    mode tcp
    default_backend balance_ports

backend balance_ports
    balance roundrobin
EOF

for ((i=0;i<count;i++)); do
p=$((range_start+i))
echo "    server s$p 127.0.0.1:$p check" >> $CFG
done

for ((i=0;i<count;i++)); do

p=$((range_start+i))

cat >> $CFG <<EOF

frontend f$p
    bind *:$p
    default_backend b$p

backend b$p
    server target $kharej_ip:$p check
EOF

done

}

setup_kharej() {

echo "=== KHAREJ SERVER SETUP ==="

range_start=$(ask "شروع بازه پورت")
count=$(ask "تعداد پورت")
iran_ip=$(ask "IP سرور ایران")
dest_port=$(ask "پورت مقصد نهایی")

write_global

for ((i=0;i<count;i++)); do

p=$((range_start+i))

cat >> $CFG <<EOF

frontend f$p
    bind *:$p
    default_backend b$p

backend b$p
    server target 127.0.0.1:$dest_port check
EOF

done

}


echo
echo "1) IRAN SERVER"
echo "2) KHAREJ SERVER"
echo "3) REMOVE / UNINSTALL"

mode=$(ask "Select option")

case "$mode" in

1)
install_haproxy
setup_iran
;;

2)
install_haproxy
setup_kharej
;;

3)
remove_haproxy
;;

*)
echo "Invalid option"
exit 1
;;

esac


haproxy -c -f $CFG

systemctl restart haproxy
systemctl enable haproxy

echo
echo "DONE"
