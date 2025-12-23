#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

ROOT="$(cd "$(dirname "$0")" && pwd)"
UPX_BIN="/home/sadog/project/upx/upx-5.0.2"
PLUGIN_BIN_DIR="${ROOT}/../fakesip/bin"

JOBS="${JOBS:-4}"
if [[ "${JOBS}" =~ ^[0-9]+$ ]]; then
	if [ "${JOBS}" -lt 1 ]; then JOBS=1; fi
	if [ "${JOBS}" -gt 4 ]; then JOBS=4; fi
else
	JOBS=4
fi

DEPS_DIR="${ROOT}/deps"
TAR_DIR="${DEPS_DIR}/tar"
SRC_DIR="${DEPS_DIR}/src"
BUILD_DIR="${DEPS_DIR}/build"
OUT_DIR="${ROOT}/out"

LIBMNL_VER="1.0.5"
LIBNFNETLINK_VER="1.0.2"
LIBNFQ_VER="1.0.5"

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
		*.tar.gz) tar -xzf "${tarball}" -C "${dst}" --strip-components=1 ;;
		*) echo "unknown tarball: ${tarball}" ; exit 1 ;;
	esac
	touch "${marker}"
}

build_one_dep() {
	local src="$1"
	local build="$2"
	local host="$3"
	local prefix="$4"

	mkdir -p "$(dirname "${build}")"
	rm -rf "${build}"
	cp -a "${src}" "${build}"

	pushd "${build}" >/dev/null
	./configure \
		--host="${host}" \
		--prefix="${prefix}" \
		--disable-shared \
		--enable-static >/dev/null
	make -j"${JOBS}" >/dev/null
	make install >/dev/null
	popd >/dev/null
}

build_deps() {
	local arch="$1"
	local toolchain_root="$2"
	local host="$3"

	local prefix="${BUILD_DIR}/out/${arch}"
	mkdir -p "${prefix}"

	export PATH="${toolchain_root}/bin:${PATH}"
	export CC="${host}-gcc"
	export CXX="${host}-g++"
	export AR="${host}-ar"
	export RANLIB="${host}-ranlib"
	export STRIP="${host}-strip"
	export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig"
	export PKG_CONFIG_LIBDIR="${prefix}/lib/pkgconfig"

	echo "== deps: ${arch} (${host}) ==" >&2
	build_one_dep "${SRC_DIR}/libmnl" "${BUILD_DIR}/${arch}/libmnl" "${host}" "${prefix}"
	build_one_dep "${SRC_DIR}/libnfnetlink" "${BUILD_DIR}/${arch}/libnfnetlink" "${host}" "${prefix}"
	build_one_dep "${SRC_DIR}/libnetfilter_queue" "${BUILD_DIR}/${arch}/libnetfilter_queue" "${host}" "${prefix}"
}

build_fakesip() {
	local arch="$1"
	local toolchain_root="$2"
	local host="$3"
	local deps_prefix="$4"

	export PATH="${toolchain_root}/bin:${PATH}"

	echo "== fakesip: ${arch} (${host}) ==" >&2
	make clean >/dev/null 2>&1 || true

	local cross_prefix="${toolchain_root}/bin/${host}-"
	local version
	version="$(git describe --tags --always 2>/dev/null || echo todo)"

	make -j"${JOBS}" \
		STATIC=1 \
		CROSS_PREFIX="${cross_prefix}" \
		VERSION="${version}" \
		CFLAGS="-I${deps_prefix}/include" \
		LDFLAGS="-L${deps_prefix}/lib" >/dev/null

	local out="${OUT_DIR}/fakesip-${arch}"
	mkdir -p "${OUT_DIR}"
	cp -f "${ROOT}/build/fakesip" "${out}"

	if [ -x "${UPX_BIN}" ]; then
		"${UPX_BIN}" --best "${out}" >/dev/null 2>&1 || true
	fi
	echo "${out}"
}

main() {
	cd "${ROOT}"
	if [ ! -x "${UPX_BIN}" ]; then
		echo "upx not found or not executable: ${UPX_BIN}"
		exit 1
	fi
	if [ ! -d "${PLUGIN_BIN_DIR}" ]; then
		echo "plugin bin dir not found: ${PLUGIN_BIN_DIR}"
		exit 1
	fi

	mkdir -p "${TAR_DIR}" "${SRC_DIR}" "${BUILD_DIR}"

	download "https://www.netfilter.org/pub/libmnl/libmnl-${LIBMNL_VER}.tar.bz2" "${TAR_DIR}/libmnl.tar.bz2"
	download "https://www.netfilter.org/pub/libnfnetlink/libnfnetlink-${LIBNFNETLINK_VER}.tar.bz2" "${TAR_DIR}/libnfnetlink.tar.bz2"
	download "https://www.netfilter.org/pub/libnetfilter_queue/libnetfilter_queue-${LIBNFQ_VER}.tar.bz2" "${TAR_DIR}/libnetfilter_queue.tar.bz2"

	extract "${TAR_DIR}/libmnl.tar.bz2" "${SRC_DIR}/libmnl"
	extract "${TAR_DIR}/libnfnetlink.tar.bz2" "${SRC_DIR}/libnfnetlink"
	extract "${TAR_DIR}/libnetfilter_queue.tar.bz2" "${SRC_DIR}/libnetfilter_queue"

	local tc64="/home/sadog/merlin/aarch64-linux-musl-cross"
	local host64="aarch64-linux-musl"

	local tc32="/home/sadog/merlin/arm-linux-musleabi-cross"
	if [ -d "${tc32}/bin" ]; then
		:
	elif [ -d "${tc32}/arm-linux-musleabi-cross/bin" ]; then
		tc32="${tc32}/arm-linux-musleabi-cross"
	fi
	local host32="arm-linux-musleabi"

	local deps32 deps64 out32 out64
	deps32="${BUILD_DIR}/out/arm32"
	deps64="${BUILD_DIR}/out/arm64"

	build_deps arm32 "${tc32}" "${host32}"
	out32="$(build_fakesip arm32 "${tc32}" "${host32}" "${deps32}")"

	build_deps arm64 "${tc64}" "${host64}"
	out64="$(build_fakesip arm64 "${tc64}" "${host64}" "${deps64}")"

	install -m 0755 "${out32}" "${PLUGIN_BIN_DIR}/fakesip-arm"
	install -m 0755 "${out64}" "${PLUGIN_BIN_DIR}/fakesip-arm64"

	echo "replaced:"
	file "${PLUGIN_BIN_DIR}/fakesip-arm" "${PLUGIN_BIN_DIR}/fakesip-arm64"
}

main "$@"

