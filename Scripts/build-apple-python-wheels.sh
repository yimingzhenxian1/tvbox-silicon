#!/bin/bash
# The compiled libraries for the iOS and tvOS Python (Scripts/build-apple-python.sh): pycryptodome, and lxml
# with libxml2 and libxslt linked in statically. A BeeWare cross venv makes pip compile them from source for
# one platform; the wheels land in build/apple-python/wheels/<platform>. Versions follow
# Runtime/PythonHost/requirements.txt, like the Mac's host.
# Usage: Scripts/build-apple-python-wheels.sh [ios|ios-simulator|tvos|tvos-simulator]
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:-ios}"
case "$TARGET" in
  ios) FAMILY=iOS; PLATFORM=iphoneos; SLICE=ios-arm64; COMPILER=arm64-apple-ios ;;
  ios-simulator) FAMILY=iOS; PLATFORM=iphonesimulator; SLICE=ios-arm64_x86_64-simulator; COMPILER=arm64-apple-ios-simulator ;;
  tvos) FAMILY=tvOS; PLATFORM=appletvos; SLICE=tvos-arm64; COMPILER=arm64-apple-tvos ;;
  tvos-simulator) FAMILY=tvOS; PLATFORM=appletvsimulator; SLICE=tvos-arm64_x86_64-simulator; COMPILER=arm64-apple-tvos-simulator ;;
  *) echo "Usage: $0 [ios|ios-simulator|tvos|tvos-simulator]" >&2; exit 2 ;;
esac
VERSION=3.14; SUPPORT=b13
LIBXML2=2.14.6; LIBXML2_SHA256=7ce458a0affeb83f0b55f1f4f9e0e55735dbfc1a9de124ee86fb4a66b597203a
# The versions lxml's own macOS and Linux wheels use, with the libxslt fixes its sdist carries.
LIBXSLT=1.1.43; LIBXSLT_SHA256=5a3d6b383ca5afc235b171118e90f5ff6aa27e9fea3303065231a6d403f0183a
pinned() { grep -E "^$1==" Runtime/PythonHost/requirements.txt | cut -d= -f3; }
PYCRYPTODOME="$(pinned pycryptodome)"; LXML="$(pinned lxml)"
HOST_PYTHON="${HOST_PYTHON:-$(command -v python$VERSION || true)}"
[ -x "$HOST_PYTHON" ] || { echo "Install Python $VERSION (brew install python@$VERSION) or set HOST_PYTHON." >&2; exit 1; }
WORK="$PWD/build/apple-python"
XCFRAMEWORK="$WORK/$FAMILY-$VERSION-$SUPPORT/Python.xcframework"
[ -d "$XCFRAMEWORK" ] || { echo "Missing $XCFRAMEWORK: run Scripts/build-apple-python.sh $TARGET." >&2; exit 1; }
WHEELS="$WORK/wheels/$PLATFORM"
mkdir -p "$WHEELS" "$WORK/sources"
# BeeWare's compiler wrappers (arm64-apple-ios-clang and so on) read the deployment target from here.
export IPHONEOS_DEPLOYMENT_TARGET=15.6 TVOS_DEPLOYMENT_TARGET=17.0
export PATH="$XCFRAMEWORK/$SLICE/bin:$PATH"

# pip in this venv believes it runs on the device's platform, so it compiles for it with the wrappers.
VENV="$WORK/venv-$PLATFORM"
if [ ! -f "$VENV/lib/python$VERSION/site-packages/_cross_venv.pth" ]; then
  rm -rf "$VENV"
  "$HOST_PYTHON" -m venv "$VENV"
  "$HOST_PYTHON" "$XCFRAMEWORK/$SLICE/platform-config/arm64-$PLATFORM/make_cross_venv.py" "$VENV" \
    "$XCFRAMEWORK/$SLICE/platform-config/arm64-$PLATFORM"
fi
# Only the arm64 slice: the apps build for arm64 only (project.yml), simulators included.
PIP=(env ARCHFLAGS="-arch arm64" "$VENV/bin/python" -m pip --disable-pip-version-check)

