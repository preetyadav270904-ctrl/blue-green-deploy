#!/usr/bin/env bash

set -euo pipefail

RAW_VERSION="${1:-v1.0.0}"
TARGET_VERSION="${RAW_VERSION:0:11}"
CHAOS_MODE="${2:-healthy}"
IMAGE_NAME="blue-green-app:${TARGET_VERSION}"
UPSTREAM_CONF="/etc/nginx/conf.d/active_upstream.conf"

echo "=================================================="
echo "Starting Blue/Green Deployment for: ${IMAGE_NAME}"
echo "Mode: ${CHAOS_MODE}"
echo "=================================================="

# Check if config exists in /etc/nginx/conf.d (host mode) or locally (fallback)
if [ ! -f "$UPSTREAM_CONF" ]; then
  UPSTREAM_CONF="nginx/active_upstream.conf"
fi

# State detection
CURRENT_UPSTREAM=$(cat "$UPSTREAM_CONF")

if grep -q "8081" <<< "$CURRENT_UPSTREAM"; then
  ACTIVE_SLOT="blue"
  IDLE_SLOT="green"
  IDLE_PORT="8082"
  IDLE_SERVICE="app_green"
elif grep -q "8082" <<< "$CURRENT_UPSTREAM"; then
  ACTIVE_SLOT="green"
  IDLE_SLOT="blue"
  IDLE_PORT="8081"
  IDLE_SERVICE="app_blue"
else
  echo "[ERROR] Could not determine active slot from $UPSTREAM_CONF"
  exit 1
fi

echo "[INFO] Currently Active Slot : ${ACTIVE_SLOT}"
echo "[INFO] Target Deployment Slot: ${IDLE_SLOT} (Port: ${IDLE_PORT})"

# Helper function to invoke docker compose
compose_cmd() {
  docker compose "$@" 2>/dev/null || docker-compose "$@"
}

# Build application image
echo "[INFO] Building Docker image ${IMAGE_NAME}..."
docker build -t "${IMAGE_NAME}" app/

# Spin up idle container
echo "[INFO] Deploying container for slot: ${IDLE_SLOT}..."
export FAIL_HEALTH="false"
if [ "${CHAOS_MODE}" == "broken" ]; then
  echo "[WARN] Injecting intentional failure mode into ${IDLE_SLOT}!"
  export FAIL_HEALTH="true"
fi

if [ "${IDLE_SLOT}" == "green" ]; then
  export APP_GREEN_IMAGE="${IMAGE_NAME}"
  export GREEN_VERSION="${TARGET_VERSION}"
else
  export APP_BLUE_IMAGE="${IMAGE_NAME}"
  export BLUE_VERSION="${TARGET_VERSION}"
fi

compose_cmd up -d --no-deps --force-recreate "${IDLE_SERVICE}"

# Pre-Cutover Verification Loop
echo "[INFO] Probing idle slot on http://127.0.0.1:${IDLE_PORT}/health..."

MAX_RETRIES=10
RETRY_INTERVAL=2
HEALTHY=false

for ((i=1; i<=MAX_RETRIES; i++)); do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${IDLE_PORT}/health" || true)

  if [ "$HTTP_STATUS" -eq 200 ]; then
    echo "[SUCCESS] Pre-cutover probe passed on attempt ${i}/${MAX_RETRIES} (HTTP 200)"
    HEALTHY=true
    break
  fi

  echo "Attempt ${i}/${MAX_RETRIES}: Received HTTP ${HTTP_STATUS}. Retrying in ${RETRY_INTERVAL}s..."
  sleep $RETRY_INTERVAL
done

# Pre-cutover failure handling
if [ "$HEALTHY" = false ]; then
  echo "--------------------------------------------------"
  echo "[ALERT] Health check failed! Initiating Pre-Cutover Abort..."
  echo "[ALERT] Tearing down unhealthy ${IDLE_SLOT} slot..."
  compose_cmd stop "${IDLE_SERVICE}"
  compose_cmd rm -f "${IDLE_SERVICE}"
  echo "[SAFE] Active traffic was NEVER shifted. Live slot remains: ${ACTIVE_SLOT}"
  echo "--------------------------------------------------"
  exit 1
fi

# Reload function checking whether to run systemd or docker
reload_nginx() {
  if systemctl is-active --quiet nginx 2>/dev/null; then
    sudo systemctl reload nginx
  else
    docker exec reverse_proxy nginx -s reload
  fi
}

# Execute Traffic Cutover
echo "[INFO] Switching Nginx traffic pointer to ${IDLE_SLOT} (Port: ${IDLE_PORT})..."
echo "server 127.0.0.1:${IDLE_PORT} max_fails=3 fail_timeout=10s;" > "$UPSTREAM_CONF"
reload_nginx

# Post-Cutover Synthetic Monitoring
echo "[INFO] Performing post-cutover synthetic checks on public proxy (port 80)..."
MONITOR_REQUESTS=5
POST_CHECK_PASSED=true

for ((j=1; j<=MONITOR_REQUESTS; j++)); do
  LIVE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:80/" || true)
  if [ "$LIVE_STATUS" -ge 500 ]; then
    echo "[ERROR] Post-cutover request ${j} returned 5xx error: HTTP ${LIVE_STATUS}"
    POST_CHECK_PASSED=false
    break
  fi
  sleep 1
done

if [ "$POST_CHECK_PASSED" = false ]; then
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "[EMERGENCY] Post-cutover failure detected!"
  echo "[ROLLBACK] Reverting Nginx upstream immediately back to: ${ACTIVE_SLOT}"

  if [ "${ACTIVE_SLOT}" == "blue" ]; then
    ACTIVE_PORT="8081"
  else
    ACTIVE_PORT="8082"
  fi

  echo "server 127.0.0.1:${ACTIVE_PORT} max_fails=3 fail_timeout=10s;" > "$UPSTREAM_CONF"
  reload_nginx

  echo "[ROLLBACK] Decommissioning broken ${IDLE_SLOT} container..."
  compose_cmd stop "${IDLE_SERVICE}"
  compose_cmd rm -f "${IDLE_SERVICE}"
  echo "[SAFE] Rollback complete. Live slot restored to: ${ACTIVE_SLOT}"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  exit 1
fi

# Decommission old slot
echo "[INFO] Decommissioning old slot (${ACTIVE_SLOT}) to release system resources..."
compose_cmd stop "app_${ACTIVE_SLOT}"
compose_cmd rm -f "app_${ACTIVE_SLOT}"

echo "=================================================="
echo "Deployment successful! Active slot is now: ${IDLE_SLOT} (${TARGET_VERSION})"
echo "=================================================="