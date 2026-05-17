#!/bin/bash
# ─────────────────────────────────────────────────────────
# Install Host Dependencies
#
# Installs system packages required by the infrastructure
# tooling. Docker is managed separately.
#
# Usage:
#   sudo ./scripts/install-deps.sh
# ─────────────────────────────────────────────────────────
set -euo pipefail

# ─── Must run as root ───
if [[ "${EUID}" -ne 0 ]]; then
    echo "❌ This script must be run as root (use sudo)." >&2
    exit 1
fi

echo "━━━ Installing Infrastructure Dependencies ━━━"
echo ""

# ─── Detect package manager ───
if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
else
    echo "❌ No supported package manager found (apt, dnf, yum)." >&2
    exit 1
fi

echo "Detected package manager: ${PKG_MANAGER}"
echo ""

# ─── Package list ───
# Add new dependencies here as the infrastructure grows.
PACKAGES=(
    apache2-utils   # htpasswd — generate Basic Auth credentials for nginx gateway
)

# ─── Install ───
echo "Installing packages: ${PACKAGES[*]}"
echo ""

case "${PKG_MANAGER}" in
    apt)
        apt-get update -qq
        apt-get install -y --no-install-recommends "${PACKAGES[@]}"
        ;;
    dnf)
        # On RHEL/Fedora the package is httpd-tools, not apache2-utils
        RHEL_PACKAGES=("${PACKAGES[@]/apache2-utils/httpd-tools}")
        dnf install -y "${RHEL_PACKAGES[@]}"
        ;;
    yum)
        YUM_PACKAGES=("${PACKAGES[@]/apache2-utils/httpd-tools}")
        yum install -y "${YUM_PACKAGES[@]}"
        ;;
esac

echo ""
echo "━━━ Verification ━━━"

# ─── Verify each tool is available ───
TOOLS=(
    "htpasswd:Generate Basic Auth passwords"
)

ALL_OK=true
for entry in "${TOOLS[@]}"; do
    TOOL="${entry%%:*}"
    DESC="${entry#*:}"
    if command -v "${TOOL}" &>/dev/null; then
        echo "  ✅ ${TOOL} — ${DESC}"
    else
        echo "  ❌ ${TOOL} — NOT FOUND"
        ALL_OK=false
    fi
done

echo ""
if [[ "${ALL_OK}" == true ]]; then
    echo "━━━ All dependencies installed successfully ━━━"
else
    echo "⚠️  Some dependencies are missing. Check the output above." >&2
    exit 1
fi
