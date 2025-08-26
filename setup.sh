#!/bin/sh
# setup.sh - runs INSIDE the Alpine chroot during image build
set -eux

# --- Repos: pin stable + community (required for tiny-cloud and utilities) ---
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" > /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/community" >> /etc/apk/repositories
apk update

# --- Base packages for cloud usage on DO (keep minimal) ---
apk add --no-cache \
  linux-virt \
  openssh \
  e2fsprogs cloud-utils-growpart \
  tiny-cloud tiny-cloud-openrc tiny-cloud-digitalocean tiny-cloud-nocloud \
  wget curl ca-certificates bash

# --- Networking: bring up eth0 via DHCP using ifupdown-ng (OpenRC's networking) ---
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
rc-update add networking default

# --- SSH: enable on boot; generate host keys; key-only auth (DO injects keys) ---
rc-update add sshd default || true
ssh-keygen -A
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config

# --- Tiny Cloud: install early+default OpenRC services (cloud-init style bootstrap) ---
# This handles DO metadata (hostname, authorized_keys) + user-data + disk grow.
tiny-cloud --setup

# --- Serial console on DO/virt (lets you use the web console comfortably) ---
grep -q 'ttyS0' /etc/inittab || echo 'ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100' >> /etc/inittab

# --- User-data compatibility helper (runs once, late in boot; harmless if nothing to do) ---
install -m0755 -d /usr/local/bin
cat > /usr/local/bin/do-userdata-compat.sh <<'EOS'
#!/bin/sh
set -eu
UD="http://169.254.169.254/metadata/v1/user-data"
TMP="/run/user-data"
if wget -qO "$TMP" "$UD"; then
  first="$(head -n1 "$TMP" || true)"
  case "$first" in
    \#\!*) sh "$TMP" ;;
    \#cloud-config*)
      # very small parser for a basic runcmd list
      awk '/^runcmd:/,/^[^ ]/{print}' "$TMP" | sed '1d' | sed -E 's/^- (.+)$/\1/' | sh || true
      ;;
    *) : ;;
  esac
fi
EOS
chmod +x /usr/local/bin/do-userdata-compat.sh

# --- DigitalOcean Droplet Console agent: best-effort auto-install on first boot ---
cat > /usr/local/bin/install-do-console-agent.sh <<'EOS'
#!/bin/sh
set -eu
LOG="/var/log/do-console-agent-install.log"
FLAG="/var/lib/do-console-agent.installed"
mkdir -p "$(dirname "$LOG")" "$(dirname "$FLAG")"

# Skip if already marked installed
if [ -f "$FLAG" ]; then
  exit 0
fi

# If binary already present, mark success
if command -v droplet-agent >/dev/null 2>&1 || [ -d /opt/droplet-agent ] || [ -f /etc/systemd/system/droplet-agent.service ] || [ -f /etc/init.d/droplet-agent ]; then
  echo "$(date -Is) droplet-agent appears present; marking installed." >> "$LOG"
  : > "$FLAG"
  exit 0
fi

# Try official installer (requires bash). Do not fail boot if it rejects Alpine.
{
  echo "=== $(date -Is) Starting DO console agent install ==="
  if command -v curl >/dev/null 2>&1; then
    (curl -sSL https://repos-droplet.digitalocean.com/install.sh | bash) 2>&1
  else
    (wget -qO- https://repos-droplet.digitalocean.com/install.sh | bash) 2>&1
  fi
  echo "=== $(date -Is) Installer finished (exit=$?) ==="
} >> "$LOG" 2>&1 || true

# Mark as installed only if agent now exists
if command -v droplet-agent >/dev/null 2>&1 || [ -d /opt/droplet-agent ]; then
  : > "$FLAG"
  echo "$(date -Is) droplet-agent detected after install; success." >> "$LOG"
else
  echo "$(date -Is) droplet-agent not detected; likely unsupported on Alpine. See $LOG. Leaving MOTD hint." >> "$LOG"
fi

exit 0
EOS
chmod +x /usr/local/bin/install-do-console-agent.sh

# --- Hook both helpers to late boot (runs every boot, but each is idempotent/flagged) ---
mkdir -p /etc/local.d
cat > /etc/local.d/userdata.start <<'SH'
#!/bin/sh
/usr/local/bin/do-userdata-compat.sh || true
/usr/local/bin/install-do-console-agent.sh || true
SH
chmod +x /etc/local.d/userdata.start
rc-update add local default

# --- Show DigitalOcean Droplet Console agent instructions at login (MOTD) ---
cat > /etc/motd <<'MOTD'
DigitalOcean Droplet Console
Use the Droplet Console for native-like browser access to your Droplet.
This image auto-attempts to install the agent on first boot (see: /var/log/do-console-agent-install.log).

If needed, you can try manually:
  curl -sSL https://repos-droplet.digitalocean.com/install.sh | sudo bash
  # or
  wget -qO- https://repos-droplet.digitalocean.com/install.sh | sudo bash

Note: The script may refuse on unsupported distros; Alpine might require manual steps.
MOTD

# --- Cleanup apk cache to keep image tiny ---
rm -rf /var/cache/apk/*
