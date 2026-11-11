#!/usr/bin/env bash
# Home Cartoon: HTTPS com DuckDNS + Let's Encrypt, firewall e icones.
# Correr como: bash https.sh   (depois de "sudo -v")
set -u
DOM=homecartoon.duckdns.org
LOG="$HOME/hc-relatorio.txt"
S="sudo -n"
exec > >(tee "$LOG") 2>&1
ok(){ echo "[OK] $*"; }; ko(){ echo "[!!] $*"; }

echo "== 1. Icones =="
ls -l /usr/local/bin/homecartoon-icons.sh /etc/apt/apt.conf.d/99homecartoon 2>&1 | sed 's/^/   /'
if [ -x /usr/local/bin/homecartoon-icons.sh ]; then
  $S /usr/local/bin/homecartoon-icons.sh >/dev/null 2>&1 && ok "script de icones correu" || ko "script de icones falhou"
else ko "script de icones nao existe ou nao e executavel"; fi
W=/usr/share/jellyfin/web
for f in "$W"/icon-transparent.*.png "$W"/banner-light.*.png "$W"/touchicon.*.png; do
  echo "   $(basename "$f") $(stat -c %s "$f") bytes"; done

echo "== 2. DuckDNS =="
PUB=$(curl -s -m 10 https://api.ipify.org || true)
DNS=$(getent ahostsv4 "$DOM" | awk 'NR==1{print $1}')
echo "   IP publico: ${PUB:-?}   $DOM -> ${DNS:-?}"
[ -n "$PUB" ] && [ "$PUB" = "$DNS" ] && ok "DuckDNS aponta para casa" || ko "DuckDNS NAO aponta para o IP de casa"
echo "   atualizador:"; (crontab -l 2>/dev/null; $S crontab -l 2>/dev/null) | grep -i duck | sed 's/token=[^&" ]*/token=***/' | sed 's/^/     /'
ls -d "$HOME"/duckdns 2>/dev/null | sed 's/^/     /'
systemctl list-timers --all 2>/dev/null | grep -i duck | sed 's/^/     /'

echo "== 3. Pacotes =="
$S apt-get -y -qq install certbot >/dev/null 2>&1 && ok "certbot instalado" || ko "falhou instalar certbot"

echo "== 4. nginx (porta 80) =="
$S mkdir -p /var/www/certbot
PROXY='
        proxy_pass http://127.0.0.1:8096;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_buffering off;'
CONF80="server {
    # Rede de casa: http://home e http://192.168.1.86
    listen 80 default_server;
    server_name _;
    allow 127.0.0.1;
    allow 192.168.1.0/24;
    deny all;
    client_max_body_size 20M;
    location / {$PROXY
    }
}

server {
    # Internet: so certificado e redirecionamento para HTTPS
    listen 80;
    server_name $DOM;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
"
echo "$CONF80" | $S tee /etc/nginx/sites-available/homecartoon >/dev/null
$S nginx -t >/dev/null 2>&1 && $S systemctl reload nginx && ok "nginx porta 80" || { ko "nginx -t falhou"; $S nginx -t; }

echo "== 5. Firewall =="
# Regra antiga que abria todo o UDP do servidor a qualquer origem: passa a ser so a rede de casa
while n=$($S ufw status numbered | grep -F '192.168.1.86/udp' | grep -F 'Anywhere' | head -n1 | sed -E 's/^\[ *([0-9]+)\].*/\1/'); [ -n "$n" ]; do
  $S ufw --force delete "$n" >/dev/null && ok "removida regra UDP aberta a todos (#$n)"
done
$S ufw allow from 192.168.1.0/24 proto udp >/dev/null && ok "UDP so para a rede de casa"
$S ufw allow 80/tcp >/dev/null && $S ufw allow 443/tcp >/dev/null && ok "abertas 80 e 443"
$S ufw status numbered | sed 's/^/   /'

echo "== 6. Certificado =="
if $S certbot certonly --webroot -w /var/www/certbot -d "$DOM" --non-interactive --agree-tos \
     --register-unsafely-without-email --keep-until-expiring \
     --deploy-hook "systemctl reload nginx" >/tmp/hc-certbot.txt 2>&1; then
  ok "certificado obtido"
else
  ko "certificado falhou:"; tail -n 15 /tmp/hc-certbot.txt | sed 's/^/   /'
fi

if $S test -f /etc/letsencrypt/live/$DOM/fullchain.pem; then
  echo "== 7. nginx (HTTPS) =="
  CONF443="
server {
    listen 443 ssl http2;
    server_name $DOM;
    ssl_certificate /etc/letsencrypt/live/$DOM/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOM/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    add_header Strict-Transport-Security \"max-age=31536000\" always;
    add_header X-Content-Type-Options \"nosniff\" always;
    server_tokens off;
    client_max_body_size 20M;
    location / {$PROXY
    }
}
"
  printf '%s\n%s\n' "$CONF80" "$CONF443" | $S tee /etc/nginx/sites-available/homecartoon >/dev/null
  $S nginx -t >/dev/null 2>&1 && $S systemctl reload nginx && ok "HTTPS ativo" || { ko "nginx -t falhou"; $S nginx -t; }
  $S systemctl list-timers 2>/dev/null | grep -q certbot && ok "renovacao automatica ativa" || ko "sem temporizador de renovacao"
  code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' --resolve "$DOM:443:127.0.0.1" "https://$DOM/web/")
  echo "   teste local https -> $code"
  code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$DOM/web/")
  echo "   teste pelo IP publico (loopback do router) -> $code"
fi

echo "== 8. Jellyfin atras do proxy =="
NX=/etc/jellyfin/network.xml
if $S test -f $NX; then
  if $S grep -q '<string>127.0.0.1</string>' $NX; then ok "KnownProxies ja tem 127.0.0.1"; else
    $S cp $NX $NX.bak-hc
    $S python3 - "$NX" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s2=re.sub(r'<KnownProxies\s*/>','<KnownProxies>\n    <string>127.0.0.1</string>\n  </KnownProxies>',s)
if s2==s: s2=re.sub(r'<KnownProxies>','<KnownProxies>\n    <string>127.0.0.1</string>',s,count=1)
if s2==s: s2=s.replace('</NetworkConfiguration>','  <KnownProxies>\n    <string>127.0.0.1</string>\n  </KnownProxies>\n</NetworkConfiguration>')
open(p,'w').write(s2)
PY
    $S systemctl restart jellyfin && ok "KnownProxies = 127.0.0.1, Jellyfin reiniciado"
  fi
  $S grep -E 'EnableRemoteAccess|KnownProxies|<string>' $NX | sed 's/^/   /'
else ko "nao encontrei $NX"; fi

echo "== FIM == relatorio em $LOG"
