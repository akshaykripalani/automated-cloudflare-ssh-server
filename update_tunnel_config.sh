#!/bin/bash

# Script to update Cloudflare Tunnel ingress rules

set -e # Exit immediately if a command exits with a non-zero status.
# set -u # Treat unset variables as an error when substituting.
# set -o pipefail # Causes a pipeline to return the exit status of the last command in the pipe that failed.

CONFIG_FILE="config.env"
API_BASE_URL="https://api.cloudflare.com/client/v4"

# --- Helper Functions ---
check_deps() {
    for cmd in jq curl; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "Error: Required command '$cmd' not found. Please install it." >&2
            exit 1
        fi
    done
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Configuration file '$CONFIG_FILE' not found." >&2
        exit 1
    fi
    # Source the .env file. Regex to extract values to be robust against comments etc.
    ACCOUNT_ID=$(grep -E '^ACCOUNT_ID=' "$CONFIG_FILE" | cut -d'=' -f2 | tr -d '"')
    COMBINED_CLOUDFLARE_TOKEN=$(grep -E '^COMBINED_CLOUDFLARE_TOKEN=' "$CONFIG_FILE" | cut -d'=' -f2 | tr -d '"')
    TUNNEL_ID=$(grep -E '^TUNNEL_ID=' "$CONFIG_FILE" | cut -d'=' -f2 | tr -d '"')

    if [[ -z "$ACCOUNT_ID" ]]; then
        echo "Error: ACCOUNT_ID is missing from '$CONFIG_FILE' or could not be read." >&2
        exit 1
    fi
    if [[ -z "$COMBINED_CLOUDFLARE_TOKEN" ]]; then
        echo "Error: COMBINED_CLOUDFLARE_TOKEN is missing from '$CONFIG_FILE' or could not be read." >&2
        exit 1
    fi
    if [[ -z "$TUNNEL_ID" ]]; then
        echo "Error: TUNNEL_ID is missing from '$CONFIG_FILE' or could not be read. Please define it in $CONFIG_FILE." >&2
        exit 1
    fi
}

# --- Main Script ---
check_deps

# Parse arguments
if [[ "$#" -ne 2 ]]; then
    echo "Usage: $0 <new_hostname> <new_service>"
    echo "Example: $0 test.example.com http://localhost:3000"
    exit 1
fi

NEW_HOSTNAME="$1"
NEW_SERVICE="$2"

load_config

echo "Fetching current tunnel configuration..."
GET_URL="${API_BASE_URL}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations"

CURRENT_CONFIG_RESPONSE=$(curl -s -X GET "$GET_URL" \
    -H "Authorization: Bearer $COMBINED_CLOUDFLARE_TOKEN" \
    -H "Content-Type: application/json")

if ! echo "$CURRENT_CONFIG_RESPONSE" | jq -e '.success == true' > /dev/null; then
    echo "Error: Failed to fetch current tunnel configuration." >&2
    echo "Response: $CURRENT_CONFIG_RESPONSE" >&2
    exit 1
fi

# Extract the current config object (.result.config)
CURRENT_TUNNEL_CONFIG_PART=$(echo "$CURRENT_CONFIG_RESPONSE" | jq -r '.result.config')

# Extract existing ingress rules and warp-routing settings
EXISTING_INGRESS_RULES=$(echo "$CURRENT_TUNNEL_CONFIG_PART" | jq -c '.ingress // []') # Use // [] for safety if ingress is null
EXISTING_WARP_ROUTING=$(echo "$CURRENT_TUNNEL_CONFIG_PART" | jq -c '."warp-routing" // {}') # Use // {} for safety

# Filter out the catch-all "http_status:404" rule, if it exists
FILTERED_INGRESS_RULES=$(echo "$EXISTING_INGRESS_RULES" | jq -c '[.[] | select(.service != "http_status:404")]')

# Create the new ingress rule JSON object
NEW_RULE=$(jq -n --arg hn "$NEW_HOSTNAME" --arg svc "$NEW_SERVICE" \
    '{hostname: $hn, service: $svc, originRequest: {}}')

# Append the new rule and then re-append the catch-all rule
UPDATED_INGRESS_RULES=$(echo "$FILTERED_INGRESS_RULES" | jq -c ". + [$NEW_RULE] + [{\"service\": \"http_status:404\"}]")

# Construct the final JSON payload for the PUT request
FINAL_PAYLOAD=$(jq -n \
    --argjson ingress "$UPDATED_INGRESS_RULES" \
    --argjson warp_routing "$EXISTING_WARP_ROUTING" \
    '{ingress: $ingress, "warp-routing": $warp_routing}')

echo ""
echo "---------------------------------------------------------------------"
echo "Proposed new Cloudflare Tunnel Configuration:"
echo "---------------------------------------------------------------------"
echo "$FINAL_PAYLOAD" | jq '.' # Pretty print the JSON
echo "---------------------------------------------------------------------"
echo "This will update the tunnel configuration for:"
echo "Account ID: $ACCOUNT_ID"
echo "Tunnel ID:  $TUNNEL_ID"
echo ""
echo "The following ingress rule will be added:"
echo "  Hostname: $NEW_HOSTNAME"
echo "  Service:  $NEW_SERVICE"
echo ""
echo "PLEASE DOUBLE AND TRIPLE CHECK THE CONFIGURATION ABOVE!"
echo "This is a critical operation and will replace the entire tunnel configuration."
echo ""

read -r -p "Are you absolutely sure you want to apply these changes? (yes/NO): " CONFIRMATION

if [[ "${CONFIRMATION,,}" != "yes" ]]; then # Convert to lowercase for case-insensitive comparison
    echo "Operation cancelled by user."
    exit 0
fi

echo ""
echo "Applying changes..."

PUT_URL="${API_BASE_URL}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations"

UPDATE_RESPONSE=$(curl -s -X PUT "$PUT_URL" \
    -H "Authorization: Bearer $COMBINED_CLOUDFLARE_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$FINAL_PAYLOAD")

if echo "$UPDATE_RESPONSE" | jq -e '.success == true' > /dev/null; then
    echo "Successfully updated Cloudflare Tunnel configuration!"
    echo "Response:"
    echo "$UPDATE_RESPONSE" | jq '.'
else
    echo "Error: Failed to update Cloudflare Tunnel configuration." >&2
    echo "Response:" >&2
    echo "$UPDATE_RESPONSE" | jq '.' >&2
    exit 1
fi

exit 0 