#!/usr/bin/env bash
#
# build_bcm.sh - Cross build fakesip with a BCM-HND toolchain
#                (same kind of compiler as used by webd's build.yml,
#                e.g. https://github.com/SWRT-dev/bcmhnd-toolchains).
#
# This script only performs the *build*. It does NOT download or install
# any compiler/toolchain -- that is expected to be done beforehand (e.g.
# in a CI workflow .yml, see .github/workflows/build-bcm.yml).
#
# Unlike build_asus.sh, this script:
#   - does NOT statically link the whole binary (no `-static`), so libc
#     and other system libraries stay dynamically linked and the binary
#     stays small;
#   - DOES statically link libnetfilter_queue/libnfnetlink/libmnl, so the
#     three dependency libraries don't need to be installed on the router
#     at runtime;
#   - does NOT run upx compression on the resulting binary.
#
# Configuration is done entirely through environment variables / CLI
# flags, in particular the compiler location (CROSS_PREFIX).
#
# Usage:
#   CROSS_PREFIX=/opt/toolchains/arm-linux/bin/arm-linux- \
#   ARCH_NAME=arm-linux \
#     ./build_bcm.sh
#
# or with flags:
#   ./build_bcm.sh --cross-prefix /opt/toolchains/arm-linux/bin/arm-linux- \
#                   --arch-name arm-linux \
#                   --out-dir out
#
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

ROOT="$(cd "$(dirname "$0")" && pwd)"

# ---- configurable options (env vars, overridable by CLI flags below) ----

# Full path prefix of the cross compiler, e.g.
#   /opt/toolchains/crosstools-arm-gcc-9.2-.../bin/arm-linux-
# such that "${CROSS_PREFIX}gcc" is the compiler executable.
# Leave empty to build with the host's native compiler.
CROSS_PREFIX="${CROSS_PREFIX:-}"

# Human readable architecture/target name, used to build dependency
# directories and the final output file name (fakesip-${ARCH_NAME}).
ARCH_NAME="${ARCH_NAME:-native}"

# Directory to place the final binary in.
OUT_DIR="${OUT_DIR:-${ROOT}/out}"

# Optional: also install the built binary into this directory
# (e.g. a softcenter/asuswrt plugin bin/ folder), named "fakesip".
INSTALL_DIR="${INSTALL_DIR:-}"

# Version string embedded into the binary via -DVERSION.
VERSION="${VERSION:-}"

JOBS="${JOBS:-4}"

DEPS_DIR="${DEPS_DIR:-${ROOT}/deps}"
TAR_DIR="${DEPS_DIR}/tar"
SRC_DIR="${DEPS_DIR}/src"
BUILD_DIR="${DEPS_DIR}/build"

LIBMNL_VER="${LIBMNL_VER:-1.0.5}"
LIBNFNETLINK_VER="${LIBNFNETLINK_VER:-1.0.2}"
LIBNFQ_VER="${LIBNFQ_VER:-1.0.5}"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --cross-prefix PREFIX   Cross compiler prefix, e.g. /opt/toolchains/.../bin/arm-linux-
                           ("\${PREFIX}gcc" must be the compiler executable).
                           (env: CROSS_PREFIX)
  --arch-name NAME        Name used for output file suffix / dep dirs (default: native)
                           (env: ARCH_NAME)
  --host TRIPLET           Autoconf --host triplet for building the dependency
                           libraries. Defaults to the cross-prefix basename
                           with the trailing "-" removed. (env: HOST_TRIPLET)
  --out-dir DIR            Output directory for the built binary (env: OUT_DIR)
  --install-dir DIR        Also install the binary as "fakesip" into DIR (env: INSTALL_DIR)
  --version VERSION        Version string embedded into the binary (env: VERSION)
  --jobs N                 Parallel build jobs, 1-4 (default: 4) (env: JOBS)
  -h, --help               Show this help
EOF
}

HOST_TRIPLET="${HOST_TRIPLET:-}"

