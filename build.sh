#!/bin/bash
set -e

IMAGE_NAME="${IMAGE_NAME:-xray-mikrotik}"
XRAY_VERSION="${XRAY_VERSION:-v26.6.27}"
PLATFORM="${PLATFORM:-linux/arm64}"

echo "=== Building Xray-Core Container ==="
echo "Image: $IMAGE_NAME"
echo "Xray version: $XRAY_VERSION"
echo "Platform: $PLATFORM"
echo ""

# Проверка наличия buildx
if ! docker buildx ls &>/dev/null; then
    echo "ERROR: docker buildx not available"
    exit 1
fi

# Сборка для указанной платформы
docker buildx build \
    --platform "$PLATFORM" \
    --build-arg "XRAY_VERSION=$XRAY_VERSION" \
    -t "$IMAGE_NAME:latest" \
    -t "$IMAGE_NAME:${XRAY_VERSION#v}" \
    --load \
    .

echo ""
echo "=== Build complete ==="
echo "Image: $IMAGE_NAME:latest"
echo ""
echo "To export for Mikrotik:"
echo "  docker save $IMAGE_NAME:latest > xray-mikrotik.tar"
