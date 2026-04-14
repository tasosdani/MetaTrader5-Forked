#!/bin/bash
set -euo pipefail

mt5file='/config/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe'
export WINEPREFIX='/config/.wine'
export WINEDEBUG='-all'

wine_executable="wine"
metatrader_version="5.0.36"
mt5server_port="${MT5_SERVER_PORT:-8001}"
MT5_CMD_OPTIONS="${MT5_CMD_OPTIONS:-}"

mono_url="https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi"
python_url="https://www.python.org/ftp/python/3.9.13/python-3.9.13.exe"
mt5setup_url="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

show_message() {
  echo "$1"
}

wait_for_path() {
  local path="$1"
  local tries="${2:-60}"
  local i=0
  while [ ! -e "$path" ] && [ "$i" -lt "$tries" ]; do
    sleep 1
    i=$((i + 1))
  done
  [ -e "$path" ]
}

check_dependency() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is not installed. Please install it to continue."
    exit 1
  fi
}

is_wine_python_ready() {
  $wine_executable python --version >/dev/null 2>&1
}

check_dependency "curl"
check_dependency "$wine_executable"
check_dependency "python3"
check_dependency "ss"

mkdir -p /config
mkdir -p "$WINEPREFIX"

show_message "[0/7] Initializing Wine prefix..."
wineboot -u || true

wait_for_path "/config/.wine/drive_c" 60 || {
  echo "Wine prefix was not initialized correctly."
  exit 1
}

mkdir -p /config/.wine/drive_c

if [ ! -e "/config/.wine/drive_c/windows/mono" ]; then
  show_message "[1/7] Downloading and installing Mono..."
  curl -L "$mono_url" -o /config/.wine/drive_c/mono.msi
  WINEDLLOVERRIDES=mscoree=d $wine_executable msiexec /i /config/.wine/drive_c/mono.msi /qn || true
  rm -f /config/.wine/drive_c/mono.msi
  show_message "[1/7] Mono install attempted."
else
  show_message "[1/7] Mono is already present."
fi

if [ ! -e "$mt5file" ]; then
  show_message "[2/7] MT5 not installed. Installing..."
  $wine_executable reg add "HKEY_CURRENT_USER\\Software\\Wine" /v Version /t REG_SZ /d "win10" /f || true
  show_message "[3/7] Downloading MT5 installer..."
  curl -L "$mt5setup_url" -o /config/.wine/drive_c/mt5setup.exe
  show_message "[3/7] Installing MetaTrader 5..."
  $wine_executable "/config/.wine/drive_c/mt5setup.exe" /auto || true
  rm -f /config/.wine/drive_c/mt5setup.exe
else
  show_message "[2/7] MT5 already installed."
fi

if [ -e "$mt5file" ]; then
  show_message "[4/7] Running MT5..."
  $wine_executable "$mt5file" $MT5_CMD_OPTIONS &
  sleep 10
else
  show_message "[4/7] MT5 still not installed. Cannot continue."
  exit 1
fi

if ! is_wine_python_ready; then
  show_message "[5/7] Installing Python in Wine..."
  curl -L "$python_url" -o /tmp/python-installer.exe
  $wine_executable /tmp/python-installer.exe /quiet InstallAllUsers=1 PrependPath=1 || true
  rm -f /tmp/python-installer.exe
  sleep 10
  show_message "[5/7] Python install attempted."
else
  show_message "[5/7] Python already available in Wine."
fi

show_message "[6/7] Installing Python libraries in Wine..."

$wine_executable python -m pip install --upgrade --no-cache-dir pip || true

# Remove potentially incompatible packages first
$wine_executable python -m pip uninstall -y \
  MetaTrader5 mt5linux numpy rpyc plumbum pyparsing \
  python-dateutil pypiwin32 pywin32 six || true

# MetaTrader5 currently needs NumPy 1.x
$wine_executable python -m pip install --no-cache-dir "numpy==1.26.4"
$wine_executable python -m pip install --no-cache-dir "MetaTrader5==$metatrader_version"
$wine_executable python -m pip install --no-cache-dir \
  "mt5linux==1.0.3" \
  "rpyc==5.2.3" \
  "plumbum==1.7.0" \
  "pyparsing>=3.1,<4" \
  python-dateutil

show_message "[6/7] Installing Linux-side bridge libraries..."

python3 -m pip install --break-system-packages --no-cache-dir \
  "mt5linux==1.0.3" \
  "rpyc==5.2.3" \
  "plumbum==1.7.0" \
  "pyparsing>=3.1,<4" \
  numpy \
  pyxdg

show_message "[7/7] Starting mt5linux server..."
wine python -m mt5linux --host 0.0.0.0 --port "$mt5server_port" &
sleep 10

if ss -tuln | grep ":$mt5server_port" >/dev/null; then
  show_message "[7/7] mt5linux server is running on port $mt5server_port."
else
  show_message "[7/7] Failed to start mt5linux server on port $mt5server_port."
  exit 1
fi

wait
