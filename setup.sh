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

# --- User-data compatibility helper (adds write_files {literal,b64,gz+b64} then runs runcmd) ---
install -m0755 -d /usr/local/bin
cat > /usr/local/bin/do-userdata-compat.sh <<'EOS'
#!/bin/sh
# Minimal cloud-config handler for Alpine + Tiny Cloud
# Supports:
#   write_files:
#     - path: /path/file
#       content: |    (literal)   OR content: <base64>
#       encoding: b64 | base64 | gz+b64 | gzip+b64   (optional)
#   runcmd:
set -eu

UD_URL="http://169.254.169.254/metadata/v1/user-data"
UD="/run/user-data"

fetch_ud() { wget -qO "$UD" "$UD_URL" || return 1; [ -s "$UD" ] || return 1; }

apply_write_files() {
  awk '
    BEGIN{ inwf=0; initem=0; incontent=0; }
    /^write_files:/ { inwf=1; next }
    {
      if (inwf==1) {
        if ($0 ~ /^[^ ]/ && $0 !~ /^write_files:/) { if (initem==1) print "__WF_FLUSH__"; exit }
        if ($0 ~ /^ *- +path:[ ]*/) {
          if (initem==1) print "__WF_FLUSH__"
          initem=1; incontent=0
          path=$0; sub(/^ *- +path:[ ]*/,"",path); gsub(/^[ \t]+|[ \t]+$/,"",path)
          print "__WF_PATH__ " path; next
        }
        if ($0 ~ /^[ \t]*encoding:[ ]*/) {
          enc=$0; sub(/^[ \t]*encoding:[ ]*/,"",enc); gsub(/^[ \t]+|[ \t]+$/,"",enc)
          print "__WF_ENC__ " enc; next
        }
        if ($0 ~ /^[ \t]*content:[ ]*\|[ \t]*$/) { incontent=1; next }
        if ($0 ~ /^[ \t]*content:[ ]*[^|].*$/) {
          c=$0; sub(/^[ \t]*content:[ ]*/,"",c); gsub(/^[ \t]+|[ \t]+$/,"",c)
          print "__WF_B64__ " c; next
        }
        if (initem==1 && incontent==1) {
          if ($0 ~ /^[ \t]*[A-Za-z0-9_-]+:/ || $0 ~ /^ *- +path:/) { incontent=0; next }
          line=$0; sub(/^[ \t]+/,"",line); print "__WF_LINE__ " line; next
        }
      }
    }
    END { if (inwf==1 && initem==1) print "__WF_FLUSH__" }
  ' "$UD" | (
    P="" ; ENC="" ; BODY="/run/_wf_body"; : > "$BODY"
    while IFS= read -r L; do
      case "$L" in
        __WF_PATH__\ *) P="${L#__WF_PATH__ }"; : > "$BODY" ; ENC=""; rm -f "$BODY.b64" 2>/dev/null || true ;;
        __WF_ENC__\ *)  ENC="${L#__WF_ENC__ }" ;;
        __WF_LINE__\ *) printf "%s\n" "${L#__WF_LINE__ }" >> "$BODY" ;;
        __WF_B64__\ *)  printf "%s\n" "${L#__WF_B64__ }" > "$BODY.b64" ;;
        __WF_FLUSH__ )
          [ -n "$P" ] || { : > "$BODY"; rm -f "$BODY.b64" 2>/dev/null || true; continue; }
          mkdir -p "$(dirname "$P")"
          TMP="$P.tmp.$$"; ENC_N="$(printf '%s' "$ENC" | tr '[:upper:]' '[:lower:]')"
          if [ -f "$BODY.b64" ] && [ -s "$BODY.b64" ]; then
            if [ "$ENC_N" = "gz+b64" ] || [ "$ENC_N" = "gzip+b64" ]; then
              base64 -d "$BODY.b64" | gzip -d > "$TMP"
            else
              base64 -d "$BODY.b64" > "$TMP"
            fi
          else
            cp "$BODY" "$TMP"
          fi
          chmod 0644 "$TMP"; mv "$TMP" "$P"
          P=""; ENC=""; : > "$BODY"; rm -f "$BODY.b64" 2>/dev/null || true
          ;;
      esac
    done
    rm -f "$BODY" "$BODY.b64" 2>/dev/null || true
  )
}

run_runcmd() {
  awk '
    /^runcmd:/ { inrc=1; next }
    inrc==1 {
      if ($0 ~ /^[^ ]/ && $0 !~ /^ /) { exit }
      if ($0 ~ /^ *- /) { sub(/^ *- /,""); print }
    }
  ' "$UD" | sh || true
}

main() {
  fetch_ud || exit 0
  case "$(head -n1 "$UD" || true)" in
    \#cloud-config*) apply_write_files; run_runcmd ;;
    \#\!*)           sh "$UD" || true ;;
    *)               : ;;
  esac
}
main
EOS
chmod +x /usr/local/bin/do-userdata-compat.sh

# --- DigitalOcean Droplet Console agent: best-effort auto-install on first boot ---
cat > /usr/local/bin/install-do-console-agent.sh <<'EOS'
#!/bin/sh
set -eu
LOG="/var/log/do-console-agent-install.log"
FLAG="/var/lib/do-console-agent.installed"
mkdir -p "$(dirname "$LOG")" "$(dirname "$FLAG")"

[ -f "$FLAG" ] && exit 0

if command -v droplet-agent >/dev/null 2>&1 || [ -d /opt/droplet-agent ] || \
   [ -f /etc/systemd/system/droplet-agent.service ] || [ -f /etc/init.d/droplet-agent ]; then
  echo "$(date -Is) droplet-agent appears present; marking installed." >> "$LOG"
  : > "$FLAG"; exit 0
fi

{
  echo "=== $(date -Is) Starting DO console agent install ==="
  if command -v curl >/dev/null 2>&1; then
    (curl -sSL https://repos-droplet.digitalocean.com/install.sh | bash) 2>&1
  else
    (wget -qO- https://repos-droplet.digitalocean.com/install.sh | bash) 2>&1
  fi
  echo "=== $(date -Is) Installer finished (exit=$?) ==="
} >> "$LOG" 2>&1 || true

if command -v droplet-agent >/dev/null 2>&1 || [ -d /opt/droplet-agent ]; then
  : > "$FLAG"; echo "$(date -Is) droplet-agent detected after install; success." >> "$LOG"
else
  echo "$(date -Is) droplet-agent not detected; likely unsupported on Alpine. See $LOG." >> "$LOG"
fi
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
MOTD

# --- Cleanup apk cache to keep image tiny ---
rm -rf /var/cache/apk/*