while [ $# -gt 0 ]; do
	case "$1" in
		--cross-prefix) CROSS_PREFIX="$2"; shift 2 ;;
		--cross-prefix=*) CROSS_PREFIX="${1#*=}"; shift ;;
		--arch-name) ARCH_NAME="$2"; shift 2 ;;
		--arch-name=*) ARCH_NAME="${1#*=}"; shift ;;
		--host) HOST_TRIPLET="$2"; shift 2 ;;
		--host=*) HOST_TRIPLET="${1#*=}"; shift ;;
		--out-dir) OUT_DIR="$2"; shift 2 ;;
		--out-dir=*) OUT_DIR="${1#*=}"; shift ;;
		--install-dir) INSTALL_DIR="$2"; shift 2 ;;
		--install-dir=*) INSTALL_DIR="${1#*=}"; shift ;;
		--version) VERSION="$2"; shift 2 ;;
		--version=*) VERSION="${1#*=}"; shift ;;
		--jobs) JOBS="$2"; shift 2 ;;
		--jobs=*) JOBS="${1#*=}"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
	esac
done

if [[ "${JOBS}" =~ ^[0-9]+$ ]]; then
	if [ "${JOBS}" -lt 1 ]; then JOBS=1; fi
	if [ "${JOBS}" -gt 4 ]; then JOBS=4; fi
else
	JOBS=4
fi

if [ -z "${HOST_TRIPLET}" ]; then
	if [ -n "${CROSS_PREFIX}" ]; then
		# e.g. /opt/toolchains/.../bin/arm-linux- -> arm-linux
		HOST_TRIPLET="$(basename "${CROSS_PREFIX}")"
		HOST_TRIPLET="${HOST_TRIPLET%-}"
	fi
fi

download() {
	local url="$1"
	local out="$2"
	if [ -f "${out}" ]; then
		return 0
	fi
	mkdir -p "$(dirname "${out}")"
	echo "download: ${url}"
	curl -fsSL --retry 3 --retry-delay 1 -o "${out}" "${url}"
}

extract() {
	local tarball="$1"
	local dst="$2"
	mkdir -p "${dst}"
	local marker="${dst}/.extracted"
	if [ -f "${marker}" ]; then
		return 0
	fi
	rm -rf "${dst:?}/"*
	case "${tarball}" in
		*.tar.bz2) tar -xjf "${tarball}" -C "${dst}" --strip-components=1 ;;
		*.tar.gz)  tar -xzf "${tarball}" -C "${dst}" --strip-components=1 ;;
		*) echo "unknown tarball: ${tarball}" ; exit 1 ;;
	esac
	touch "${marker}"
}

build_one_dep() {
	local name="$1"
	local src="$2"
	local build="$3"
	local host="$4"
	local prefix="$5"
	shift 5
	# remaining args: extra configure args (e.g. explicit *_CFLAGS/*_LIBS
	# to avoid depending on a working pkg-config in the toolchain)
	local extra_configure_args=("$@")

	mkdir -p "$(dirname "${build}")"
	rm -rf "${build}"
	cp -a "${src}" "${build}"

	echo "-- building dependency: ${name} (${host:-native}) --" >&2

	pushd "${build}" >/dev/null
	local configure_args=(
		--prefix="${prefix}"
		--disable-shared
		--enable-static
	)
	if [ -n "${host}" ]; then
		configure_args+=(--host="${host}")
	fi
	configure_args+=("${extra_configure_args[@]}")
	./configure "${configure_args[@]}" >/dev/null
	make -j"${JOBS}" >/dev/null
	make install >/dev/null
	popd >/dev/null
}

build_deps() {
	local arch="$1"
	local host="$2"
	local prefix="$3"

	mkdir -p "${prefix}"

	echo "== deps: ${arch} (${host:-native}) ==" >&2

	build_one_dep "libmnl" \
		"${SRC_DIR}/libmnl" \
		"${BUILD_DIR}/${arch}/libmnl" \
		"${host}" "${prefix}"

	build_one_dep "libnfnetlink" \
		"${SRC_DIR}/libnfnetlink" \
		"${BUILD_DIR}/${arch}/libnfnetlink" \
		"${host}" "${prefix}" \
		"LIBMNL_CFLAGS=-I${prefix}/include" \
		"LIBMNL_LIBS=-L${prefix}/lib -lmnl"

	# libnetfilter_queue's configure script uses pkg-config to locate
	# libmnl/libnfnetlink. Some cross toolchains ship a broken/incomplete
	# pkg-config (e.g. missing libpkgconf.so), so pass the *_CFLAGS/*_LIBS
	# explicitly to skip the pkg-config lookup entirely.
	build_one_dep "libnetfilter_queue" \
		"${SRC_DIR}/libnetfilter_queue" \
		"${BUILD_DIR}/${arch}/libnetfilter_queue" \
		"${host}" "${prefix}" \
		"LIBMNL_CFLAGS=-I${prefix}/include" \
		"LIBMNL_LIBS=-L${prefix}/lib -lmnl" \
		"LIBNFNETLINK_CFLAGS=-I${prefix}/include" \
		"LIBNFNETLINK_LIBS=-L${prefix}/lib -lnfnetlink"
}

