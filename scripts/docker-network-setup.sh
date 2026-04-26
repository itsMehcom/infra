#!/bin/bash

# Exit on any error
set -e

# Define the network name
NETWORK_NAME="internal"

echo "Checking for required Docker network: $NETWORK_NAME"

# Check if the network already exists
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    echo "Network '$NETWORK_NAME' does not exist. Creating..."
    docker network create "$NETWORK_NAME"
    echo "✅ Network '$NETWORK_NAME' created successfully."
else
    echo "✅ Network '$NETWORK_NAME' already exists. Skipping."
fi

echo "Docker network setup complete!"
