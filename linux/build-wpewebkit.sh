#!/usr/bin/env bash
#
# Builds local .deb packages for the WPE WebKit stack (libwoff2, libwpe,
# WPEBackend-fdo and WPEWebKit itself) from source.
#
# Why this exists: Wimsy's Linux build embeds WebXDC mini-apps via
# flutter_webxdc_linux -> flutter_inappwebview_forge_linux, whose native
# backend requires the WPE WebKit runtime/dev packages (wpe-webkit-2.0,
# wpe-platform-2.0/wpebackend-fdo-1.0, libwpe-1.0 pkg-config modules; see
# flutter_webxdc_linux's README for the full rationale). Newer Ubuntu
# releases (24.04+, including 26.04 "Resolute Raccoon") no longer ship
# these packages in their archives, so `flutter build linux` fails with
# missing packages unless they are built from source first.
#
# This script is adapted from the build steps in the reference workflow at
# https://github.com/hobleyd/wpe-webkit-linux/blob/main/.github/workflows/build.yml
# but is a plain local build script rather than a CI workflow: it does not
# sign or publish an APT repository, it just compiles each component and
# produces .deb files under build/wpewebkit/pkg for local installation via
# `sudo dpkg -i` (or pass --install to do that automatically).
#
# Usage:
#   ./linux/build-wpewebkit.sh           # build only
#   ./linux/build-wpewebkit.sh --install # build, then install the .debs
#
# Run this directly on an Ubuntu 26.04 (or compatible Debian-family) host
# with sudo access -- it is not containerized. WPEWebKit itself takes
# roughly 60-90 minutes to compile, depending on hardware.
#
# Environment variables (all optional; defaults are the latest stable
# releases at the time of writing, per https://wpewebkit.org/about/get-wpe.html):
#   WPEWEBKIT_VERSION       (default: 2.52.6)
#   LIBWPE_VERSION          (default: 1.16.3)
#   WPEBACKEND_FDO_VERSION  (default: 1.16.1)

set -euo pipefail

WPEWEBKIT_VERSION="${WPEWEBKIT_VERSION:-2.52.6}"
LIBWPE_VERSION="${LIBWPE_VERSION:-1.16.3}"
WPEBACKEND_FDO_VERSION="${WPEBACKEND_FDO_VERSION:-1.16.1}"

INSTALL_AFTER_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL_AFTER_BUILD=1 ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--install]" >&2
      exit 1
      ;;
  esac
done

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Please run this script as a normal user (it uses sudo where needed), not as root." >&2
  exit 1
fi

# Detect the distro codename to use as the package version suffix, e.g.
# "resolute" for Ubuntu 26.04. Falls back to "resolute" if detection fails,
# since that is this script's primary target.
DISTRO="resolute"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO="${VERSION_CODENAME:-resolute}"
fi
ARCH="$(dpkg --print-architecture)"
# The Debian package "Architecture:" field (e.g. "amd64") is NOT the same
# as the multiarch library directory name (e.g. "x86_64-linux-gnu") that
# pkg-config/ld actually search by default -- conflating the two means
# libraries/.pc files get installed somewhere nothing looks for them.
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"

