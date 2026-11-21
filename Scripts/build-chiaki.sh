#!/bin/zsh
# Fetches chiaki-ng (the PS Remote Play protocol library) at a pinned commit and builds it as static
# libraries.
# Requires: brew install cmake pkgconf miniupnpc libevent json-c opus openssl@3 curl protobuf
# The `protobuf` Python module for the nanopb generator is installed into Vendor/build/venv.
# Output: Vendor/build/chiaki (libchiaki.a and helper libraries).
set -euo pipefail

cd "$(dirname "$0")/.."
# The same commit Veyra for Windows uses.
CHIAKI_COMMIT="0e16950165f06e5c3291537c2eeba6e852be7120"
SOURCE="Vendor/chiaki-ng"
BUILD="Vendor/build/chiaki"

if [[ ! -d "$SOURCE/.git" ]]; then
  mkdir -p Vendor
  git clone --filter=blob:none --no-checkout https://github.com/streetpea/chiaki-ng.git "$SOURCE"
fi
git -C "$SOURCE" checkout --quiet --detach "$CHIAKI_COMMIT"
git -C "$SOURCE" submodule update --init --depth 1 third-party/nanopb third-party/jerasure third-party/gf-complete

BREW="$(brew --prefix)"
# The nanopb generator needs the `protobuf` Python module, no older than `protoc`.
# It lives in a local virtual environment so system packages stay untouched.
VENV="Vendor/build/venv"
PROTOC_VERSION="$(protoc --version | awk '{print $2}')"
if [[ ! -x "$VENV/bin/python" ]]; then
  mkdir -p Vendor/build
  python3 -m venv "$VENV"
fi
"$VENV/bin/python" -c "import google.protobuf" 2>/dev/null || "$VENV/bin/pip" install --quiet "protobuf==7.$PROTOC_VERSION"
PYTHON="$PWD/$VENV/bin/python"
export PKG_CONFIG_PATH="$BREW/opt/curl/lib/pkgconfig:$BREW/opt/openssl@3/lib/pkgconfig:$BREW/lib/pkgconfig"

cmake -S "$SOURCE" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_PREFIX_PATH="$BREW/opt/curl;$BREW/opt/openssl@3;$BREW" \
  -DOPENSSL_ROOT_DIR="$BREW/opt/openssl@3" \
  -DPYTHON_EXECUTABLE="$PYTHON" -DPython_EXECUTABLE="$PYTHON" -DPython3_EXECUTABLE="$PYTHON" \
  -DCHIAKI_ENABLE_GUI=OFF -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_TESTS=OFF \
  -DCHIAKI_ENABLE_SETSU=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF \
  -DCHIAKI_ENABLE_SPEEX=OFF -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF -DCHIAKI_ENABLE_PI_DECODER=OFF \
  -DCHIAKI_USE_SYSTEM_CURL=ON -DCHIAKI_USE_SYSTEM_NANOPB=OFF -DCHIAKI_USE_SYSTEM_JERASURE=OFF \
  > "$BUILD.configure.log" 2>&1 || { tail -30 "$BUILD.configure.log"; exit 1; }

cmake --build "$BUILD" --target chiaki-lib -j 8 > "$BUILD.build.log" 2>&1 || { grep -E "error|Error" "$BUILD.build.log" | head -30; exit 1; }

find "$BUILD" -name '*.a' | sort
echo "Done: $BUILD"
