#!/usr/bin/env bash
# EmComm Tools OS: install Artemis 4.1.0 from source on Ubuntu/Debian.
# Keeps compatibility with tests/test-artemis.sh and its /opt/artemis/app.bin path.
set -Eeuo pipefail

trap 'status=$?; printf "[artemis] ERROR on line %s (exit %s): %s\n" "$LINENO" "$status" "$BASH_COMMAND" >&2' ERR

log() { printf '[artemis] %s\n' "$*"; }
die() { printf '[artemis] ERROR: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || die 'Run as root: sudo bash scripts/install-artemis.sh'

APP_VERSION='4.1.0'
INSTALL_DIR="/opt/artemis-${APP_VERSION}"
LINK_PATH='/opt/artemis'
REPO_URL='https://github.com/AresValley/Artemis.git'
# v4.1.0's actual release commit; never silently use the latest source.
EXPECTED_COMMIT='7c6fc179a10177ba01ba5a8d87dc9554f5961e0d'

log "Installing Artemis ${APP_VERSION} from its tagged source..."
log 'Installing system requirements (no .deb or ZIP package required)...'
apt-get install -y \
  git python3 python3-venv ca-certificates \
  libgl1 libegl1 libxkbcommon-x11-0 \
  libxcb-cursor0 libxcb-icccm4 libxcb-keysyms1 libxcb-shape0 \
  libxcb-image0 libxcb-render-util0 libxcb-xinerama0

# Prefer Python 3.12 (the upstream v4.1.0 build version).
# PySide6==6.8.0.1 also supports Python 3.10 and 3.11.
# Python 3.13/3.14 need a newer PySide6 for compatibility.
PYTHON_BIN=''
for candidate in python3.12 python3.11 python3.10 python3.13 python3.14 python3; do
  if command -v "$candidate" >/dev/null 2>&1 && \
      "$candidate" -c 'import sys; assert (3, 10) <= sys.version_info[:2] < (3, 15)' 2>/dev/null; then
    PYTHON_BIN="$(command -v "$candidate")"
    break
  fi
done
[[ -n "$PYTHON_BIN" ]] || die 'Python 3.10 through 3.14 required; no compatible interpreter was found.'
PYTHON_VERSION="$($PYTHON_BIN -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
log "Using ${PYTHON_BIN} (Python ${PYTHON_VERSION})."

# The named interpreter may need its own -venv package, even when
# python3-venv (for the distro default interpreter) is already installed.
VENV_PACKAGE="python${PYTHON_VERSION}-venv"
if apt-cache show "$VENV_PACKAGE" >/dev/null 2>&1; then
  apt-get install -y "$VENV_PACKAGE"
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
  ACTUAL_COMMIT="$(git -C "$INSTALL_DIR" rev-parse HEAD)"
  [[ "$ACTUAL_COMMIT" == "$EXPECTED_COMMIT" ]] || \
    die "${INSTALL_DIR} exists but is not the Artemis v${APP_VERSION} checkout; refusing to overwrite it."
  log "Reusing existing verified Artemis v${APP_VERSION} checkout."
elif [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
  die "${INSTALL_DIR} already exists without the correct Git checkout. Move it aside, then rerun."
else
  git clone --depth 1 --branch "v${APP_VERSION}" "$REPO_URL" "$INSTALL_DIR"
  ACTUAL_COMMIT="$(git -C "$INSTALL_DIR" rev-parse HEAD)"
  [[ "$ACTUAL_COMMIT" == "$EXPECTED_COMMIT" ]] || \
    die "Unexpected source revision: ${ACTUAL_COMMIT}; expected ${EXPECTED_COMMIT}."
fi

[[ -f "$INSTALL_DIR/app.py" ]] || die 'Artemis 4.1.0 app.py was not found.'
[[ -f "$INSTALL_DIR/requirements.txt" ]] || die 'Artemis 4.1.0 requirements.txt was not found.'

VENV_DIR="${INSTALL_DIR}/.venv"
if [[ -x "${VENV_DIR}/bin/python" ]]; then
  VENV_VERSION="$("${VENV_DIR}/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  if [[ "$VENV_VERSION" != "$PYTHON_VERSION" ]]; then
    log "Existing virtual environment uses Python ${VENV_VERSION}; recreating it for ${PYTHON_VERSION}."
    rm -rf -- "$VENV_DIR"
  fi
fi
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR" || die "Could not make virtual environment; check ${VENV_PACKAGE}."
fi

log 'Installing source dependencies inside an isolated Python virtual environment...'
"${VENV_DIR}/bin/python" -m pip install --upgrade pip
REQUIREMENTS="${INSTALL_DIR}/requirements.txt"
if [[ "$PYTHON_VERSION" == '3.13' || "$PYTHON_VERSION" == '3.14' ]]; then
  # Keep Artemis source at v4.1.0, but update its old Qt binding for newer Python.
  # PySide6 6.10.3 supports Python 3.13/3.14; the original pin does not.
  log "Python ${PYTHON_VERSION} needs a newer PySide6 than Artemis 4.1.0 originally pinned."
  REQUIREMENTS="${INSTALL_DIR}/.artemis-compatible-requirements.txt"
  awk '/^PySide6==/ { print "PySide6==6.10.3"; next } { print }' \
    "${INSTALL_DIR}/requirements.txt" > "$REQUIREMENTS"
fi
"${VENV_DIR}/bin/python" -m pip install -r "$REQUIREMENTS"
"${VENV_DIR}/bin/python" -c 'import PySide6.QtCore, PySide6.QtQml, PySide6.QtMultimedia, requests, packaging'

# For 4.1.0, the correct entry point is app.py (NOT python -m artemis).
# A real executable shell wrapper at app.bin satisfies EmComm's existing test.
log 'Creating /opt/artemis/app.bin compatibility launcher...'
cat > "${INSTALL_DIR}/app.bin" <<'LAUNCHER'
#!/bin/sh
set -eu
cd /opt/artemis-4.1.0
exec /opt/artemis-4.1.0/.venv/bin/python /opt/artemis-4.1.0/app.py "$@"
LAUNCHER
chmod 755 "${INSTALL_DIR}/app.bin"

if [[ -e "$LINK_PATH" && ! -L "$LINK_PATH" ]]; then
  die "${LINK_PATH} exists as a real directory/file; refusing to overwrite it."
fi
ln -sfnT "$INSTALL_DIR" "$LINK_PATH"

log 'Installing the system-wide desktop launcher...'
install -d -m 755 /usr/share/applications
cat > /usr/share/applications/artemis.desktop <<'DESKTOP'
[Desktop Entry]
Name=Artemis
Comment=Radio signal identification
Exec=/opt/artemis/app.bin
Icon=/opt/artemis/images/artemis_icon.svg
Terminal=false
Type=Application
Categories=Utility;
StartupNotify=true
DESKTOP

[[ -x /opt/artemis/app.bin ]] || die 'EmComm path test failed: /opt/artemis/app.bin missing.'
log "Artemis ${APP_VERSION} installed at ${INSTALL_DIR}."
log 'Run /opt/artemis/app.bin as your desktop user (not root) to test the GUI.'