build_fakesip() {
	local arch="$1"
	local cross_prefix="$2"
	local deps_prefix="$3"

	echo "== fakesip: ${arch} (${cross_prefix:-native}) ==" >&2

	make -C "${ROOT}" clean >/dev/null 2>&1 || true

	local make_version
	make_version="${VERSION:-$(git -C "${ROOT}" describe --tags --always 2>/dev/null || echo todo)}"

	# STATIC_LIBNFQ=1: statically link libnetfilter_queue / libnfnetlink /
	# libmnl only, so no runtime install of these libraries is required on
	# the router, while libc & other system libraries stay dynamically
	# linked (smaller binary, no full static build).
	make -C "${ROOT}" -j"${JOBS}" \
		STATIC_LIBNFQ=1 \
		CROSS_PREFIX="${cross_prefix}" \
		VERSION="${make_version}" \
		CFLAGS="-I${deps_prefix}/include" \
		LDFLAGS="-L${deps_prefix}/lib" >/dev/null

	local out="${OUT_DIR}/fakesip-${arch}"
	mkdir -p "${OUT_DIR}"
	cp -f "${ROOT}/build/fakesip" "${out}"

	echo "${out}"
}

main() {
	mkdir -p "${TAR_DIR}" "${SRC_DIR}" "${BUILD_DIR}"

	download "https://www.netfilter.org/pub/libmnl/libmnl-${LIBMNL_VER}.tar.bz2" "${TAR_DIR}/libmnl.tar.bz2"
	download "https://www.netfilter.org/pub/libnfnetlink/libnfnetlink-${LIBNFNETLINK_VER}.tar.bz2" "${TAR_DIR}/libnfnetlink.tar.bz2"
	download "https://www.netfilter.org/pub/libnetfilter_queue/libnetfilter_queue-${LIBNFQ_VER}.tar.bz2" "${TAR_DIR}/libnetfilter_queue.tar.bz2"

	extract "${TAR_DIR}/libmnl.tar.bz2" "${SRC_DIR}/libmnl"
	extract "${TAR_DIR}/libnfnetlink.tar.bz2" "${SRC_DIR}/libnfnetlink"
	extract "${TAR_DIR}/libnetfilter_queue.tar.bz2" "${SRC_DIR}/libnetfilter_queue"

	if [ -n "${CROSS_PREFIX}" ]; then
		local cross_bin_dir
		cross_bin_dir="$(dirname "${CROSS_PREFIX}")"
		if [ ! -x "${CROSS_PREFIX}gcc" ]; then
			echo "cross compiler not found or not executable: ${CROSS_PREFIX}gcc" >&2
			echo "(toolchain installation must be done before running this script, e.g. in the CI workflow)" >&2
			exit 1
		fi
		export PATH="${cross_bin_dir}:${PATH}"
		export CC="${CROSS_PREFIX}gcc"
		export CXX="${CROSS_PREFIX}g++"
		export AR="${CROSS_PREFIX}ar"
		export RANLIB="${CROSS_PREFIX}ranlib"
		export STRIP="${CROSS_PREFIX}strip"
	fi

	local deps_prefix="${BUILD_DIR}/out/${ARCH_NAME}"
	export PKG_CONFIG_PATH="${deps_prefix}/lib/pkgconfig"
	export PKG_CONFIG_LIBDIR="${deps_prefix}/lib/pkgconfig"

	build_deps "${ARCH_NAME}" "${HOST_TRIPLET}" "${deps_prefix}"

	local out
	out="$(build_fakesip "${ARCH_NAME}" "${CROSS_PREFIX}" "${deps_prefix}")"

	echo "built:"
	file "${out}"

	if [ -n "${INSTALL_DIR}" ]; then
		mkdir -p "${INSTALL_DIR}"
		install -m 0755 "${out}" "${INSTALL_DIR}/fakesip"
		echo "installed:"
		file "${INSTALL_DIR}/fakesip"
	fi
}

main
