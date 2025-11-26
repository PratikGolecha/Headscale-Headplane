#!/bin/bash

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root." 
   exit 1
fi

# Prompt the user for the full domain (including subdomain)
read -p "Enter your full domain (e.g., headscale.example.com): " FULL_DOMAIN

# Create directory structure
mkdir -p headscale/data headscale/configs/headscale headscale/headplane/data

########################################
# DOCKER COMPOSE (HEADSCALE + HEADPLANE)
########################################
cat <<EOF > headscale/docker-compose.yaml
services:
  headscale:
    image: 'headscale/headscale:latest'
    container_name: 'headscale'
    restart: 'unless-stopped'
    command: 'serve'
    volumes:
      - './data:/var/lib/headscale'
      - './configs/headscale:/etc/headscale'
    environment:
      TZ: 'Asia/Kolkata'
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.headscale.rule=Host(\`$FULL_DOMAIN\`)"
      - "traefik.http.routers.headscale.entrypoints=websecure"
      - "traefik.http.routers.headscale.tls.certresolver=myresolver"
      - "traefik.http.routers.headscale.tls=true"
      - "traefik.http.services.headscale.loadbalancer.server.port=8080"

  headplane:
    image: 'ghcr.io/tale/headplane:latest'
    container_name: 'headplane'
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - './headplane/config.yaml:/etc/headplane/config.yaml'
      - './headplane/data:/var/lib/headplane'
      - './configs/headscale:/etc/headscale'
      - './data:/var/lib/headscale'
      - '/var/run/docker.sock:/var/run/docker.sock:ro'
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.headplane.rule=Host(\`$FULL_DOMAIN\`) && PathPrefix(\`/admin\`)"
      - "traefik.http.routers.headplane.entrypoints=websecure"
      - "traefik.http.routers.headplane.tls=true"
      - "traefik.http.services.headplane.loadbalancer.server.port=3000"

  traefik:
    image: "traefik:latest"
    container_name: "traefik"
    command:
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entryPoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entryPoints.websecure.address=:443"
      - "--certificatesresolvers.myresolver.acme.httpchallenge=true"
      - "--certificatesresolvers.myresolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.myresolver.acme.email=you@yourdomain.com"
      - "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "./letsencrypt:/letsencrypt"
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
EOF

########################################
# HEADSCALE CONFIG FILE
########################################
cat <<EOF > headscale/configs/headscale/config.yaml
server_url: https://$FULL_DOMAIN
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false
noise:
  private_key_path: /var/lib/headscale/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
derp:
  server:
    enabled: true
    region_id: 999
    region_code: "headscale"
    region_name: "Headscale Embedded DERP"
    stun_listen_addr: "0.0.0.0:3478"
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
    ipv4: 1.2.3.4
    ipv6: 2001:db8::1
  urls:
    - https://controlplane.tailscale.com/derpmap/default
EOF

########################################
# HEADPLANE CONFIG
########################################
cat <<EOF > headscale/headplane/config.yaml
server:
  host: "0.0.0.0"
  port: 3000
  cookie_secret: "12345678901234567890123456789012"
  cookie_secure: true
  data_path: "/var/lib/headplane"

headscale:
  url: "https://$FULL_DOMAIN"
  config_path: "/etc/headscale/config.yaml"
  config_strict: true

integration:
  docker:
    enabled: true
    container_label: "me.tale.headplane.target=headscale"
    socket: "unix:///var/run/docker.sock"
EOF

echo "Starting Headscale + Headplane..."
docker compose -f headscale/docker-compose.yaml up -d || exit 1

sleep 10

API_KEY=$(docker exec headscale headscale apikey create)

echo ""
echo "=========================================="
echo " ✅ Headplane Installed Successfully!"
echo "=========================================="
echo "Login URL: https://$FULL_DOMAIN/admin"
echo "API Key: $API_KEY"
echo ""
echo "Use this API key in the Headplane login form."
echo ""
