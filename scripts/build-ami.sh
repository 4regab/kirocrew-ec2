#!/bin/bash
# ---------------------------------------------------------------------------
# build-ami.sh
#
# Runs ON a throwaway builder instance (see docs/02-setup-guide.md step 6).
# Installs the OS packages the application needs, drops in the three instance
# scripts and five systemd units, and ENABLES the boot units.
#
# It never STARTS the units. That matters: if the storage unit started here,
# the builder would try to attach the data volume and could interfere with the
# live instance. Enable-then-stop-then-image is the safe order.
#
# Usage on the builder, as root:
#   /tmp/kirocrew-build/build-ami.sh
# expects, relative to its own directory:
#   config.env
#   instance/kirocrew-storage.sh
#   instance/kirocrew-spot-watch.sh
#   instance/kirocrew-selfheal.sh
#   systemd/*.service
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$HERE/config.env" ] || { echo "FATAL: $HERE/config.env not found"; exit 1; }
# shellcheck disable=SC1091
. "$HERE/config.env"

: "${OS_PACKAGES:?}" "${APP_USER:?}" "${APP_USER_EXTRA_GROUPS:?}"

echo "########## 1. OS packages ##########"
dnf install -y $OS_PACKAGES

if [ "${INSTALL_GH_CLI:-no}" = "yes" ]; then
  echo "########## 2. GitHub CLI ##########"
  cat > /etc/yum.repos.d/gh-cli.repo <<'EOF'
[gh-cli]
name=packages for the GitHub CLI
baseurl=https://cli.github.com/packages/rpm
enabled=1
gpgcheck=1
gpgkey=https://cli.github.com/packages/githubcli-archive-keyring.asc
EOF
  dnf install -y gh || echo "WARN: gh install failed (non-fatal)"
fi

if [ "${INSTALL_CHROME:-no}" = "yes" ]; then
  echo "########## 3. Google Chrome (browser automation) ##########"
  cat > /etc/yum.repos.d/google-chrome.repo <<'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
  dnf install -y google-chrome-stable || echo "WARN: chrome install failed (non-fatal)"
fi

echo "########## 4. app user groups + linger ##########"
# Extra groups typically include systemd-journal so the user can read logs.
usermod -aG "$APP_USER_EXTRA_GROUPS" "$APP_USER"
# Linger makes systemd start user@<uid>.service at boot without a login, which
# the gateway needs because it spawns per-agent scopes via `systemd-run --user`.
mkdir -p /var/lib/systemd/linger
touch "/var/lib/systemd/linger/${APP_USER}"

echo "########## 5. install config ##########"
install -d -m 0755 /etc/kirocrew
install -m 0644 "$HERE/config.env" /etc/kirocrew/config.env

echo "########## 6. install instance scripts ##########"
install -m 0755 "$HERE/instance/kirocrew-storage.sh"    /usr/local/sbin/
install -m 0755 "$HERE/instance/kirocrew-spot-watch.sh" /usr/local/sbin/
install -m 0755 "$HERE/instance/kirocrew-selfheal.sh"   /usr/local/sbin/
for s in /usr/local/sbin/kirocrew-*.sh; do bash -n "$s" && echo "syntax OK: $s"; done

echo "########## 7. install systemd units ##########"
install -m 0644 "$HERE"/systemd/*.service /etc/systemd/system/
systemctl daemon-reload

echo "########## 8. enable boot units (NOT started) ##########"
systemctl enable kirocrew-storage.service
systemctl enable kirocrew.service
systemctl enable kirocrew-tmux.service
systemctl enable kirocrew-spot-watch.service
# kirocrew-selfheal.service is intentionally NOT enabled - it is static and
# only ever runs via OnFailure= from the storage unit.

echo "########## 9. verification ##########"
echo "--- enabled (expect: enabled x4) ---"
systemctl is-enabled kirocrew-storage.service kirocrew.service \
                     kirocrew-tmux.service kirocrew-spot-watch.service
echo "--- selfheal must be static ---"
systemctl show kirocrew-selfheal.service -p UnitFileState
echo "--- OnFailure must be wired ---"
systemctl show kirocrew-storage.service -p OnFailure
echo "--- active (expect: inactive on the builder) ---"
systemctl is-active kirocrew-storage.service kirocrew.service \
                    kirocrew-tmux.service kirocrew-spot-watch.service || true
echo "--- tooling ---"
for c in git tmux jq rsync gh wget unzip; do
  printf '%-8s ' "$c"; command -v "$c" || echo MISSING
done
echo "--- linger ---"
ls -la /var/lib/systemd/linger/
echo "--- app user ---"
id "$APP_USER"

echo "########## BUILD COMPLETE ##########"
echo "Next: stop this instance, then create-image with --no-reboot, then terminate it."
