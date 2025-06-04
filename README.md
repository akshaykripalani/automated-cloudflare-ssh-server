# Cloudflare Zero Trust SSH Setup Scripts

These scripts automate the setup of a Cloudflare Tunnel and Cloudflare Access for SSH access to this server.

## Prerequisites

**1. Required Tools:**
   - `curl`: Used for making API calls to Cloudflare.
   - `jq`: Used for parsing JSON responses from API calls.
   - `cloudflared`: The Cloudflare Tunnel daemon. Installation instructions can be found at [https://pkg.cloudflare.com/index.html](https://pkg.cloudflare.com/index.html).
   - Ensure these are installed and in your system's PATH before running the scripts.

**2. Cloudflare Account & API Tokens:**
   - You need an active Cloudflare account.
   - The following API tokens must be generated from your Cloudflare dashboard:
     - **`COMBINED_CLOUDFLARE_TOKEN`**: Needs **all** permissions of the tokens it replaces:
       - Account Scope: `Cloudflare Tunnel:Edit`
       - Zone Scope (for all relevant zones if managing DNS, though not strictly used by these scripts for DNS record creation beyond tunnel routing): `DNS:Edit` (or more targeted permissions if preferred, but Tunnel:Edit at account level is key).
       - Account Scope: `Zero Trust:Edit`
       - Account Scope: `Access: Apps and Policies:Edit` (or `Access: Apps:Edit` and `Access: Policies:Edit`)
       - Account Scope: `Access: SSH Auditing:Edit` (This is for managing the SSH CA key).

**3. Configuration File (`config.env`):**
   - Create a file named `config.env` in the same directory as the scripts.
   - Populate it with the following information:

     ```env
     # Cloudflare Account and API Configuration
     ACCOUNT_ID="YOUR_CLOUDFLARE_ACCOUNT_ID"
     COMBINED_CLOUDFLARE_TOKEN="YOUR_COMBINED_CLOUDFLARE_TOKEN"

     # Set your primary Unix username on this server
     UNIX_USERNAME="your_unix_username"

     # Custom names for Cloudflare resources (optional, defaults are provided)
     TUNNEL_NAME="VM-Script-Tunnel"
     HOSTNAME="Scripted-VM-Target"
     APPNAME="Scripted VM SSH Access"

     # Runtime Variables (these will be set by the scripts, leave them commented out or blank initially)
     # SERVER_INTERNAL_IP=""
     # NETWORK_CIDR=""
     # TUNNEL_ID=""
     # TUNNEL_TOKEN=""
     ```
   - **Replace placeholders** like `YOUR_CLOUDFLARE_ACCOUNT_ID`, `YOUR_COMBINED_CLOUDFLARE_TOKEN`, and `your_unix_username` with your actual values.
   - **Security**: Protect this file as it contains sensitive API tokens. Set restrictive permissions (e.g., `chmod 600 config.env`).

**4. Permissions:**
   - The user running these scripts will need `sudo` privileges for:
     - Installing the `cloudflared` service (`sudo cloudflared service install ...`).
     - Writing the Cloudflare SSH CA public key to `/etc/ssh/ca.pub` (`sudo tee -a /etc/ssh/ca.pub`).
     - Potentially for installing missing packages if you choose to add that to the scripts.

## Execution Order & Steps

**IMPORTANT**: Execute the scripts in the specified order.

**Step 1: Run `setup.sh`**
   - This script sets up the Cloudflare Tunnel and routes traffic from your Cloudflare network to this server.
   - **Command:** `./setup.sh`
   - This script will:
     1. Detect the server's internal IP address.
     2. Create a Cloudflare Tunnel (named as per `TUNNEL_NAME` in `config.env`).
     3. Add a route in your Cloudflare Zero Trust for this server's IP to the created tunnel.
     4. Install and start the `cloudflared` service on this machine using the generated tunnel token.
     5. Update `config.env` with `SERVER_INTERNAL_IP`, `NETWORK_CIDR`, `TUNNEL_ID`, and `TUNNEL_TOKEN`.

**Step 2: Cloudflare Dashboard Configuration (Manual)**
   - **CRITICAL**: Before running `setup2.sh`, you **MUST** go to your Cloudflare Zero Trust dashboard:
     - Navigate to **Settings -> WARP Client -> Device settings -> (Your relevant profile, often Default) -> Split Tunnels**.
     - **Add this server's internal IP address (`SERVER_INTERNAL_IP` from `config.env`) to the "Include IPs and domains" list.**
     - The tunnel and SSH access via Cloudflare will **NOT** work correctly without this step.

**Step 3: Run `setup2.sh`**
   - This script configures Cloudflare Access applications and prepares the SSH server.
   - **Command:** `./setup2.sh`
   - This script will:
     1. Prompt for confirmation that you've completed the Split Tunnels manual step.
     2. Retrieve your default Virtual Network ID from Cloudflare.
     3. Create an Infrastructure Target in Cloudflare Access (named as per `HOSTNAME` in `config.env`).
     4. Create an Access Application for SSH (named as per `APPNAME` in `config.env`), targeting the created hostname and port 22.
        - The application policy by default allows users with specific email addresses (hardcoded in the script) and the `UNIX_USERNAME` (from `config.env`) or `root`.
     5. Retrieve or generate the Cloudflare SSH CA public key.
     6. Append this public key to `/etc/ssh/ca.pub` on this server (if not already present).
     7. Provide instructions for manually updating your server's `sshd_config` and restarting the SSH service.

**Step 4: Final SSH Configuration (Manual)**
   - As instructed by the output of `setup2.sh`:
     1. Edit your SSH daemon configuration file (usually `/etc/ssh/sshd_config`).
     2. Add the line: `TrustedUserCAKeys /etc/ssh/ca.pub` (if not already present or different).
     3. Restart the SSH daemon on your server (e.g., `sudo systemctl restart ssh` or `sudo service ssh restart`).

## Post-Setup

- Your server should now be accessible via SSH through Cloudflare Access.
- Users will authenticate via their Cloudflare login (matching the emails in the Access policy).
- When SSHing, use the command `cloudflared access ssh --hostname <your-target-hostname>` (where `<your-target-hostname>` is what you set for `HOSTNAME` in `config.env`).
- Ensure your WARP client is active on devices you wish to connect from and enrolled in your Zero Trust organization. 