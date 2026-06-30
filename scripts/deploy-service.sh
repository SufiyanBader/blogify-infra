#!/bin/bash
# =============================================================================
# Blue-Green deployment for ONE microservice.
# Usage: ./deploy-service.sh <service_name> <image> <port_blue> <port_green> [env_file]
# Example:
#   ./deploy-service.sh posts sufiyanbader/blogify-posts:abc1234 4201 4202 /opt/blogify/posts.env
# =============================================================================

set -euo pipefail

SERVICE=$1
IMAGE=$2
PORT_BLUE=$3
PORT_GREEN=$4
ENV_FILE=${5:-}

NGINX_CONF_DIR="/etc/nginx/conf.d"
HEALTH_RETRIES=10
HEALTH_WAIT=5

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()     { echo -e "${NC}[$(date '+%H:%M:%S')] [$SERVICE] $*"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] [$SERVICE] ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] [$SERVICE] ⚠ $*${NC}"; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] [$SERVICE] ✗ $*${NC}"; exit 1; }

UPSTREAM_NAME="${SERVICE//-/_}_active"

get_active_slot() {
    local conf="${NGINX_CONF_DIR}/${SERVICE}-active.conf"
    if [ -f "$conf" ] && grep -q "${PORT_BLUE}" "$conf"; then
        echo "blue"
    else
        echo "green"
    fi
}

health_check() {
    local port=$1
    local retries=$HEALTH_RETRIES
    log "Waiting for health on port ${port}..."
    while [ $retries -gt 0 ]; do
        if curl -sf "http://127.0.0.1:${port}/health" > /dev/null 2>&1; then
            success "Health check passed on port ${port}"
            return 0
        fi
        retries=$((retries - 1))
        warn "Not healthy yet. Retrying in ${HEALTH_WAIT}s ($retries left)"
        sleep $HEALTH_WAIT
    done
    return 1
}

main() {
    log "Deploying image: ${IMAGE}"
    ACTIVE=$(get_active_slot)
    log "Current active slot: ${ACTIVE}"

    if [ "${ACTIVE}" = "blue" ]; then
        NEW_SLOT="green"; NEW_PORT=$PORT_GREEN
        OLD_SLOT="blue";  OLD_PORT=$PORT_BLUE
    else
        NEW_SLOT="blue";  NEW_PORT=$PORT_BLUE
        OLD_SLOT="green"; OLD_PORT=$PORT_GREEN
    fi

    log "Target slot: ${NEW_SLOT} (port ${NEW_PORT})"

    log "Pulling ${IMAGE}..."
    docker pull "${IMAGE}" || error "Image pull failed"

    CONTAINER_NAME="blogify-${SERVICE}-${NEW_SLOT}"
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log "Removing stale ${NEW_SLOT} container..."
        docker stop "${CONTAINER_NAME}" 2>/dev/null || true
        docker rm   "${CONTAINER_NAME}" 2>/dev/null || true
    fi

    log "Starting ${CONTAINER_NAME} on port ${NEW_PORT}..."

    ENV_ARGS=(
        -e "PORT=${NEW_PORT}"
        -e "APP_VERSION=${IMAGE##*:}"
        -e "DATABASE_URL=postgresql://blogify:blogify@127.0.0.1:5432/blogify"
        -e "REDIS_URL=redis://127.0.0.1:6379"
        -e "RABBITMQ_URL=amqp://blogify:blogify@127.0.0.1:5672"
        -e "MINIO_ENDPOINT=127.0.0.1"
        -e "MINIO_PORT=9000"
        -e "MINIO_ACCESS_KEY=blogify"
        -e "MINIO_SECRET_KEY=blogify123"
        -e "JWT_SECRET=${JWT_SECRET:-change-this-in-prod}"
    )

    docker run -d \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        --network host \
        "${ENV_ARGS[@]}" \
        "${IMAGE}" || error "Failed to start ${NEW_SLOT} container"

    if ! health_check "${NEW_PORT}"; then
        warn "New ${NEW_SLOT} container failed health checks — stopping it, keeping ${OLD_SLOT} live"
        docker stop "${CONTAINER_NAME}" 2>/dev/null || true
        error "Deployment aborted for ${SERVICE} — rolled back to ${OLD_SLOT}"
    fi

    log "Switching ${SERVICE} upstream to ${NEW_SLOT}..."
    cp "${NGINX_CONF_DIR}/${SERVICE}-${NEW_SLOT}.conf" "${NGINX_CONF_DIR}/${SERVICE}-active.conf"

    nginx -t || error "Nginx config test failed — not reloading"
    nginx -s reload
    success "Nginx reloaded — ${SERVICE} traffic now on ${NEW_SLOT} (port ${NEW_PORT})"

    sleep 2
    if curl -sf "http://127.0.0.1/api/${SERVICE}/health" > /dev/null 2>&1; then
        success "End-to-end check passed via gateway"
    else
        warn "End-to-end check failed — reverting ${SERVICE} to ${OLD_SLOT}"
        cp "${NGINX_CONF_DIR}/${SERVICE}-${OLD_SLOT}.conf" "${NGINX_CONF_DIR}/${SERVICE}-active.conf"
        nginx -s reload
        docker stop "${CONTAINER_NAME}" 2>/dev/null || true
        error "Deployment failed for ${SERVICE} — ${OLD_SLOT} remains active"
    fi

    OLD_CONTAINER="blogify-${SERVICE}-${OLD_SLOT}"
    if docker ps --format '{{.Names}}' | grep -q "^${OLD_CONTAINER}$"; then
        log "Waiting 20s before stopping old ${OLD_SLOT} container..."
        sleep 20
        docker stop "${OLD_CONTAINER}" || true
        success "Old ${OLD_SLOT} container stopped"
    fi

    success "=== ${SERVICE} deployment complete: ${NEW_SLOT} @ ${NEW_PORT} ==="
}

main
