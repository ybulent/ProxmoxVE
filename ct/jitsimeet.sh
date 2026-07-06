#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/ybulent/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Bulent (ybulent)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/jitsi/jitsi-meet
#
# Jitsi Meet in an LXC, published through a Cloudflare Tunnel (cloudflared).
# Web/signalling goes over the tunnel; media (UDP 10000) is forwarded directly.

APP="Jitsi Meet"
var_tags="${var_tags:-communication;video;cloudflare}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-12}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /etc/jitsi ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  msg_info "Updating $APP LXC (Jitsi + cloudflared)"
  $STD apt update
  $STD apt -y upgrade
  msg_ok "Updated $APP LXC"
  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Web is published by Cloudflare — no inbound TCP 80/443 forward needed.${CL}"
echo -e "${INFO}${YW} In Cloudflare Zero Trust, point your hostname to ${BGN}https://localhost:443${CL}${YW} (No TLS Verify: ON).${CL}"
echo -e "${INFO}${YW} For audio/video, forward ${BGN}UDP 10000${CL}${YW} on your router to this container.${CL}"
echo -e "${INFO}${YW} Details saved inside the container at ${BGN}~/jitsi.creds${CL}"
