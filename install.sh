#!/bin/bash
set -e

# ==========================================
# R-BOTS - Railway SSH + Cloudflare Tunnel
# ==========================================

GREEN="\033[0;32m"
RED="\033[0;31m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"

echo
echo "=========================================="
echo "       R-BOTS SSH + CLOUDFLARED"
echo "=========================================="
echo

# Root check
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Please run this script as root.${RESET}"
    exit 1
fi

# ------------------------------------------
# 1. APT UPDATE + REQUIRED PACKAGES
# ------------------------------------------

echo -e "${CYAN}[1/7] Installing required packages...${RESET}"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y

apt-get install -y \
    openssh-server \
    curl \
    ca-certificates \
    python3 \
    supervisor \
    iproute2

echo -e "${GREEN}Packages installed.${RESET}"
echo

# ------------------------------------------
# 2. SSH CONFIGURATION
# ------------------------------------------

echo -e "${CYAN}[2/7] Configuring SSH...${RESET}"

mkdir -p /run/sshd

# Remove conflicting SSH settings
sed -i '/^[[:space:]]*PermitRootLogin[[:space:]]/d' /etc/ssh/sshd_config
sed -i '/^[[:space:]]*PasswordAuthentication[[:space:]]/d' /etc/ssh/sshd_config

# Add required settings
cat >> /etc/ssh/sshd_config <<'EOF'

# R-BOTS SSH
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
EOF

# Test SSH configuration
/usr/sbin/sshd -t

echo -e "${GREEN}SSH configuration OK.${RESET}"
echo

# ------------------------------------------
# 3. CLOUDFLARED FROM GITHUB
# ------------------------------------------

echo -e "${CYAN}[3/7] Installing Cloudflared from GitHub...${RESET}"

ARCH=$(dpkg --print-architecture)

case "$ARCH" in
    amd64)
        CF_ARCH="amd64"
        ;;
    arm64)
        CF_ARCH="arm64"
        ;;
    armhf)
        CF_ARCH="arm"
        ;;
    *)
        echo -e "${RED}Unsupported architecture: $ARCH${RESET}"
        exit 1
        ;;
esac

echo "Architecture: $CF_ARCH"

curl -fL \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
    -o /tmp/cloudflared

install -m 755 /tmp/cloudflared /usr/local/bin/cloudflared

rm -f /tmp/cloudflared

echo
/usr/local/bin/cloudflared --version
echo

echo -e "${GREEN}Cloudflared installed successfully.${RESET}"
echo

# ------------------------------------------
# 4. ASK FOR TUNNEL TOKEN
# ------------------------------------------

echo "=========================================="
echo "        CLOUDFLARE TUNNEL TOKEN"
echo "=========================================="
echo
echo "Paste your Cloudflare Tunnel Token."
echo "Input will remain hidden."
echo

read -rsp "Tunnel Token: " CF_TOKEN
echo
echo

if [ -z "$CF_TOKEN" ]; then
    echo -e "${RED}Token cannot be empty.${RESET}"
    exit 1
fi

# ------------------------------------------
# 5. EXTRACT TUNNEL ID + TEST TOKEN
# ------------------------------------------

echo -e "${CYAN}[4/7] Checking Tunnel Token...${RESET}"

mkdir -p /etc/cloudflared
chmod 700 /etc/cloudflared

# Extract tunnel ID from token
TUNNEL_ID=$(python3 - "$CF_TOKEN" <<'PY'
import sys
import base64
import json

token = sys.argv[1].strip()

try:
    decoded = base64.urlsafe_b64decode(
        token + "=" * (-len(token) % 4)
    )

    data = json.loads(decoded)

    tunnel_id = data.get("t", "")

    if tunnel_id:
        print(tunnel_id)

except Exception:
    pass
PY
)

if [ -z "$TUNNEL_ID" ]; then
    echo
    echo -e "${RED}Invalid Cloudflare Tunnel Token.${RESET}"
    echo "Please generate a fresh Tunnel Token and try again."
    exit 1
fi

echo -e "${GREEN}Tunnel ID detected:${RESET} $TUNNEL_ID"
echo

# Save token securely
printf '%s' "$CF_TOKEN" > /etc/cloudflared/token
chmod 600 /etc/cloudflared/token

# Clear shell variable
unset CF_TOKEN

echo "Testing Cloudflare Tunnel connection..."
echo

# Temporary test
rm -f /tmp/cloudflared-test.log

timeout 20 \
    /usr/local/bin/cloudflared tunnel run \
    --token "$(cat /etc/cloudflared/token)" \
    > /tmp/cloudflared-test.log 2>&1 &

