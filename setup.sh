#!/bin/sh
# setup.sh - runs INSIDE the Alpine chroot during image build
set -eux

# Repos (stable + community)
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" > /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/community" >> /etc/apk/repositories
apk update

# Base packages
apk add --no-cache \
  linux-virt \
  openssh \
  e2fsprogs cloud-utils-growpart \
  tiny-cloud tiny-cloud-openrc tiny-cloud-digitalocean tiny-cloud-nocloud \
  wget curl ca-certificates bash

# Networking: DHCP on eth0
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
rc-update add networking default

# SSH: enable, host keys, key-only auth
rc-update add sshd default || true
ssh-keygen -A
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
grep -q '^AuthorizedKeysFile' /etc/ssh/sshd_config || echo 'AuthorizedKeysFile .ssh/authorized_keys' >> /etc/ssh/sshd_config

# Tiny Cloud bootstrap: early via OpenRC; rest via local.d if no service
rc-update add tiny-cloud-early sysinit || true
if rc-service -l 2>/dev/null | grep -qx tiny-cloud; then
  rc-update add tiny-cloud default || true
else
  cat > /etc/local.d/05-tiny-cloud.start <<'SH'
#!/bin/sh
if command -v tiny-cloud >/dev/null 2>&1; then
  tiny-cloud boot   || true
  tiny-cloud main   || true
  tiny-cloud final  || true
fi
SH
  chmod +x /etc/local.d/05-tiny-cloud.start
fi

# Serial console for DO console
grep -q 'ttyS0' /etc/inittab || echo 'ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100' >> /etc/inittab

# User-data handler: supports write_files (literal/b64/gz+b64) + runcmd
install -m0755 -d /usr/local/bin
cat > /usr/local/bin/do-userdata-compat.sh <<'EOS'
#!/bin/sh
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
        __WF_PATH__\ *) P="${L#__WF_PATH__ }"; : > "$BODY"; ENC=""; rm -f "$BODY.b64" 2>/dev/null || true ;;
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

# DO metadata SSH key fetcher
cat > /usr/local/bin/do-fetch-keys.sh <<'EOS'
#!/bin/sh
set -eu
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [ ! -s /root/.ssh/authorized_keys ]; then
  wget -qO- http://169.254.169.254/metadata/v1/public-keys > /root/.ssh/authorized_keys || true
  chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
fi
EOS
chmod +x /usr/local/bin/do-fetch-keys.sh

# Local hooks: 05-tiny-cloud (above), 10-sshkeys, 90-userdata
mkdir -p /etc/local.d
cat > /etc/local.d/10-sshkeys.start <<'SH'
#!/bin/sh
/usr/local/bin/do-fetch-keys.sh || true
rc-service sshd restart || rc-service sshd start
SH
chmod +x /etc/local.d/10-sshkeys.start

cat > /etc/local.d/90-userdata.start <<'SH'
#!/bin/sh
/usr/local/bin/do-userdata-compat.sh || true
SH
chmod +x /etc/local.d/90-userdata.start

rc-update add local default

# MOTD
echo 'Alpine Linux on DigitalOcean' > /etc/motd

# Cleanup
rm -rf /var/cache/apk/*
