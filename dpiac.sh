#!/bin/bash
set -euo pipefail

VPN_PORT=1194
NET_IF="$(ip route get 8.8.8.8 | awk '{print $5; exit}')"
IP_ADDR="$(hostname -I | awk '{print $1}')"

echo "Updating packages..."
apt update

echo "Installing required packages..."
apt install -y nginx ufw iptables iproute2 stunnel4 openssl

echo "Generating self-signed certificate..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/stunnel/private.key -out /etc/stunnel/certificate.crt \
  -subj "/CN=$IP_ADDR"

echo "Resetting and configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp
ufw allow 80/tcp

for port in 443 8080 8443 2083; do
  ufw allow $port/tcp
done

ufw --force enable

echo "Flushing iptables rules and setting new rules..."
iptables -F

iptables -A INPUT -p udp --dport $VPN_PORT -j ACCEPT

for port in 443 8080 8443 2083; do
  iptables -A INPUT -p tcp --dport $port -j ACCEPT
done

iptables -A INPUT -j DROP

echo "Configuring traffic shaping with tc..."
tc qdisc del dev $NET_IF root 2>/dev/null || true
tc qdisc add dev $NET_IF root netem delay 20ms 5ms distribution normal loss 0.02% duplicate 0.01%

echo "Setting up stunnel configuration..."
cat > /etc/stunnel/stunnel.conf <<EOF
pid = /var/run/stunnel.pid

[openvpn]
accept = 443
connect = 127.0.0.1:$VPN_PORT
cert = /etc/stunnel/certificate.crt
key = /etc/stunnel/private.key
sslVersion = TLSv1.2
options = NO_SSLv2
options = NO_SSLv3
options = NO_TLSv1
options = NO_TLSv1.1
ciphers = HIGH
EOF

sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4
systemctl restart stunnel4
systemctl enable stunnel4

echo "Configuring nginx as proxy on port 80..."
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:$VPN_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }
}
EOF

nginx -t && systemctl reload nginx

echo "==============================="
echo "Setup complete!"
echo "VPN Port: $VPN_PORT"
echo "Stunnel TLS running on port 443."
echo "==============================="
