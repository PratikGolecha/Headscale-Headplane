#!/bin/bash

set -e

# Must run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo ./headscale.sh)."
   exit 1
fi

echo "============================================"
echo " Headscale + Headplane + Traefik Installer"
echo "============================================"
echo ""

read -p "Enter your full Headscale domain (e.g., headscale.yourdomain.com): " FULL_DOMAIN
read -p "Enter MagicDNS base domain (e.g., vpn.yourdomain.com): " MAGIC_DOMAIN
read -p "Enter your email for Let's Encrypt (ACME): " ACME_EMAIL

if [[ -z "$FULL_DOMAIN" || -z "$MAGIC_DOMAIN" || -z "$ACME_EMAIL" ]]; then
  echo "Domain, MagicDNS base domain, and email are all required."
  exit 1
fi

# Generate a 32-char cookie secret (fallback to fixed if /dev/urandom fails)
COOKIE_SECRET=$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32 || echo "12345678901234567890123456789012")

echo ""
echo "Using Headscale domain:      $FULL_DOMAIN"
echo "Using MagicDNS base domain:  $MAGIC_DOMAIN"
echo "Using ACME email:            $ACME_EMAIL"
echo "Generated cookie secret:     $COOKIE_SECRET"
echo ""

# Create required folders
mkdir -p headscale/data headscale/configs/headscale headscale/configs/headplane headscale/letsencrypt

cd headscale

########################################
# docker-compose.yaml
########################################
cat <<EOF > docker-compose.yaml
services:
  headscale:
    image: 'headscale/headscale:latest'
    container_name: 'headscale'
    restart: 'unless-stopped'
    command: 'serve'
    ports:
      - "3478:3478/udp"
    volumes:
      - './data:/var/lib/headscale'
      - './configs/headscale:/etc/headscale'
    environment:
      TZ: 'Asia/Kolkata'

    # labels for traefik reverse proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.headscale.rule=Host(\`$FULL_DOMAIN\`)"
      - "traefik.http.routers.headscale.tls.certresolver=myresolver"
      - "traefik.http.routers.headscale.entrypoints=websecure"
      - "traefik.http.routers.headscale.tls=true"
      - "traefik.http.services.headscale.loadbalancer.server.port=8080"

  headplane:
    container_name: headplane
    image: ghcr.io/tale/headplane:latest
    restart: unless-stopped
    volumes:
      - './data:/var/lib/headscale'
      - './configs/headscale:/etc/headscale'
      - './configs/headplane:/etc/headplane'
      - '/var/run/docker.sock:/var/run/docker.sock:ro'
    environment:
      # Required for Headplane
      COOKIE_SECRET: '$COOKIE_SECRET'
      HEADSCALE_INTEGRATION: 'docker'
      HEADSCALE_CONTAINER: 'headscale'
      DISABLE_API_KEY_LOGIN: 'false'
      HOST: '0.0.0.0'
      PORT: '3000'

      # Only set this to false if you aren't behind a reverse proxy
      COOKIE_SECURE: 'true'

    # labels for traefik reverse proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.headplane.rule=Host(\`$FULL_DOMAIN\`) && PathPrefix(\`/admin\`)"
      - "traefik.http.routers.headplane.entrypoints=websecure"
      - "traefik.http.routers.headplane.tls=true"
      - "traefik.http.services.headplane.loadbalancer.server.port=3000"

  traefik:
    image: "traefik:v3.3"
    container_name: "traefik"
    restart: 'unless-stopped'
    command:
      #- "--log.level=DEBUG"
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entryPoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entryPoints.websecure.address=:443"
      - "--certificatesresolvers.myresolver.acme.httpchallenge=true"
      - "--certificatesresolvers.myresolver.acme.httpchallenge.entrypoint=web"
      #- "--certificatesresolvers.myresolver.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory"
      - "--certificatesresolvers.myresolver.acme.email=$ACME_EMAIL"
      - "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "./letsencrypt:/letsencrypt"
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
EOF

