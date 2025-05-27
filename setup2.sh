#!/bin/bash

# Source the configuration file
source config.env

echo "IMPORTANT: Please confirm that you have added this machine's IP address to the Cloudflare Split Tunnels Include List."
echo "This is a critical step - the tunnel will not work correctly without it."
echo -n "Press Enter to confirm and continue..."
read

echo "Proceeding with configuring targets and applications..."

# Get virtual network ID
echo "Getting virtual network ID..."
network_response=$(curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/teamnet/virtual_networks?is_default=true" \
  --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN")

network_success=$(echo "$network_response" | jq -r '.success')
if [[ "$network_success" != "true" ]]; then
  echo "Error: Failed to get virtual network ID."
  echo "Response: $network_response"
  exit 1
fi

VIRTUAL_NETWORK_ID=$(echo "$network_response" | jq -r '.result[0].id')
if [ -z "$VIRTUAL_NETWORK_ID" ] || [ "$VIRTUAL_NETWORK_ID" == "null" ]; then
  echo "Error: Failed to retrieve a valid Virtual Network ID."
  echo "Response: $network_response"
  exit 1
fi
echo "Virtual network ID retrieved successfully: $VIRTUAL_NETWORK_ID"

# Create infrastructure target
echo "Creating infrastructure target..."
target_response=$(curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/infrastructure/targets" \
  --header "Authorization: Bearer $ZEROTRUST_API_TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{
    "hostname": "'"${HOSTNAME}"'",
    "ip": {
      "ipv4": {
        "ip_addr": "'"${SERVER_INTERNAL_IP}"'",
        "virtual_network_id": "'"${VIRTUAL_NETWORK_ID}"'"
      }
    }
  }')

target_success=$(echo "$target_response" | jq -r '.success')
if [[ "$target_success" != "true" ]]; then
  echo "Error: Infrastructure target creation failed."
  echo "Response: $target_response"
  exit 1
fi
echo "Infrastructure target created successfully."


# Create Access application for SSH
echo "Creating Access application..."
app_response=$(curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/apps" \
  --header "Authorization: Bearer $ACCESS_API_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{
    "name": "'"${APPNAME}"'",
    "type": "infrastructure", 
    "target_criteria": [
      {
        "target_attributes": {
          "hostname": [
            "'"${HOSTNAME}"'"
          ]
        },
        "port": 22,
        "protocol": "SSH"
      }
    ],
    "policies": [
      {
        "name": "Allow authorized users",
        "decision": "allow",
        "include": [
          {
            "email": {
              "email": "akshaykrip@gmail.com"
            }
          },
          {
            "email": {
              "email": "asticlol69@gmail.com" 
            }
          },
          {
            "email": {
              "email": "yash.panditrao@gmail.com"
            }
          }
        ],
        "connection_rules": {
          "ssh": {
            "usernames": [
              "root",
              "'"${UNIX_USERNAME}"'"
            ]
          }
        }
      }
    ]
  }')

app_success=$(echo "$app_response" | jq -r '.success')
if [[ "$app_success" != "true" ]]; then
  echo "Error: Access application creation failed."
  echo "Response: $app_response"
  exit 1
fi
echo "Access application created successfully."


echo "Configuring SSH server to trust Cloudflare SSH CA..."

# Try to create a new Cloudflare SSH CA or get existing one
echo "Attempting to generate or retrieve Cloudflare SSH CA public key..."
# Note: Using SSH_AUDIT_TOKEN as specified in the requirements
ca_api_response=$(curl -s --request POST \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/gateway_ca" \
  --header "Authorization: Bearer $SSH_AUDIT_TOKEN")

PUBLIC_KEY=$(echo "$ca_api_response" | jq -r '.result.public_key // empty')
api_success=$(echo "$ca_api_response" | jq -r '.success')

if [[ "$api_success" == "true" && -n "$PUBLIC_KEY" ]]; then
  echo "Cloudflare SSH CA generated/retrieved successfully (via POST)."
else
    echo "Cloudflare SSH CA already exists. Fetching existing CA public key via GET..."
    ca_api_response=$(curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/gateway_ca" \
        --header "Authorization: Bearer $SSH_AUDIT_TOKEN")

    PUBLIC_KEY=$(echo "$ca_api_response" | jq -r '.result.public_key // empty')
    api_success=$(echo "$ca_api_response" | jq -r '.success')

    if [[ "$api_success" == "true" && -n "$PUBLIC_KEY" ]]; then
        echo "Existing Cloudflare SSH CA public key retrieved successfully."
    else
        echo "Critical failure! Failed to create and get CA Public Key!! Please check your API token and try again."
        exit 1
    fi
fi

echo "Cloudflare SSH CA public key obtained."
# For debugging: echo "Public Key: $PUBLIC_KEY"

# Check if the key already exists in the file
if [[ -z "$PUBLIC_KEY" ]]; then
  echo "Error: Public key is empty, cannot save to this server."
  exit 1
fi

if sudo grep -qF "$PUBLIC_KEY" /etc/ssh/ca.pub; then
  echo "Cloudflare SSH CA public key already exists in /etc/ssh/ca.pub."
else
  echo "Saving public key to /etc/ssh/ca.pub..."
  if echo "${PUBLIC_KEY}" | sudo tee -a /etc/ssh/ca.pub > /dev/null; then
    echo "Public key successfully appended to /etc/ssh/ca.pub."
  else
    echo "Error: Failed to save public key to /etc/ssh/ca.pub."
    echo "Please ensure you have sudo privileges and the /etc/ssh directory exists."
    exit 1
  fi
fi

echo ""
echo "Cloudflare SSH CA public key has been added to /etc/ssh/ca.pub."
echo "IMPORTANT: Manual steps are required to finalize SSH configuration:"
echo "  1. Edit your SSH daemon configuration file (usually /etc/ssh/sshd_config)."
echo "     Add the following line if it's not already present:"
echo "       TrustedUserCAKeys /etc/ssh/ca.pub"
echo "  2. After saving the changes to sshd_config, restart the SSH daemon."
echo "     Common commands (use the one appropriate for your system):"
echo "       sudo systemctl restart ssh (Common on most Ubuntu/Debian versions)" 
echo "       sudo service ssh restart (if you're a dinosaur)"
echo "---------------------------------------------------------------------"