# Installs the given .deb files via dpkg (falling back to "apt-get -f" to
# pull in any missing dependencies), then refreshes the linker cache.
#
# INSTALL_AFTER_BUILD only controls whether we install at the very end for
# the User's benefit; the intermediate packages (woff2, libwpe,
# WPEBackend-fdo) must always be installed as soon as they're built --
# otherwise later phases can't find them: WPEBackend-fdo's meson build and
# WPEWebKit's cmake configure both look up these dependencies via
# pkg-config/find_package against whatever is actually registered with
# dpkg, not just files that happen to exist on disk.
install_debs() {
  sudo dpkg -i "$@" || sudo apt-get install -f -y
  sudo ldconfig
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/build/wpewebkit"
PKG_DIR="${WORK_DIR}/pkg"

echo "[*] Target distro: ${DISTRO} (${ARCH}, ${MULTIARCH})"
echo "[*] WPEWebKit ${WPEWEBKIT_VERSION}, libwpe ${LIBWPE_VERSION}, WPEBackend-fdo ${WPEBACKEND_FDO_VERSION}"
echo "[*] Work directory: ${WORK_DIR}"

mkdir -p "${WORK_DIR}" "${PKG_DIR}"
cd "${WORK_DIR}"

echo "[*] Installing build dependencies (sudo apt-get)..."
sudo apt-get update -y
sudo apt-get install -y \
  curl cmake meson ninja-build pkg-config python3 ruby perl \
  bison flex gperf unifdef gettext \
  libglib2.0-dev libgcrypt20-dev \
  libsoup-3.0-dev libxml2-dev libxslt1-dev \
  libcairo2-dev libfontconfig1-dev libfreetype-dev \
  libharfbuzz-dev libicu-dev libpango1.0-dev \
  libsqlite3-dev libwebp-dev libjpeg-dev libpng-dev libopenjp2-7-dev \
  libbrotli-dev libopus-dev libavif-dev libjxl-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libgstreamer-plugins-bad1.0-dev \
  libepoxy-dev libgbm-dev \
  libegl-dev libwayland-dev wayland-protocols libxkbcommon-dev \
  libunwind-dev libseccomp-dev \
  libenchant-2-dev libhyphen-dev liblcms2-dev \
  libtasn1-6-dev \
  libmanette-0.2-dev \
  dpkg-dev

# ---------------------------------------------------------------------------
# woff2
# ---------------------------------------------------------------------------
build_woff2() {
  local ver="1.0.2"
  echo "[*] Building woff2 ${ver}..."
  if [[ ! -d woff2-src ]]; then
    curl -fL "https://github.com/google/woff2/archive/refs/tags/v${ver}.tar.gz" -o woff2.tar.gz
    mkdir woff2-src
    tar xf woff2.tar.gz --strip-components=1 -C woff2-src
  fi

  # woff2 1.0.2's output.h uses uint8_t without including <cstdint>. Older
  # compilers pulled it in transitively via other standard headers, but
  # GCC 13+ (e.g. Ubuntu 26.04) does not, causing
  # "error: expected ')' before '*' token" / "'uint8_t' does not name a type"
  # when compiling src/woff2_out.cc. Guarded so it's a no-op if already fixed
  # upstream.
  if ! grep -q '#include <cstdint>' woff2-src/include/woff2/output.h; then
    sed -i '/#include <string>/a #include <cstdint>' woff2-src/include/woff2/output.h
  fi

  cmake -S woff2-src -B woff2-build \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR="lib/${MULTIARCH}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  ninja -C woff2-build
  DESTDIR="${WORK_DIR}/staging-woff2" ninja -C woff2-build install

  echo "[*] Packaging woff2 ${ver}..."
  local pkgver="${ver}-1~${DISTRO}1"

  local pkg="libwoff2-1"
  local dir="${PKG_DIR}/${pkg}_${pkgver}_${ARCH}"
  mkdir -p "${dir}/DEBIAN" "${dir}/usr/lib/${MULTIARCH}"
  cp -a "staging-woff2/usr/lib/${MULTIARCH}/"libwoff2*.so.* \
    "${dir}/usr/lib/${MULTIARCH}/" 2>/dev/null || true
  cat > "${dir}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${pkgver}
Architecture: ${ARCH}
Section: libs
Priority: optional
Maintainer: Wimsy
Depends: libbrotli1
Description: WebFont compression library (runtime)
 WOFF2 is a font compression format for the web.
EOF
  dpkg-deb --build --root-owner-group "${dir}" "${PKG_DIR}/${pkg}_${pkgver}_${ARCH}.deb"

  pkg="libwoff2-dev"
  dir="${PKG_DIR}/${pkg}_${pkgver}_${ARCH}"
  mkdir -p "${dir}/DEBIAN" "${dir}/usr/lib/${MULTIARCH}" "${dir}/usr/include"
  [[ -d staging-woff2/usr/include/woff2 ]] && cp -a staging-woff2/usr/include/woff2 "${dir}/usr/include/"
  find "staging-woff2/usr/lib/${MULTIARCH}" -maxdepth 1 -name "libwoff2*.so" \
    | xargs -r -I{} cp -a {} "${dir}/usr/lib/${MULTIARCH}/"
  cat > "${dir}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${pkgver}
Architecture: ${ARCH}
Section: libdevel
Priority: optional
Maintainer: Wimsy
Depends: libwoff2-1 (= ${pkgver})
Description: WebFont compression library (development)
 Development headers for libwoff2.
EOF
  dpkg-deb --build --root-owner-group "${dir}" "${PKG_DIR}/${pkg}_${pkgver}_${ARCH}.deb"

  # Install now so WPEBackend-fdo and WPEWebKit can find libwoff2 below.
  echo "[*] Installing woff2 ${ver} packages..."
  install_debs "${PKG_DIR}/libwoff2-1_${pkgver}_${ARCH}.deb" "${PKG_DIR}/libwoff2-dev_${pkgver}_${ARCH}.deb"
}

# ---------------------------------------------------------------------------
# libwpe
# ---------------------------------------------------------------------------
build_libwpe() {
  echo "[*] Building libwpe ${LIBWPE_VERSION}..."
  if [[ ! -d libwpe-src ]]; then
    curl -fL "https://github.com/WebPlatformForEmbedded/libwpe/archive/refs/tags/${LIBWPE_VERSION}.tar.gz" -o libwpe.tar.gz
    mkdir libwpe-src
    tar xf libwpe.tar.gz --strip-components=1 -C libwpe-src
  fi
  cmake -S libwpe-src -B libwpe-build \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR="lib/${MULTIARCH}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  ninja -C libwpe-build
  DESTDIR="${WORK_DIR}/staging-libwpe" ninja -C libwpe-build install

  echo "[*] Packaging libwpe ${LIBWPE_VERSION}..."
  local pkgver="${LIBWPE_VERSION}-1~${DISTRO}1"

  local pkg="libwpe-1.0-1"
  local dir="${PKG_DIR}/${pkg}_${pkgver}_${ARCH}"
  mkdir -p "${dir}/DEBIAN" "${dir}/usr/lib/${MULTIARCH}"
  cp -a "staging-libwpe/usr/lib/${MULTIARCH}/libwpe-1.0.so."* \
    "${dir}/usr/lib/${MULTIARCH}/" 2>/dev/null || true
  cat > "${dir}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${pkgver}
Architecture: ${ARCH}
Section: libs
Priority: optional
Maintainer: Wimsy
Description: WPE platform library (runtime)
 libwpe is a general-purpose library for the WPE WebKit port.
EOF
  dpkg-deb --build --root-owner-group "${dir}" "${PKG_DIR}/${pkg}_${pkgver}_${ARCH}.deb"

  pkg="libwpe-1.0-dev"
  dir="${PKG_DIR}/${pkg}_${pkgver}_${ARCH}"
  mkdir -p "${dir}/DEBIAN" "${dir}/usr/lib/${MULTIARCH}/pkgconfig" "${dir}/usr/include"
  [[ -d staging-libwpe/usr/include/wpe-1.0 ]] && cp -a staging-libwpe/usr/include/wpe-1.0 "${dir}/usr/include/"
  cp -a "staging-libwpe/usr/lib/${MULTIARCH}/libwpe-1.0.so" \
    "${dir}/usr/lib/${MULTIARCH}/" 2>/dev/null || true
  find staging-libwpe -name "wpe-1.0.pc" 2>/dev/null | head -1 \
    | xargs -r -I{} cp {} "${dir}/usr/lib/${MULTIARCH}/pkgconfig/"
  cat > "${dir}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${pkgver}
Architecture: ${ARCH}
Section: libdevel
Priority: optional
Maintainer: Wimsy
Depends: libwpe-1.0-1 (= ${pkgver})
Description: WPE platform library (development)
 Development headers and pkg-config for libwpe-1.0.
EOF
  dpkg-deb --build --root-owner-group "${dir}" "${PKG_DIR}/${pkg}_${pkgver}_${ARCH}.deb"

  # Install now so WPEBackend-fdo and WPEWebKit can find libwpe below.
  echo "[*] Installing libwpe ${LIBWPE_VERSION} packages..."
  install_debs "${PKG_DIR}/libwpe-1.0-1_${pkgver}_${ARCH}.deb" "${PKG_DIR}/libwpe-1.0-dev_${pkgver}_${ARCH}.deb"
}

# ---------------------------------------------------------------------------
# WPEBackend-fdo
# ---------------------------------------------------------------------------
build_wpebackend_fdo() {
  echo "[*] Building WPEBackend-fdo ${WPEBACKEND_FDO_VERSION}..."
  if [[ ! -d wpebackend-fdo-src ]]; then
    curl -fL "https://github.com/Igalia/WPEBackend-fdo/archive/refs/tags/${WPEBACKEND_FDO_VERSION}.tar.gz" -o wpebackend-fdo.tar.gz
    mkdir wpebackend-fdo-src
    tar xf wpebackend-fdo.tar.gz --strip-components=1 -C wpebackend-fdo-src
  fi
  meson setup wpebackend-fdo-build wpebackend-fdo-src \
    --prefix=/usr \
    --libdir="lib/${MULTIARCH}" \
    -Dbuildtype=release \
    --wipe 2>/dev/null || \
  meson setup wpebackend-fdo-build wpebackend-fdo-src \
    --prefix=/usr \
    --libdir="lib/${MULTIARCH}" \
    -Dbuildtype=release
  ninja -C wpebackend-fdo-build
  DESTDIR="${WORK_DIR}/staging-wpebackend-fdo" ninja -C wpebackend-fdo-build install

  echo "[*] Packaging WPEBackend-fdo ${WPEBACKEND_FDO_VERSION}..."
  local pkgver="${WPEBACKEND_FDO_VERSION}-1~${DISTRO}1"

  local pkg="libwpebackend-fdo-1.0-1"
  local dir="${PKG_DIR}/${pkg}_${pkgver}_${ARCH}"
  mkdir -p "${dir}/DEBIAN" "${dir}/usr/lib/${MULTIARCH}"
  cp -a "staging-wpebackend-fdo/usr/lib/${MULTIARCH}/libWPEBackend-fdo-1.0.so."* \
    "${dir}/usr/lib/${MULTIARCH}/" 2>/dev/null || true
  cat > "${dir}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${pkgver}
Architecture: ${ARCH}
Section: libs
Priority: optional
Maintainer: Wimsy
Depends: libwpe-1.0-1
Description: WPE FDO backend (runtime)
 FDO backend for the WPE WebKit web content engine.
EOF
  dpkg-deb --build --root-owner-group "${dir}" "${PKG_DIR}/${pkg}_${pkgver}_${ARCH}.deb"

  pkg="libwpebackend-fdo-1.0-dev"
  dir="${PKG_DIR}/${pkg}_${pkgver}_${ARCH}"
  mkdir -p "${dir}/DEBIAN" "${dir}/usr/lib/${MULTIARCH}/pkgconfig" "${dir}/usr/include"
  [[ -d staging-wpebackend-fdo/usr/include/wpe-fdo-1.0 ]] && \
    cp -a staging-wpebackend-fdo/usr/include/wpe-fdo-1.0 "${dir}/usr/include/"
  cp -a "staging-wpebackend-fdo/usr/lib/${MULTIARCH}/libWPEBackend-fdo-1.0.so" \
    "${dir}/usr/lib/${MULTIARCH}/" 2>/dev/null || true
  find staging-wpebackend-fdo -name "wpebackend-fdo-1.0.pc" 2>/dev/null | head -1 \
    | xargs -r -I{} cp {} "${dir}/usr/lib/${MULTIARCH}/pkgconfig/"
  cat > "${dir}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${pkgver}
Architecture: ${ARCH}
Section: libdevel
Priority: optional
Maintainer: Wimsy
Depends: libwpebackend-fdo-1.0-1 (= ${pkgver})
Description: WPE FDO backend (development)
 Development headers and pkg-config for libwpebackend-fdo-1.0.
EOF
  dpkg-deb --build --root-owner-group "${dir}" "${PKG_DIR}/${pkg}_${pkgver}_${ARCH}.deb"

  # Install now so WPEWebKit can find WPEBackend-fdo below.
  echo "[*] Installing WPEBackend-fdo ${WPEBACKEND_FDO_VERSION} packages..."
  install_debs "${PKG_DIR}/libwpebackend-fdo-1.0-1_${pkgver}_${ARCH}.deb" "${PKG_DIR}/libwpebackend-fdo-1.0-dev_${pkgver}_${ARCH}.deb"
}

# ---------------------------------------------------------------------------
# WPEWebKit
# ---------------------------------------------------------------------------
download_wpewebkit_source() {
  [[ -d wpewebkit-src ]] && return 0
  echo "[*] Downloading WPEWebKit ${WPEWEBKIT_VERSION} source..."
  # wpewebkit.org only hosts recent releases; fall back to webkitgtk.org,
  # which mirrors the same source tree (cmake -DPORT=WPE builds WPE from
  # either tarball).
  curl -fL "https://wpewebkit.org/releases/wpewebkit-${WPEWEBKIT_VERSION}.tar.xz" -o wpewebkit.tar.xz 2>/dev/null || \
  curl -fL "https://webkitgtk.org/releases/webkitgtk-${WPEWEBKIT_VERSION}.tar.xz" -o wpewebkit.tar.xz
  tar xf wpewebkit.tar.xz
  if [[ -d "wpewebkit-${WPEWEBKIT_VERSION}" ]]; then
    mv "wpewebkit-${WPEWEBKIT_VERSION}" wpewebkit-src
  elif [[ -d "webkitgtk-${WPEWEBKIT_VERSION}" ]]; then
    mv "webkitgtk-${WPEWEBKIT_VERSION}" wpewebkit-src
  else
    echo "ERROR: could not find extracted WPEWebKit source directory" >&2
    exit 1
  fi
}

# Older WPEWebKit releases don't build cleanly against very new toolchains.
# These patches are idempotent/guarded (no-op if the pattern isn't present,
# e.g. because a newer release already fixed it upstream) so it's safe to
# always run this step.
patch_wpewebkit_source() {
  echo "[*] Applying toolchain-compatibility patches (guarded, may be no-ops)..."

  # Ruby 3.2 removed the long-deprecated File.exists? in favour of File.exist?.
  find wpewebkit-src/Source/JavaScriptCore/offlineasm -name "*.rb" \
    -exec sed -i 's/File\.exists?/File.exist?/g' {} +

  # GCC 13+ requires an explicit <cstdint> for uint64_t/uint32_t; older
  # compilers pulled it in transitively via other system headers.
  local shader_vars="wpewebkit-src/Source/ThirdParty/ANGLE/include/GLSLANG/ShaderVars.h"
  if [[ -f "${shader_vars}" ]] && ! grep -q '#include <cstdint>' "${shader_vars}"; then
    sed -i '/#include <vector>/a #include <cstdint>' "${shader_vars}"
  fi

  # GCC 13+ refuses the implicit enum->uint8_t conversion that older
  # compilers accepted for SerializableErrorType. Use Python to avoid
  # shell-escaping issues with < > in static_cast.
  python3 - <<'PYEOF'
path = 'wpewebkit-src/Source/WebCore/bindings/js/SerializedScriptValue.cpp'
old = 'write(errorNameToSerializableErrorType(errorTypeString));'
new = 'write(static_cast<uint8_t>(errorNameToSerializableErrorType(errorTypeString)));'
with open(path) as f:
    content = f.read()
if old not in content:
    print(f'  (skipped: pattern not found in {path})')
else:
    with open(path, 'w') as f:
        f.write(content.replace(old, new))
    print(f'  patched {path}')
PYEOF
}

build_wpewebkit() {
  download_wpewebkit_source
  patch_wpewebkit_source

  echo "[*] Configuring WPEWebKit ${WPEWEBKIT_VERSION}..."
  cmake -S wpewebkit-src -B build \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR="lib/${MULTIARCH}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DPORT=WPE \
    -DENABLE_INTROSPECTION=OFF \
    -DENABLE_DOCUMENTATION=OFF \
    -DENABLE_MINIBROWSER=OFF \
    -DENABLE_API_TESTS=OFF \
    -DENABLE_LAYOUT_TESTS=OFF \
    -DUSE_SOUP2=OFF \
    -DENABLE_GAMEPAD=OFF \
    -DENABLE_SPEECH_SYNTHESIS=OFF \
    -DENABLE_WEB_CRYPTO=OFF \
    -DENABLE_ACCESSIBILITY=OFF \
    -DUSE_ATK=OFF \
    -DUSE_LIBBACKTRACE=OFF \
    -DENABLE_JOURNALD_LOG=OFF \
    -DENABLE_BUBBLEWRAP_SANDBOX=OFF

  echo "[*] Building WPEWebKit ${WPEWEBKIT_VERSION} (this takes ~60-90 minutes)..."
  ninja -C build -j"$(nproc)"

  echo "[*] Installing WPEWebKit to staging directory..."
  DESTDIR="${WORK_DIR}/staging" ninja -C build install

  echo "[*] Packaging libwpewebkit-1.0-3 (runtime)..."
  local pkgver="${WPEWEBKIT_VERSION}-1~${DISTRO}1"
  local pkg="libwpewebkit-1.0-3"
  local dir="${PKG_DIR}/${pkg}_${pkgver}_${ARCH}"
  mkdir -p "${dir}/DEBIAN" "${dir}/usr/lib/${MULTIARCH}"

  # Copy versioned shared libraries only: the unversioned
  # libWPEWebKit-2.0.so symlink belongs in the -dev package below; the
  # .so.* glob ensures we only pick up .so.1 and .so.1.x.y here.
  cp -a "staging/usr/lib/${MULTIARCH}/libWPEWebKit-2.0.so."* \
    "${dir}/usr/lib/${MULTIARCH}/" 2>/dev/null || true
  for share_dir in wpe wpewebkit; do
    if [[ -d "staging/usr/share/${share_dir}" ]]; then
      mkdir -p "${dir}/usr/share"
      cp -a "staging/usr/share/${share_dir}" "${dir}/usr/share/"
    fi
  done
  if [[ -d "staging/usr/lib/${MULTIARCH}/gstreamer-1.0" ]]; then
    mkdir -p "${dir}/usr/lib/${MULTIARCH}"
    cp -a "staging/usr/lib/${MULTIARCH}/gstreamer-1.0" "${dir}/usr/lib/${MULTIARCH}/"
  fi
  # Injected bundle, inspector resources, etc. (wpe-webkit-*/ subdir).
  for d in "staging/usr/lib/${MULTIARCH}/"wpe-webkit-*/; do
    [[ -d "$d" ]] && cp -a "$d" "${dir}/usr/lib/${MULTIARCH}/" || true
  done
  if [[ -d staging/usr/libexec ]]; then
    mkdir -p "${dir}/usr"
    cp -a staging/usr/libexec "${dir}/usr/"
  fi

  cat > "${dir}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${pkgver}
Architecture: ${ARCH}
Section: libs
Priority: optional
Maintainer: Wimsy
Depends: libwpe-1.0-1, libwpebackend-fdo-1.0-1, libwoff2-1
Description: WPE WebKit web content engine for embedded devices (runtime)
 WPEWebKit is the WebKit port for WPE (Web Platform for Embedded). This
 package contains the runtime shared libraries.
EOF
  dpkg-deb --build --root-owner-group "${dir}" "${PKG_DIR}/${pkg}_${pkgver}_${ARCH}.deb"

  echo "[*] Packaging libwpewebkit-1.0-dev (development)..."
  pkg="libwpewebkit-1.0-dev"
  dir="${PKG_DIR}/${pkg}_${pkgver}_${ARCH}"
  mkdir -p "${dir}/DEBIAN" "${dir}/usr/lib/${MULTIARCH}" "${dir}/usr/include" \
    "${dir}/usr/lib/${MULTIARCH}/pkgconfig"

  # Headers install under wpe-webkit-2.0/ as of WPEWebKit 2.42+.
  [[ -d staging/usr/include/wpe-webkit-2.0 ]] && \
    cp -a staging/usr/include/wpe-webkit-2.0 "${dir}/usr/include/"

  # Unversioned .so symlink, needed for linking at compile time.
  cp -a "staging/usr/lib/${MULTIARCH}/libWPEWebKit-2.0.so" \
    "${dir}/usr/lib/${MULTIARCH}/" 2>/dev/null || \
    echo "WARNING: libWPEWebKit-2.0.so not found in staging"

  # Use the real wpe-webkit-2.0.pc produced by the build so the Requires:
  # (libsoup-3.0, glib-2.0, etc.) stay in sync with what was actually built.
  find staging -name "wpe-webkit-2.0.pc" 2>/dev/null | head -1 \
    | xargs -r -I{} cp {} "${dir}/usr/lib/${MULTIARCH}/pkgconfig/"

  cat > "${dir}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${pkgver}
Architecture: ${ARCH}
Section: libdevel
Priority: optional
Maintainer: Wimsy
Depends: libwpewebkit-1.0-3 (= ${pkgver})
Description: WPEWebKit web content engine for embedded devices (development)
 Development headers and pkg-config file for libwpewebkit-1.0.
EOF
  dpkg-deb --build --root-owner-group "${dir}" "${PKG_DIR}/${pkg}_${pkgver}_${ARCH}.deb"

  echo "[*] Verifying libwpewebkit-1.0-dev package contents..."
  dpkg-deb --contents "${PKG_DIR}/${pkg}_${pkgver}_${ARCH}.deb" | grep -q "wpe-webkit-2.0.pc" \
    && echo "  OK: wpe-webkit-2.0.pc present" \
    || { echo "ERROR: wpe-webkit-2.0.pc missing from package!" >&2; exit 1; }
  # Symlinks show as "libWPEWebKit-2.0.so -> target" in dpkg-deb output, so
  # match the name followed by a non-dot character (a space before "->")
  # rather than anchoring on end-of-line, which would match the target.
  dpkg-deb --contents "${PKG_DIR}/${pkg}_${pkgver}_${ARCH}.deb" | grep -q "libWPEWebKit-2\.0\.so[^.]" \
    && echo "  OK: libWPEWebKit-2.0.so present" \
    || { echo "ERROR: libWPEWebKit-2.0.so symlink missing from package!" >&2; exit 1; }
}

build_woff2
build_libwpe
build_wpebackend_fdo
build_wpewebkit

echo
echo "[*] Done. Built packages:"
ls -1 "${PKG_DIR}"/*.deb

if [[ "${INSTALL_AFTER_BUILD}" -eq 1 ]]; then
  # woff2, libwpe and WPEBackend-fdo are already installed (install_debs was
  # called as each was built, so that later phases could find them). Only
  # the final WPEWebKit packages are still pending here.
  echo "[*] Installing WPEWebKit packages (sudo dpkg -i)..."
  install_debs "${PKG_DIR}"/libwpewebkit-1.0-3_*_"${ARCH}.deb" "${PKG_DIR}"/libwpewebkit-1.0-dev_*_"${ARCH}.deb"
else
  echo
  echo "woff2, libwpe and WPEBackend-fdo are already installed (needed to build WPEWebKit)."
  echo "To install WPEWebKit too: sudo dpkg -i ${PKG_DIR}/libwpewebkit-1.0-{3,dev}_*_${ARCH}.deb"
  echo "(or re-run this script with --install)"
fi