TEST_PID=$!

sleep 10

if kill -0 "$TEST_PID" 2>/dev/null; then
    echo -e "${GREEN}Cloudflare Tunnel connected successfully.${RESET}"

    kill "$TEST_PID" 2>/dev/null || true
    wait "$TEST_PID" 2>/dev/null || true
else
    echo
    echo -e "${RED}Cloudflare Tunnel connection failed.${RESET}"
    echo
    cat /tmp/cloudflared-test.log
    echo
    exit 1
fi

rm -f /tmp/cloudflared-test.log

echo

# ------------------------------------------
# 6. ROOT PASSWORD
# ------------------------------------------

echo "=========================================="
echo "          CREATE ROOT PASSWORD"
echo "=========================================="
echo

passwd root

echo

# ------------------------------------------
# 7. SUPERVISOR AUTO-RESTART
# ------------------------------------------

echo -e "${CYAN}[5/7] Configuring Cloudflared auto-restart...${RESET}"

mkdir -p /var/log/cloudflared

cat > /etc/supervisor/conf.d/cloudflared.conf <<'EOF'
[program:cloudflared]
command=/bin/bash -c '/usr/local/bin/cloudflared tunnel run --token "$(cat /etc/cloudflared/token)"'
directory=/root

autostart=true
autorestart=true

startsecs=5
startretries=999999

stopasgroup=true
killasgroup=true

stdout_logfile=/var/log/cloudflared/cloudflared.log
stderr_logfile=/var/log/cloudflared/cloudflared-error.log

stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB

stdout_logfile_backups=3
stderr_logfile_backups=3
EOF

# ------------------------------------------
# SSH SUPERVISOR WATCHDOG
# ------------------------------------------

cat > /usr/local/bin/ssh-watchdog.sh <<'EOF'
#!/bin/bash

while true
do
    if ! ss -lnt 2>/dev/null | grep -q ':22 '; then
        mkdir -p /run/sshd
        /usr/sbin/sshd
    fi

    sleep 5
done
EOF

chmod +x /usr/local/bin/ssh-watchdog.sh

cat > /etc/supervisor/conf.d/ssh-watchdog.conf <<'EOF'
[program:ssh-watchdog]
command=/usr/local/bin/ssh-watchdog.sh
directory=/root

autostart=true
autorestart=true

startsecs=2
startretries=999999

stdout_logfile=/var/log/ssh-watchdog.log
stderr_logfile=/var/log/ssh-watchdog-error.log

stdout_logfile_maxbytes=5MB
stderr_logfile_maxbytes=5MB

stdout_logfile_backups=2
stderr_logfile_backups=2
EOF

echo -e "${GREEN}Auto-restart configured.${RESET}"
echo

# ------------------------------------------
# START SSH
# ------------------------------------------

echo -e "${CYAN}[6/7] Starting SSH...${RESET}"

mkdir -p /run/sshd

if ! ss -lnt 2>/dev/null | grep -q ':22 '; then
    /usr/sbin/sshd
fi

echo -e "${GREEN}SSH is running on port 22.${RESET}"
echo

# ------------------------------------------
# START SUPERVISOR
# ------------------------------------------

echo -e "${CYAN}[7/7] Starting services...${RESET}"

if ! pgrep -x supervisord >/dev/null 2>&1; then
    supervisord -c /etc/supervisor/supervisord.conf
    sleep 2
fi

supervisorctl reread
supervisorctl update

supervisorctl restart cloudflared 2>/dev/null || \
supervisorctl start cloudflared

supervisorctl restart ssh-watchdog 2>/dev/null || \
supervisorctl start ssh-watchdog

sleep 5

# ------------------------------------------
# FINAL STATUS
# ------------------------------------------

echo
echo "=========================================="
echo "             INSTALL COMPLETE"
echo "=========================================="
echo

echo -e "${GREEN}SSH:${RESET}"
echo "  User : root"
echo "  Port : 22"

echo
echo -e "${GREEN}Cloudflared:${RESET}"
supervisorctl status cloudflared

echo
echo -e "${GREEN}SSH Watchdog:${RESET}"
supervisorctl status ssh-watchdog

echo
echo -e "${GREEN}Tunnel ID:${RESET}"
echo "$TUNNEL_ID"

echo
echo "Cloudflared logs:"
echo "  tail -f /var/log/cloudflared/cloudflared.log"

echo
echo "SSH status:"
ss -lntp 2>/dev/null | grep ':22 ' || true

echo
echo "=========================================="
echo -e "${GREEN}       R-BOTS READY 🚀${RESET}"
echo "=========================================="
echo
