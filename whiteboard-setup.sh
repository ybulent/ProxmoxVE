#!/usr/bin/env bash
#
# Enable the Jitsi Meet whiteboard (Excalidraw) on a self-hosted install.
# Run INSIDE the Jitsi LXC as root:   bash whiteboard-setup.sh [FQDN]
#
# Idempotent + makes .wbak backups. Reverts nginx if its config test fails.
set -euo pipefail

PORT=3002

# ---- detect FQDN ----------------------------------------------------------
if [[ -n "${1:-}" ]]; then
  FQDN="$1"
else
  FQDN="$(basename "$(ls /etc/jitsi/meet/*-config.js 2>/dev/null | head -n1)" -config.js)"
fi
CONFIG="/etc/jitsi/meet/${FQDN}-config.js"
NGINX="/etc/nginx/sites-available/${FQDN}.conf"
PROSODY="/etc/prosody/conf.avail/${FQDN}.cfg.lua"
echo ">> FQDN = $FQDN"
[[ -f "$CONFIG" ]]  || { echo "!! config.js not found: $CONFIG"; exit 1; }
[[ -f "$NGINX" ]]   || { echo "!! nginx vhost not found: $NGINX"; exit 1; }
[[ -f "$PROSODY" ]] || { echo "!! prosody config not found: $PROSODY"; exit 1; }

# ---- 1. excalidraw-backend (port 3002) ------------------------------------
echo ">> [1/5] excalidraw-backend"
command -v node >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y nodejs npm git; }
command -v git  >/dev/null 2>&1 || apt-get install -y git
[[ -d /opt/excalidraw-backend ]] || git clone --depth 1 https://github.com/jitsi/excalidraw-backend.git /opt/excalidraw-backend
cd /opt/excalidraw-backend
npm install
npm run build
cat >/etc/systemd/system/excalidraw-backend.service <<EOF
[Unit]
Description=Excalidraw backend (Jitsi whiteboard)
After=network.target

[Service]
WorkingDirectory=/opt/excalidraw-backend
Environment=NODE_ENV=production
Environment=PORT=${PORT}
ExecStart=/usr/bin/npm start
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now excalidraw-backend
sleep 2
systemctl is-active --quiet excalidraw-backend && echo "   backend active" || { echo "!! backend not active"; journalctl -u excalidraw-backend -n 15 --no-pager; }

# ---- 2. nginx  /socket.io/  ->  backend -----------------------------------
echo ">> [2/5] nginx /socket.io/"
if grep -q "location /socket.io/" "$NGINX"; then
  echo "   already present"
else
  cp "$NGINX" "$NGINX.wbak"
  # insert right after the TLS key line => guaranteed inside the 443 server block
  awk -v port="$PORT" '
    { print }
    /ssl_certificate_key/ && !done {
      print "    location /socket.io/ {"
      print "        proxy_http_version 1.1;"
      print "        proxy_set_header Upgrade $http_upgrade;"
      print "        proxy_set_header Connection \"upgrade\";"
      print "        proxy_set_header Host $http_host;"
      print "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
      print "        proxy_pass http://127.0.0.1:" port ";"
      print "    }"
      done=1
    }
  ' "$NGINX.wbak" >"$NGINX"
  if nginx -t 2>/dev/null; then echo "   added"; else echo "!! nginx test failed, reverting"; cp "$NGINX.wbak" "$NGINX"; fi
fi

# ---- 3. config.js  whiteboard ---------------------------------------------
# NOTE: the default config ships a COMMENTED "// whiteboard: {" block, so we
# must check for an ACTIVE (non-commented) block, not just the word.
echo ">> [3/5] config.js whiteboard"
if grep -qE '^[[:space:]]*whiteboard:[[:space:]]*\{' "$CONFIG"; then
  echo "   already enabled"
else
  cp "$CONFIG" "$CONFIG.wbak"
  awk -v fqdn="$FQDN" '
    { print }
    /^var config = \{/ && !done {
      print "    whiteboard: { enabled: true, collabServerBaseUrl: \"https://" fqdn "\" },"
      done=1
    }
  ' "$CONFIG.wbak" >"$CONFIG"
  grep -qE '^[[:space:]]*whiteboard:[[:space:]]*\{' "$CONFIG" && echo "   enabled" || { echo "!! insert failed, reverting"; cp "$CONFIG.wbak" "$CONFIG"; }
fi

# ---- 4. prosody  room_metadata component ----------------------------------
# The module ships as mod_room_metadata_component.lua and is loaded via a
# Component (NOT via modules_enabled). Add the vhost setting + one Component.
echo ">> [4/5] prosody room_metadata"
if grep -q "room_metadata_component" "$PROSODY"; then
  echo "   already present"
else
  cp "$PROSODY" "$PROSODY.wbak"
  awk -v host="$FQDN" '
    BEGIN{ invh=0 }
    /^VirtualHost /{ invh = ($0 ~ ("\"" host "\"")) ? 1 : 0 }
    /^Component /{ invh=0 }
    { print }
    invh==1 && /^VirtualHost / && !vh_done {
      print "    room_metadata_component = \"metadata." host "\""
      print "    main_muc = \"conference." host "\""
      vh_done=1
    }
    END{
      print ""
      print "Component \"metadata." host "\" \"room_metadata_component\""
      print "    muc_component = \"conference." host "\""
    }
  ' "$PROSODY.wbak" >"$PROSODY"
  echo "   added (setting + single Component)"
fi

# ---- 5. restart -----------------------------------------------------------
echo ">> [5/5] restarting services"
systemctl reload nginx || systemctl restart nginx
systemctl restart prosody jicofo jitsi-videobridge2
sleep 2
echo ""
echo "=== status ==="
for s in excalidraw-backend prosody jicofo jitsi-videobridge2 nginx; do
  printf "%-22s %s\n" "$s" "$(systemctl is-active "$s")"
done
echo "backend port:"; ss -tlnp | grep ":$PORT" || echo "  NOT listening on $PORT"
journalctl -u prosody -n 20 --no-pager | grep -iE "error|already defined" | tail -5 || true
echo ""
echo "Done. Hard-refresh the browser (Ctrl+F5). The whiteboard is under the"
echo "'...' (More actions) menu and is available to the MODERATOR (first person in)."
