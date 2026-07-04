#!/bin/bash
set -euo pipefail

SERVICE=$1
IMAGE=$2
PORT_BLUE=$3
PORT_GREEN=$4

GATEWAY_CONF="/etc/nginx/conf.d/gateway.conf"
HEALTH_RETRIES=10
HEALTH_WAIT=5

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()     { echo -e "${NC}[$(date '+%H:%M:%S')] [$SERVICE] $*"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] [$SERVICE] ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] [$SERVICE] ⚠ $*${NC}"; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] [$SERVICE] ✗ $*${NC}"; exit 1; }

UPSTREAM_NAME="${SERVICE//-/_}_active"

get_active_port() {
    grep -A1 "upstream ${UPSTREAM_NAME}" $GATEWAY_CONF | grep server | grep -oP ':\K[0-9]+' | head -1
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

    CURRENT_PORT=$(get_active_port)
    log "Current active port: ${CURRENT_PORT}"

    if [ "$CURRENT_PORT" = "$PORT_BLUE" ]; then
        NEW_SLOT="green"; NEW_PORT=$PORT_GREEN
        OLD_SLOT="blue";  OLD_PORT=$PORT_BLUE
    else
        NEW_SLOT="blue";  NEW_PORT=$PORT_BLUE
        OLD_SLOT="green"; OLD_PORT=$PORT_GREEN
    fi

    log "Target slot: ${NEW_SLOT} (port ${NEW_PORT})"

    log "Pulling ${IMAGE}..."
    docker pull "${IMAGE}" || error "Image pull failed"

    CONTAINER="blogify-${SERVICE}-${NEW_SLOT}"
    docker stop "${CONTAINER}" 2>/dev/null || true
    docker rm   "${CONTAINER}" 2>/dev/null || true

    log "Starting ${CONTAINER} on port ${NEW_PORT}..."
    docker run -d \
        --name "${CONTAINER}" \
        --restart unless-stopped \
        --network host \
        -e PORT="${NEW_PORT}" \
        -e APP_VERSION="${IMAGE##*:}" \
        -e DATABASE_URL="postgresql://blogify:blogify@127.0.0.1:5432/blogify" \
        -e REDIS_URL="redis://127.0.0.1:6379" \
        -e RABBITMQ_URL="amqp://blogify:blogify@127.0.0.1:5672" \
        -e MINIO_ENDPOINT="127.0.0.1" \
        -e MINIO_PORT="9000" \
        -e MINIO_ACCESS_KEY="blogify" \
        -e MINIO_SECRET_KEY="blogify123" \
        -e JWT_SECRET="${JWT_SECRET:-dev-secret-change-in-prod}" \
        "${IMAGE}" || error "Failed to start container"

    if ! health_check "${NEW_PORT}"; then
        docker stop "${CONTAINER}" 2>/dev/null || true
        error "Health check failed — keeping ${OLD_SLOT} active"
    fi

    log "Switching ${SERVICE} upstream to port ${NEW_PORT}..."
    sed -i "s|upstream ${UPSTREAM_NAME} { server 127.0.0.1:${OLD_PORT}; }|upstream ${UPSTREAM_NAME} { server 127.0.0.1:${NEW_PORT}; }|" $GATEWAY_CONF

    nginx -t || error "Nginx config test failed"
    nginx -s reload
    success "Nginx reloaded — ${SERVICE} now on ${NEW_SLOT} (port ${NEW_PORT})"

    sleep 2
    if curl -sf "http://127.0.0.1/api/${SERVICE}/health" > /dev/null 2>&1; then
        success "End-to-end check passed"
    else
        warn "End-to-end check failed — reverting"
        sed -i "s|upstream ${UPSTREAM_NAME} { server 127.0.0.1:${NEW_PORT}; }|upstream ${UPSTREAM_NAME} { server 127.0.0.1:${OLD_PORT}; }|" $GATEWAY_CONF
        nginx -s reload
        docker stop "${CONTAINER}" || true
        error "Deployment failed — ${OLD_SLOT} restored"
    fi

    OLD_CONTAINER="blogify-${SERVICE}-${OLD_SLOT}"
    if docker ps --format '{{.Names}}' | grep -q "^${OLD_CONTAINER}$"; then
        log "Stopping old ${OLD_SLOT} container in 10s..."
        sleep 10
        docker stop "${OLD_CONTAINER}" || true
        success "Old ${OLD_SLOT} container stopped"
    fi

    success "=== ${SERVICE} deployed to ${NEW_SLOT} @ port ${NEW_PORT} ==="
}

main
SCRIPT

sudo chmod +x /opt/blogify/deploy-service.sh
echo "Script updated"