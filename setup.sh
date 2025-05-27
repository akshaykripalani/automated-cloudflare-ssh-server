#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status
set -o pipefail # The return value of a pipeline is the status of the last command to exit with a non-zero status

# Source the configuration file
if [ ! -f "config.env" ]; then
    echo "Error: config.env file not found!" >&2
    exit 1
fi
source config.env

# Check for required environment variables
if [ -z "$ACCOUNT_ID" ] || [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    echo "Error: Required environment variables are not set in config.env" >&2
    exit 1
fi

# Check for required commands
for cmd in curl jq; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "Error: $cmd is not installed. Please install it and retry." >&2
        exit 1
    fi
done

# Special check for cloudflared
if ! command -v cloudflared >/dev/null 2>&1; then
    echo "Error: cloudflared is not installed." >&2
    echo "Please visit https://pkg.cloudflare.com/index.html and follow the installation instructions for your system." >&2
    echo "After installing cloudflared, run this script again." >&2
    exit 1
fi

SERVER_INTERNAL_IP=$(ip route get 1 | awk '{print $7; exit}')
if [ -z "$SERVER_INTERNAL_IP" ]; then
    echo "Error: Could not determine server internal IP." >&2
    exit 1
fi
NETWORK_CIDR="${SERVER_INTERNAL_IP}/32"
echo "Determined network CIDR as: $NETWORK_CIDR"

# Update config.env with runtime variables
sed -i "/^SERVER_INTERNAL_IP=/d" config.env
sed -i "/^NETWORK_CIDR=/d" config.env
echo "SERVER_INTERNAL_IP=\"$SERVER_INTERNAL_IP\"" >> config.env
echo "NETWORK_CIDR=\"$NETWORK_CIDR\"" >> config.env

echo "Attempting to create Cloudflare tunnel..."
response=$(curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel" \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  --data '{
    "name": "'"${TUNNEL_NAME}"'",
    "config_src": "cloudflare"
  }')

success=$(echo "$response" | jq -r '.success')
if [[ "$success" != "true" ]]; then
  echo "Error: Tunnel creation failed."
  echo "Response: $response"
  exit 1
fi
echo "Tunnel created successfully."

# Extract tunnel ID and token
TUNNEL_ID=$(echo "$response" | jq -r '.result.id')
TUNNEL_TOKEN=$(echo "$response" | jq -r '.result.token') # This is the JWT to run the tunnel

echo "Tunnel ID: $TUNNEL_ID"
echo "Tunnel Token: $TUNNEL_TOKEN" # You'll need this token for cloudflared

# After tunnel creation, update config.env with tunnel details
sed -i "/^TUNNEL_ID=/d" config.env
sed -i "/^TUNNEL_TOKEN=/d" config.env
echo "TUNNEL_ID=\"$TUNNEL_ID\"" >> config.env
echo "TUNNEL_TOKEN=\"$TUNNEL_TOKEN\"" >> config.env

echo "Attempting to add route to tunnel..."
# Note the quoting for variables inside the JSON string for --data
# We 'exit' the single-quoted string to let bash expand the variable, then re-enter.
route_response=$(curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/teamnet/routes" \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  --data '{
    "network": "'"${NETWORK_CIDR}"'",
    "tunnel_id": "'"${TUNNEL_ID}"'",
    "comment": "Route for server '"${SERVER_INTERNAL_IP}"'"
  }')

route_success=$(echo "$route_response" | jq -r '.success')
if [[ "$route_success" != "true" ]]; then
  echo "Warning: Failed to add route to tunnel. Assuming it already exists or will be managed manually."
  echo "Response: $route_response"
  # Consider what to do here. Maybe delete the tunnel if routing fails?
  # For now, just continuing as per user request.
else
  echo "Successfully added route for $NETWORK_CIDR to tunnel $TUNNEL_ID."
fi

echo "Tunnel setup complete."
echo "Attempting to install and run tunnel on this machine."

sudo cloudflared service install "$TUNNEL_TOKEN"

echo "Attempting to verify if tunnel is running..."

verification_response=$(curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID" \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN")

verification_success=$(echo "$verification_response" | jq -r '.success')
if [[ "$verification_success" != "true" ]]; then
  echo "Error: Failed to verify tunnel status."
  echo "Response: $verification_response"
  exit 1
fi

echo "Tunnel is running."

echo "At this point you would deploy the WARP client on your devices, and manually configure TCP settings, along with your enrolment rules."