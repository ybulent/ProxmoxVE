#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Bulent (ybulent)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/jitsi/jitsi-meet
#
# Installs Jitsi Meet with a SELF-SIGNED certificate (Cloudflare terminates TLS
# at the edge) and connects the container to Cloudflare via a cloudflared tunnel.
# Media (UDP 10000) is NOT carried by the tunnel and must be forwarded directly.

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ------------------------------------------------------------------------------
# Configuration
# Non-interactive overrides: JITSI_FQDN, CF_TUNNEL_TOKEN, PUBLIC_IP
# ------------------------------------------------------------------------------
JITSI_FQDN="${JITSI_FQDN:-}"
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
PUBLIC_IP="${PUBLIC_IP:-}"

if [[ -z "$JITSI_FQDN" ]]; then
  while :; do
    if ! JITSI_FQDN=$(whiptail --backtitle "Jitsi Meet" --title "Public Hostname (FQDN)" \
      --inputbox "Enter the public hostname that Cloudflare will serve.\n\nThis must match the Public Hostname you configure on the Cloudflare Tunnel.\n\nExample: meet.example.com" \
      13 72 "meet.example.com" 3>&1 1>&2 2>&3); then
      msg_error "Setup cancelled by user."
      exit 1
    fi
    JITSI_FQDN="$(echo -e "${JITSI_FQDN}" | tr -d '[:space:]')"
    if [[ "$JITSI_FQDN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; then
      break
    fi
    whiptail --backtitle "Jitsi Meet" --title "Invalid FQDN" \
      --msgbox "'$JITSI_FQDN' is not a valid FQDN.\nPlease enter something like meet.example.com" 9 60
  done
fi

if [[ -z "$CF_TUNNEL_TOKEN" ]]; then
  if ! CF_TUNNEL_TOKEN=$(whiptail --backtitle "Jitsi Meet" --title "Cloudflare Tunnel Token" \
    --passwordbox "Paste your Cloudflare Tunnel token.\n\nCloudflare Zero Trust > Networks > Tunnels > (create/select) > Install connector — copy the token (the long string after 'service install').\n\nLeave empty to install cloudflared now and connect it later." \
    14 74 3>&1 1>&2 2>&3); then
    CF_TUNNEL_TOKEN=""
  fi
  CF_TUNNEL_TOKEN="$(echo -e "${CF_TUNNEL_TOKEN}" | tr -d '[:space:]')"
fi

JITSI_HOST="${JITSI_FQDN%%.*}"
LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="$(curl -fsSL https://api.ipify.org 2>/dev/null || true)"
fi

msg_info "Installing Dependencies"
$STD apt install -y \
  gnupg2 \
  nginx-full \
  apt-transport-https \
  ca-certificates \
  lsb-release \
  curl
msg_ok "Installed Dependencies"

msg_info "Setting Hostname to $JITSI_FQDN"
echo "$JITSI_FQDN" >/etc/hostname
hostname "$JITSI_FQDN" 2>/dev/null || true
if ! grep -q "$JITSI_FQDN" /etc/hosts; then
  echo "127.0.1.1 $JITSI_FQDN $JITSI_HOST" >>/etc/hosts
fi
msg_ok "Set Hostname"

msg_info "Setting up Prosody Repository"
curl -fsSL https://prosody.im/files/prosody-debian-packages.key \
  -o /usr/share/keyrings/prosody-debian-packages.key
echo "deb [signed-by=/usr/share/keyrings/prosody-debian-packages.key] http://packages.prosody.im/debian $(lsb_release -sc) main" \
  >/etc/apt/sources.list.d/prosody-debian-packages.list
$STD apt update
$STD apt install -y lua5.2
msg_ok "Set up Prosody Repository"

msg_info "Setting up Jitsi Repository"
curl -fsSL https://download.jitsi.org/jitsi-key.gpg.key |
  gpg --dearmor -o /usr/share/keyrings/jitsi-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/jitsi-keyring.gpg] https://download.jitsi.org stable/" \
  >/etc/apt/sources.list.d/jitsi-stable.list
$STD apt update
msg_ok "Set up Jitsi Repository"

msg_info "Installing Jitsi Meet (this can take a few minutes)"
# Cloudflare provides the public certificate, so the origin uses a self-signed
# certificate. cloudflared connects to it with "No TLS Verify".
echo "jitsi-videobridge jitsi-videobridge/jvb-hostname string $JITSI_FQDN" | debconf-set-selections
echo "jitsi-meet-web-config jitsi-meet/jvb-hostname string $JITSI_FQDN" | debconf-set-selections
echo "jitsi-meet-web-config jitsi-meet/cert-choice select Generate a new self-signed certificate (You will later get a chance to obtain a Let's encrypt certificate)" | debconf-set-selections
export DEBIAN_FRONTEND=noninteractive
$STD apt install -y jitsi-meet
unset DEBIAN_FRONTEND
msg_ok "Installed Jitsi Meet"

msg_info "Ensuring nginx web vhost"
# The jitsi-meet-web-config postinst sometimes skips creating the nginx vhost
# under a non-interactive install, which leaves nothing listening on 443.
# Instantiate it from the shipped template if it is missing.
if [[ ! -e "/etc/nginx/sites-enabled/${JITSI_FQDN}.conf" ]]; then
  if [[ ! -s "/etc/jitsi/meet/${JITSI_FQDN}.crt" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout "/etc/jitsi/meet/${JITSI_FQDN}.key" \
      -out "/etc/jitsi/meet/${JITSI_FQDN}.crt" -subj "/CN=${JITSI_FQDN}" 2>/dev/null
  fi
  if [[ -f /usr/share/jitsi-meet-web-config/jitsi-meet.example ]]; then
    cp /usr/share/jitsi-meet-web-config/jitsi-meet.example "/etc/nginx/sites-available/${JITSI_FQDN}.conf"
    sed -i "s/jitsi-meet\.example\.com/${JITSI_FQDN}/g" "/etc/nginx/sites-available/${JITSI_FQDN}.conf"
    ln -sf "/etc/nginx/sites-available/${JITSI_FQDN}.conf" "/etc/nginx/sites-enabled/${JITSI_FQDN}.conf"
    nginx -t 2>/dev/null && systemctl reload nginx
  fi
fi
msg_ok "Ensured nginx web vhost (443 listening)"

msg_info "Configuring Videobridge for direct UDP media"
# The browser reaches the videobridge directly at <public-ip>:10000/udp, so JVB
# must advertise the public address in its ICE candidates.
JVB_PROPS="/etc/jitsi/videobridge/sip-communicator.properties"
touch "$JVB_PROPS"
sed -i '/NAT_HARVESTER_LOCAL_ADDRESS/d;/NAT_HARVESTER_PUBLIC_ADDRESS/d' "$JVB_PROPS"
if [[ -n "$LOCAL_IP" ]]; then
  echo "org.ice4j.ice.harvest.NAT_HARVESTER_LOCAL_ADDRESS=${LOCAL_IP}" >>"$JVB_PROPS"
fi
if [[ -n "$PUBLIC_IP" ]]; then
  echo "org.ice4j.ice.harvest.NAT_HARVESTER_PUBLIC_ADDRESS=${PUBLIC_IP}" >>"$JVB_PROPS"
fi
systemctl restart jitsi-videobridge2 2>/dev/null || true
msg_ok "Configured Videobridge (local ${LOCAL_IP:-?}, public ${PUBLIC_IP:-auto/STUN})"

msg_info "Installing cloudflared"
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  -o /usr/share/keyrings/cloudflare-main.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -sc) main" \
  >/etc/apt/sources.list.d/cloudflared.list
$STD apt update
$STD apt install -y cloudflared
msg_ok "Installed cloudflared"

if [[ -n "$CF_TUNNEL_TOKEN" ]]; then
  msg_info "Connecting Cloudflare Tunnel"
  $STD cloudflared service install "$CF_TUNNEL_TOKEN"
  systemctl enable -q --now cloudflared 2>/dev/null || true
  msg_ok "Connected Cloudflare Tunnel"
else
  msg_error "No Cloudflare token given — cloudflared is installed but not connected."
  echo -e "${YW}  Connect it later from inside the container with:${CL}"
  echo -e "  cloudflared service install <YOUR_TUNNEL_TOKEN>\n"
fi

msg_info "Saving Deployment Info"
{
  echo "Jitsi Meet + Cloudflare Tunnel"
  echo "Public URL:   https://$JITSI_FQDN   (served by Cloudflare)"
  echo "Container IP: ${LOCAL_IP:-unknown}"
  echo "Public IP:    ${PUBLIC_IP:-unknown}"
  echo ""
  echo "Cloudflare Zero Trust > Tunnels > (your tunnel) > Public Hostname:"
  echo "  Subdomain/Domain : $JITSI_FQDN"
  echo "  Type / URL       : HTTPS  ->  localhost:443"
  echo "  Additional application settings > TLS > No TLS Verify : ON"
  echo ""
  echo "Router port-forward (REQUIRED for audio/video):"
  echo "  UDP 10000  ->  ${LOCAL_IP:-<container-ip>}   (Jitsi Videobridge media)"
  echo ""
  echo "No inbound TCP 80/443 forward is needed (Cloudflare Tunnel handles web)."
} >~/jitsi.creds
msg_ok "Saved Deployment Info to ~/jitsi.creds"

motd_ssh
customize
cleanup_lxc
