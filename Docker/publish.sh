#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./Docker/publish.sh [image] [tag]
# Example:
#   ./Docker/publish.sh aminetbaik/a2tools latest

IMAGE_NAME="${1:-aminetbaik/a2tools}"
IMAGE_TAG="${2:-latest}"
# Requested default set:
# - linux/amd64 (baseline)
# - linux/amd64/v3 (x86-64-v3 tuned variant)
# - linux/arm64 (ARM)
PLATFORMS="${PLATFORMS:-linux/amd64,linux/amd64/v3,linux/arm64}"
BUILDER_NAME="${BUILDER_NAME:-a2tools-builder}"
ALLOW_PLATFORM_FALLBACK="${ALLOW_PLATFORM_FALLBACK:-0}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not in PATH." >&2
  exit 1
fi

if ! docker buildx version >/dev/null 2>&1; then
  echo "ERROR: docker buildx is required." >&2
  exit 1
fi

if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  docker buildx create --name "$BUILDER_NAME" --use >/dev/null
else
  docker buildx use "$BUILDER_NAME" >/dev/null
fi

BUILDER_INFO="$(docker buildx inspect --bootstrap)"
SUPPORTED_PLATFORMS="$(printf '%s\n' "$BUILDER_INFO" | awk -F': ' '/Platforms:/ {print $2}')"

if printf '%s' "$PLATFORMS" | grep -q 'linux/amd64/v3' && ! printf '%s' "$SUPPORTED_PLATFORMS" | grep -q 'linux/amd64/v3'; then
  if [ "$ALLOW_PLATFORM_FALLBACK" = "1" ]; then
    echo "WARN: Builder '$BUILDER_NAME' does not support linux/amd64/v3. Falling back to linux/amd64,linux/arm64." >&2
    PLATFORMS="linux/amd64,linux/arm64"
  else
    echo "ERROR: Builder '$BUILDER_NAME' does not support linux/amd64/v3." >&2
    echo "Supported platforms: $SUPPORTED_PLATFORMS" >&2
    echo "Use a builder with linux/amd64/v3 support, or rerun with ALLOW_PLATFORM_FALLBACK=1." >&2
    exit 1
  fi
fi

echo "Building and pushing ${IMAGE_NAME}:${IMAGE_TAG} for platforms: ${PLATFORMS}"
docker buildx build \
  --platform "$PLATFORMS" \
  --file "$ROOT_DIR/Docker/Dockerfile" \
  --tag "$IMAGE_NAME:$IMAGE_TAG" \
  --push \
  "$ROOT_DIR"

echo
echo "Published manifest:"
docker buildx imagetools inspect "$IMAGE_NAME:$IMAGE_TAG"
