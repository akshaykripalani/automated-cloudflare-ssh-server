#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status
# set -o pipefail # Consider adding this if you have complex pipelines

echo "Nginx Reverse Proxy Configuration Helper for Ubuntu 22.04"
echo "========================================================"
echo "This script will guide you through setting up Nginx server blocks."
echo "It assumes your Cloudflare Tunnel public hostnames will point to this server on port 80."
echo ""

# Ensure script is run with sudo or as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script needs to be run with sudo or as root." >&2
  echo "Please run as: sudo $0"
  exit 1
fi

# --- Phase 1: Nginx Installation and Service Check ---
echo "--- Checking Nginx Status ---"
if ! command -v nginx > /dev/null 2>&1; then
  echo "Nginx is not installed."
  read -r -p "Do you want to install Nginx now? (y/N): " install_nginx
  if [[ "$install_nginx" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo "Installing Nginx..."
    apt update > /dev/null
    apt install nginx -y > /dev/null
    echo "Nginx installed successfully."
  else
    echo "Nginx installation skipped. Exiting."
    exit 1
  fi
else
  echo "Nginx is already installed."
fi

if ! systemctl is-active --quiet nginx; then
  echo "Nginx service is not active. Starting Nginx..."
  systemctl start nginx
  echo "Nginx service started."
else
  echo "Nginx service is active."
fi

if ! systemctl is-enabled --quiet nginx; then
  echo "Nginx service is not enabled to start on boot. Enabling Nginx..."
  systemctl enable nginx > /dev/null
  echo "Nginx service enabled."
else
  echo "Nginx service is already enabled."
fi
echo "-----------------------------"
echo ""

# --- Phase 2: Optionally Disable Default Nginx Site ---
DEFAULT_NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/default"
if [ -L "$DEFAULT_NGINX_SITE_ENABLED" ]; then
  read -r -p "The default Nginx site is currently enabled. Do you want to disable it for a cleaner setup? (recommended) (y/N): " disable_default
  if [[ "$disable_default" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo "Disabling default Nginx site..."
    rm -f "$DEFAULT_NGINX_SITE_ENABLED"
    echo "Default Nginx site disabled. You might need to reload Nginx later for this to take full effect if no other sites are configured."
  else
    echo "Default Nginx site will remain enabled."
  fi
  echo ""
fi

# --- Phase 3: Interactive Site Configuration Loop ---
SITES_CONFIGURED_COUNT=0
while true; do
  echo "--- Configure a New Site ---"
  read -r -p "Enter the public hostname (e.g., app1.yourdomain.com, leave blank to finish): " public_hostname

  if [ -z "$public_hostname" ]; then
    if [ "$SITES_CONFIGURED_COUNT" -eq 0 ]; then
      echo "No sites configured. Exiting."
      exit 0
    else
      echo "Finished configuring sites."
      break
    fi
  fi

  while true; do
    read -r -p "Enter the internal port your application for '$public_hostname' listens on (e.g., 3000): " internal_port
    if [[ "$internal_port" =~ ^[0-9]+$ ]] && [ "$internal_port" -gt 0 ] && [ "$internal_port" -lt 65536 ]; then
      # Check if port is commonly used by system services (very basic check)
      if [ "$internal_port" -lt 1024 ] && [ "$internal_port" -ne 80 ] && [ "$internal_port" -ne 443 ]; then
         read -r -p "Warning: Port $internal_port is a privileged port (<1024). Are you sure? (y/N): " confirm_privileged_port
         if [[ ! "$confirm_privileged_port" =~ ^([yY][eE][sS]|[yY])$ ]]; then
           echo "Please choose a different port."
           continue
         fi
      fi
      break
    else
      echo "Invalid port number. Please enter a number between 1 and 65535."
    fi
  done

  # Confirm details
  echo ""
  echo "Site Details:"
  echo "  Public Hostname: $public_hostname"
  echo "  Internal App Port: $internal_port"
  echo "  Nginx will proxy to: http://localhost:$internal_port"
  read -r -p "Is this correct? (y/N): " confirm_details
  if [[ ! "$confirm_details" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo "Configuration for '$public_hostname' cancelled."
    continue
  fi

  # --- Phase 4: Nginx File Generation ---
  NGINX_CONF_DIR_AVAILABLE="/etc/nginx/sites-available"
  NGINX_CONF_DIR_ENABLED="/etc/nginx/sites-enabled"
  CONF_FILE_NAME="$public_hostname.conf" # Using .conf extension is common
  CONF_FILE_PATH="$NGINX_CONF_DIR_AVAILABLE/$CONF_FILE_NAME"

  echo "Creating Nginx configuration file at $CONF_FILE_PATH..."

  # Using a here document to create the config content
  # Note: Variables like $public_hostname and $internal_port are expanded by bash here.
  # $host, $remote_addr etc. are Nginx variables, so they need to be escaped or put in single quotes
  # if this here-doc was single-quoted. Since it's double-quoted (implicit), Nginx vars are fine.
  cat << EOF > "/tmp/$CONF_FILE_NAME"
server {
    listen 80;
    listen [::]:80; # Listen on IPv6 as well

    server_name $public_hostname;

    location / {
        proxy_pass http://localhost:$internal_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade"; # For WebSocket support
    }

    # Optional: You can add specific access and error logs per site
    # access_log /var/log/nginx/${public_hostname}.access.log;
    # error_log /var/log/nginx/${public_hostname}.error.log;

    # Optional: Basic error pages
    # error_page 500 502 503 504 /50x.html;
    # location = /50x.html {
    #     root /usr/share/nginx/html;
    # }
}
EOF

  # Move the file with sudo
  mv "/tmp/$CONF_FILE_NAME" "$CONF_FILE_PATH"
  chown root:root "$CONF_FILE_PATH"
  chmod 644 "$CONF_FILE_PATH"
  echo "Configuration file created."

  # --- Phase 5: Enable Site ---
  echo "Enabling site '$public_hostname'..."
  # -f to force overwrite if symlink already exists (e.g., re-running script)
  ln -sf "$CONF_FILE_PATH" "$NGINX_CONF_DIR_ENABLED/$CONF_FILE_NAME"
  echo "Site enabled."
  SITES_CONFIGURED_COUNT=$((SITES_CONFIGURED_COUNT + 1))
  echo "-----------------------------"
  echo ""
done


# --- Phase 6: Test Nginx Configuration & Reload (only if sites were configured) ---
if [ "$SITES_CONFIGURED_COUNT" -gt 0 ]; then
  echo "--- Testing Nginx Configuration ---"
  if nginx -t; then
    echo "Nginx configuration test successful."
    echo "Reloading Nginx to apply changes..."
    systemctl reload nginx
    echo "Nginx reloaded successfully."
  else
    echo "ERROR: Nginx configuration test failed!" >&2
    echo "Nginx was NOT reloaded." >&2
    echo "Please review the error messages above and check your configuration files in $NGINX_CONF_DIR_AVAILABLE." >&2
    echo "You may need to manually remove the problematic symlink(s) from $NGINX_CONF_DIR_ENABLED before Nginx can start/reload correctly." >&2
    # Example: if app1.yourdomain.com.conf was bad: sudo rm /etc/nginx/sites-enabled/app1.yourdomain.com.conf
    exit 1 # Exit with error if config test fails
  fi
else
  # This case might occur if default was disabled but no new sites added
  if [[ "$disable_default" =~ ^([yY][eE][sS]|[yY])$ ]]; then
      echo "Default site was disabled. Testing and reloading Nginx..."
      if nginx -t; then
          systemctl reload nginx
          echo "Nginx reloaded."
      else
          echo "ERROR: Nginx configuration test failed after disabling default site." >&2
          echo "Nginx was NOT reloaded. You might need to restore the default site or fix other configurations." >&2
          exit 1
      fi
  fi
fi

echo ""
echo "========================================================"
echo "Nginx configuration process complete."
echo "Make sure your Cloudflare Tunnel Public Hostnames for the configured sites"
echo "are pointing to http://localhost:80 (or this server's IP on port 80)."