if ! ls "$WHEELS"/pycryptodome-"$PYCRYPTODOME"-*.whl >/dev/null 2>&1; then
  "${PIP[@]}" wheel --quiet --no-deps --no-binary :all: "pycryptodome==$PYCRYPTODOME" -w "$WHEELS"
fi

fetch() {  # url sha256 -> the unpacked folder in $WORK/sources
  local archive="$WORK/sources/$(basename "$1")"
  if [ ! -f "$archive" ]; then
    curl -fL --retry 2 "$1" -o "$archive.download"
    mv "$archive.download" "$archive"
  fi
  echo "$2  $archive" | shasum -a 256 -c - >/dev/null
  [ -d "${archive%.tar.xz}" ] || tar -xJf "$archive" -C "$WORK/sources"
}

if ! ls "$WHEELS"/lxml-"$LXML"-*.whl >/dev/null 2>&1; then
  SDIST="$WORK/sources/lxml-$LXML.tar.gz"
  [ -f "$SDIST" ] || "$HOST_PYTHON" -m pip download --quiet --disable-pip-version-check --no-deps --no-binary :all: \
    "lxml==$LXML" -d "$WORK/sources"
  # Static libxml2 and libxslt, linked into lxml's modules. iconv and zlib come with the SDK.
  DEPS="$WORK/xml-$PLATFORM"
  if [ ! -f "$DEPS/lib/libxslt.a" ] || ! grep -q "^$LIBXML2 $LIBXSLT\$" "$DEPS/versions" 2>/dev/null; then
    fetch "https://download.gnome.org/sources/libxml2/${LIBXML2%.*}/libxml2-$LIBXML2.tar.xz" "$LIBXML2_SHA256"
    fetch "https://download.gnome.org/sources/libxslt/${LIBXSLT%.*}/libxslt-$LIBXSLT.tar.xz" "$LIBXSLT_SHA256"
    if [ ! -f "$WORK/sources/libxslt-$LIBXSLT/.lxml-patched" ]; then
      tar -xzOf "$SDIST" "lxml-$LXML/libxslt-$LIBXSLT-backport1.patch" | patch -s -p1 -d "$WORK/sources/libxslt-$LIBXSLT"
      touch "$WORK/sources/libxslt-$LIBXSLT/.lxml-patched"
    fi
    rm -rf "$DEPS" && mkdir -p "$DEPS/build/libxml2" "$DEPS/build/libxslt"
    COMMON=(--host=aarch64-apple-darwin --prefix="$DEPS" --disable-shared --enable-static --without-python)
    (cd "$DEPS/build/libxml2" && CC="$COMPILER-clang" AR="$COMPILER-ar" CFLAGS="-O2" \
      "$WORK/sources/libxml2-$LIBXML2/configure" "${COMMON[@]}" --with-zlib --with-iconv --without-lzma --without-icu \
      && make -j "${JOBS:-8}" && make install) >"$DEPS/build/libxml2.log" 2>&1 \
      || { tail -30 "$DEPS/build/libxml2.log" >&2; exit 1; }
    (cd "$DEPS/build/libxslt" && CC="$COMPILER-clang" AR="$COMPILER-ar" CFLAGS="-O2" \
      "$WORK/sources/libxslt-$LIBXSLT/configure" "${COMMON[@]}" --with-libxml-prefix="$DEPS" --without-crypto \
      && make -j "${JOBS:-8}" && make install) >"$DEPS/build/libxslt.log" 2>&1 \
      || { tail -30 "$DEPS/build/libxslt.log" >&2; exit 1; }
    echo "$LIBXML2 $LIBXSLT" > "$DEPS/versions"
  fi
  # lxml asks pkg-config before xml2-config; keep it from finding the Mac's own libxml2. xml2-config
  # leaves out iconv, which the SDK keeps in its own library.
  PKG_CONFIG=/usr/bin/false XML2_CONFIG="$DEPS/bin/xml2-config" XSLT_CONFIG="$DEPS/bin/xslt-config" LDFLAGS="-liconv" \
    "${PIP[@]}" wheel --quiet --no-deps "$SDIST" -w "$WHEELS"
fi
ls "$WHEELS"