########################################
# Headplane config.yaml
########################################
cat <<EOF > configs/headplane/config.yaml
# Configuration for the Headplane server and web application
server:
  host: "0.0.0.0"
  port: 3000

  # The secret used to encode and decode web sessions
  cookie_secret: "$COOKIE_SECRET"

  # Should the cookies only work over HTTPS?
  cookie_secure: true

# Headscale specific settings to allow Headplane to talk to Headscale
headscale:
  # Internal HTTP endpoint (inside Docker network)
  url: "http://headscale:8080"

  # Public URL for UI links, etc.
  public_url: "https://$FULL_DOMAIN"

  # Path to the Headscale configuration file
  config_path: "/etc/headscale/config.yaml"
  config_strict: true

# Integration configurations for Headplane to interact with Headscale
integration:
  docker:
    enabled: true
    container_name: "headscale"
    socket: "unix:///var/run/docker.sock"
  kubernetes:
    enabled: false
    validate_manifest: true
    pod_name: "headscale"
  proc:
    enabled: false

# OIDC Configuration (optional, placeholders)
oidc:
  issuer: "https://accounts.google.com"
  client_id: "your-client-id"
  client_secret: "<your-client-secret>"
  disable_api_key_login: false
  token_endpoint_auth_method: "client_secret_post"
  headscale_api_key: "<your-headscale-api-key>"
  redirect_uri: "https://$FULL_DOMAIN/admin/oidc/callback"
EOF

########################################
# Headscale config.yaml
########################################
cat <<EOF > configs/headscale/config.yaml
---
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
  paths: []
  auto_update_enabled: true
  update_frequency: 24h

disable_check_updates: false
ephemeral_node_inactivity_timeout: 30m

database:
  type: sqlite
  debug: false
  gorm:
    prepare_stmt: true
    parameterized_queries: true
    skip_err_record_not_found: true
    slow_threshold: 1000
  sqlite:
    path: /var/lib/headscale/db.sqlite
    write_ahead_log: true
    wal_autocheckpoint: 1000

acme_url: https://acme-v02.api.letsencrypt.org/directory
acme_email: ""
tls_letsencrypt_hostname: ""
tls_letsencrypt_cache_dir: /var/lib/headscale/cache
tls_letsencrypt_challenge_type: HTTP-01
tls_letsencrypt_listen: ":http"
tls_cert_path: ""
tls_key_path: ""

log:
  format: text
  level: info

policy:
  mode: database
  path: ""

dns:
  magic_dns: true
  base_domain: $MAGIC_DOMAIN
  nameservers:
    global:
      - 1.1.1.1
      - 1.0.0.1
      - 2606:4700:4700::1111
      - 2606:4700:4700::1001
    split: {}
  search_domains: []
  extra_records: []

unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"

logtail:
  enabled: false

randomize_client_port: false
EOF

echo ""
echo "Bringing up docker stack (headscale + headplane + traefik)..."
docker compose up -d

echo "Waiting a bit for Headscale to start..."
sleep 10

echo "Attempting to create an API key..."
API_KEY=$(docker exec headscale headscale apikeys create --expiration 999d 2>/dev/null || true)
if [[ -z "$API_KEY" ]]; then
  API_KEY=$(docker exec headscale headscale apikey create 2>/dev/null || true)
fi

echo ""
echo "=========================================="
echo " ✅ Deployment complete"
echo "=========================================="
echo "Headplane URL:       https://$FULL_DOMAIN/admin"
echo "Headscale URL:       https://$FULL_DOMAIN"
echo "MagicDNS base FQDN:  $MAGIC_DOMAIN"
echo ""
if [[ -n "$API_KEY" ]]; then
  echo "Headscale API Key (use in Headplane or OIDC if needed):"
  echo "$API_KEY"
else
  echo "API key could not be created automatically."
  echo "Once Headscale is up, run this manually:"
  echo "  docker exec headscale headscale apikeys create --expiration 999d"
fi
echo ""
echo "Headplane config:   headscale/configs/headplane/config.yaml"
echo "Headscale config:   headscale/configs/headscale/config.yaml"
echo ""
