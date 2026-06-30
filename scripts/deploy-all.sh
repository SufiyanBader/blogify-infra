#!/bin/bash
# =============================================================================
# Deploys multiple services in sequence, one blue-green swap at a time.
# Usage: ./deploy-all.sh <namespace> <image_tag> <service1,service2,...>
# Example: ./deploy-all.sh sufiyanbader abc1234 posts,comments
# =============================================================================

set -euo pipefail

NAMESPACE=$1
TAG=$2
SERVICES_CSV=$3
DEPLOY_DIR="/opt/blogify"

declare -A PORT_BLUE=( [auth]=4101 [posts]=4201 [comments]=4301 [media]=4401 [notification-worker]=4501 )
declare -A PORT_GREEN=( [auth]=4102 [posts]=4202 [comments]=4302 [media]=4402 [notification-worker]=4502 )

IFS=',' read -ra SERVICES <<< "$SERVICES_CSV"

FAILED=()

for svc in "${SERVICES[@]}"; do
    svc=$(echo "$svc" | tr -d '"[] ')
    [ -z "$svc" ] && continue

    if [ -z "${PORT_BLUE[$svc]:-}" ]; then
        echo "Unknown service: $svc — skipping"
        continue
    fi

    image="${NAMESPACE}/blogify-${svc}:${TAG}"
    echo ""
    echo "=================================================================="
    echo " Deploying ${svc} -> ${image}"
    echo "=================================================================="

    if ! "${DEPLOY_DIR}/deploy-service.sh" "$svc" "$image" "${PORT_BLUE[$svc]}" "${PORT_GREEN[$svc]}"; then
        FAILED+=("$svc")
        echo "Deployment of ${svc} FAILED — continuing with remaining services"
    fi
done

echo ""
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "All services deployed successfully."
    exit 0
else
    echo "The following services FAILED to deploy: ${FAILED[*]}"
    exit 1
fi
