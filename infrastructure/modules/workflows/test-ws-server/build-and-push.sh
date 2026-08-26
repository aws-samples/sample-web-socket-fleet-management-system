#!/bin/bash
set -e

echo "Building test-ws-server Docker image..."
echo "Repository: $REPO_NAME"
echo "Source Path: $SOURCE_PATH"

if ! docker info > /dev/null 2>&1; then
    echo "Error: Docker daemon is not running."
    exit 1
fi

if [ ! -f "$SOURCE_PATH/Dockerfile" ]; then
    echo "Error: Dockerfile not found at $SOURCE_PATH/Dockerfile"
    exit 1
fi

echo "Logging in to Amazon ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

echo "Building Docker image with tag: $IMAGE_TAG"
cd "$SOURCE_PATH"
docker build --platform linux/amd64 -t "$REPO_NAME:$IMAGE_TAG" .

docker tag "$REPO_NAME:$IMAGE_TAG" "$REPO_URL:$IMAGE_TAG"
docker tag "$REPO_NAME:$IMAGE_TAG" "$REPO_URL:latest"

echo "Pushing image to ECR..."
docker push "$REPO_URL:$IMAGE_TAG"
docker push "$REPO_URL:latest"

echo "Successfully built and pushed: $REPO_URL:$IMAGE_TAG"
