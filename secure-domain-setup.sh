#!/usr/bin/env bash
#
# Lock down a self-hosted Jitsi Meet so only authenticated users can CREATE
# rooms (guests can still join once a moderator opens the room). "Secure Domain".
# Run INSIDE the Jitsi LXC as root:   bash secure-domain-setup.sh [FQDN]
#
# Idempotent + makes .sbak backups.
set -euo pipefail

# ---- detect FQDN ----------------------------------------------------------
if [[ -n "${1:-}" ]]; then
  FQDN="$1"
else
  FQDN="$(basename "$(ls /etc/jitsi/meet/*-config.js 2>/dev/null | head -n1)" -config.js)"
fi
CONFIG="/etc/jitsi/meet/${FQDN}-config.js"
PROSODY="/etc/prosody/conf.avail/${FQDN}.cfg.lua"
JICOFO="/etc/jitsi/jicofo/jicofo.conf"
GUEST="guest.${FQDN}"
echo ">> FQDN = $FQDN"
[[ -f "$CONFIG" ]]  || { echo "!! config.js not found: $CONFIG"; exit 1; }
[[ -f "$PROSODY" ]] || { echo "!! prosody config not found: $PROSODY"; exit 1; }

# ---- 1. prosody: internal_hashed on main vhost + anonymous guest vhost -----
echo ">> [1/4] prosody authentication"
if grep -q "VirtualHost \"${GUEST}\"" "$PROSODY"; then
  echo "   already configured"
else
  cp "$PROSODY" "$PROSODY.sbak"
  awk -v host="$FQDN" -v guest="$GUEST" '
    /^VirtualHost /{ invh = ($0 ~ ("\"" host "\"")) ? 1 : 0 }
    /^Component /{ invh=0 }
    # inside the MAIN vhost, force hashed auth
    invh==1 && $0 ~ /^[[:space:]]*authentication[[:space:]]*=/ {
      print "    authentication = \"internal_hashed\""; next
    }
    { print }
    END{
      print ""
      print "VirtualHost \"" guest "\""
      print "    authentication = \"jitsi-anonymous\""
      print "    c2s_require_encryption = false"
    }
  ' "$PROSODY.sbak" >"$PROSODY"
  echo "   set internal_hashed + added guest vhost ${GUEST}"
fi

# ---- 2. config.js: anonymousdomain ----------------------------------------
echo ">> [2/4] config.js anonymousdomain"
if grep -q "anonymousdomain" "$CONFIG"; then
  echo "   already present"
else
  cp "$CONFIG" "$CONFIG.sbak"
  awk -v host="$FQDN" -v guest="$GUEST" '
    { print }
    index($0, "domain: \047" host "\047") && !d && index($0,"anonymousdomain")==0 {
      print "        anonymousdomain: \047" guest "\047,"
      d=1
    }
  ' "$CONFIG.sbak" >"$CONFIG"
  grep -q "anonymousdomain" "$CONFIG" && echo "   added" || { echo "!! insert failed, reverting"; cp "$CONFIG.sbak" "$CONFIG"; }
fi

# ---- 3. jicofo.conf: authentication block ---------------------------------
echo ">> [3/4] jicofo authentication"
if [[ ! -f "$JICOFO" ]]; then
  printf 'jicofo {\n}\n' >"$JICOFO"
fi
if grep -q "login-url" "$JICOFO"; then
  echo "   already present"
else
  cp "$JICOFO" "$JICOFO.sbak"
  awk -v host="$FQDN" '
    { print }
    /^jicofo[[:space:]]*\{/ && !d {
      print "  authentication: {"
      print "    enabled: true"
      print "    type: XMPP"
      print "    login-url: \"" host "\""
      print "  }"
      d=1
    }
  ' "$JICOFO.sbak" >"$JICOFO"
  echo "   added authentication block"
fi

# ---- 4. restart -----------------------------------------------------------
echo ">> [4/4] restarting services"
systemctl restart prosody
sleep 2
systemctl restart jicofo jitsi-videobridge2
echo ""
echo "=== status ==="
for s in prosody jicofo jitsi-videobridge2; do
  printf "%-20s %s\n" "$s" "$(systemctl is-active "$s")"
done
journalctl -u prosody -n 15 --no-pager | grep -iE "error|already defined" | tail -5 || true

# ---- create a login -------------------------------------------------------
echo ""
echo "Now create at least one login (needed to open rooms)."
read -rp "Username (leave empty to skip and add later): " SDUSER
if [[ -n "$SDUSER" ]]; then
  read -rsp "Password: " SDPASS; echo
  if prosodyctl register "$SDUSER" "$FQDN" "$SDPASS"; then
    echo "   user '$SDUSER' created."
  else
    echo "!! registration failed."
  fi
fi

cat <<EOF

Done. Reload the browser (Ctrl+F5).
- Opening a NEW room now prompts for username/password (moderator).
- Guests can join an already-open room without logging in.

Manage users later:
  prosodyctl register   <user> ${FQDN} <password>   # add / change
  prosodyctl unregister <user> ${FQDN}              # remove
EOF
