#!/bin/bash -e

# Build and cache the Ubuntu package layer. Common/board overlays, kernel, DTB
# and modules are applied later by configure-rootfs.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
BUILD_DIR="${BUILD_DIR:-$SDK_ROOT/build}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$BUILD_DIR/scripts}"
OUTPUT_DIR="${OUTPUT_DIR:-$SDK_ROOT/output}"
CACHE_DIR="${CACHE_DIR:-$OUTPUT_DIR/cache}"
ROOTFS_BASE_CACHE_DIR="${ROOTFS_BASE_CACHE_DIR:-$CACHE_DIR/rootfs-base}"
APT_ARCHIVE_CACHE_DIR="${APT_ARCHIVE_CACHE_DIR:-$CACHE_DIR/apt-archives}"
APT_LISTS_CACHE_DIR="${APT_LISTS_CACHE_DIR:-$CACHE_DIR/apt-lists}"
BOARD_DIR="${BOARD_DIR:-$SDK_ROOT/boards/ampheck/eidos-alpha}"
COMMON_LOCAL_PACKAGE_DIR="${COMMON_LOCAL_PACKAGE_DIR:-$SDK_ROOT/common/packages/local}"
COMMON_EXTRA_DEB_MANIFEST="${COMMON_EXTRA_DEB_MANIFEST:-$SDK_ROOT/common/packages/third-party-debs.txt}"
BOARD_LOCAL_PACKAGE_DIR="${BOARD_LOCAL_PACKAGE_DIR:-$BOARD_DIR/packages/local}"
BOARD_EXTRA_DEB_MANIFEST="${BOARD_EXTRA_DEB_MANIFEST:-$BOARD_DIR/packages/third-party-debs.txt}"
ROOTFS_DIR="${ROOTFS_DIR:-$OUTPUT_DIR/rootfs}"
ROOTFS_ROOT="${ROOTFS_ROOT:-$ROOTFS_DIR/root}"

RK_SDK_DIR="$SDK_ROOT"
RK_BUILD_DIR="$BUILD_DIR"
RK_SCRIPTS_DIR="$SCRIPTS_DIR"
RK_OUTDIR="$OUTPUT_DIR"
RK_KERNEL_ARCH="${BOARD_ARCH:-arm64}"
RK_UBUNTU_ARCH="${UBUNTU_ARCH:-arm64}"
RK_UBUNTU_VERSION="${UBUNTU_VERSION:-24.04.5}"
RK_UBUNTU_SUITE="${UBUNTU_SUITE:-noble}"
RK_UBUNTU_BASE_URL="${UBUNTU_BASE_URL:-}"
RK_UBUNTU_SHA256="${UBUNTU_BASE_SHA256:-}"
RK_UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://mirrors.aliyun.com/ubuntu-ports}"
RK_UBUNTU_ROOT_PASSWORD="${UBUNTU_ROOT_PASSWORD:-}"
RK_UBUNTU_USER="${ROOTFS_UBUNTU_USER:-ubuntu}"
RK_UBUNTU_USER_PASSWORD="${ROOTFS_UBUNTU_PASSWORD:-}"
RK_UBUNTU_LOCALE="${ROOTFS_LOCALE:-en_US.UTF-8}"
RK_UBUNTU_PACKAGES="${UBUNTU_PACKAGES:-}"
RK_OWNER_UID="$(id -u)"
RK_OWNER_GID="$(id -g)"

if [ -z "$RK_UBUNTU_SHA256" ]; then
	echo "UBUNTU_BASE_SHA256 is required; run this target through make" >&2
	exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
	UBUNTU_SUDO=
else
	UBUNTU_SUDO=sudo
fi

# Fixed package timestamps reduce variance in locally built board packages.
UBUNTU_PACKAGE_EPOCH="${UBUNTU_PACKAGE_EPOCH:-1704067200}"
# Bump when the apt-installed Ubuntu base layer changes in a way that is not
# already represented by the Ubuntu release, sources or package list.
ROOTFS_PACKAGE_CACHE_VERSION=4

ubuntu_log()
{
	[ "$1" ] || return 0
	local color="$2"
	[ "$color" ] || color=36
	printf '\033[%sm%s\033[0m\n' "$color" "$1"
}

ubuntu_target_arch()
{
	case "${RK_UBUNTU_ARCH:-${RK_KERNEL_ARCH:-arm64}}" in
		arm64|aarch64) echo arm64 ;;
		arm|armhf) echo armhf ;;
		*) return 1 ;;
	esac
}

ubuntu_qemu_static()
{
	case "$1" in
		arm64) echo qemu-aarch64-static ;;
		armhf) echo qemu-arm-static ;;
		*) return 1 ;;
	esac
}

ubuntu_package_field()
{
	local control="$1"
	local field="$2"

	sed -n "s/^${field}:[[:space:]]*//p" "$control" | head -n 1
}

ubuntu_build_local_debs()
{
	local dest="$1"
	local source_roots=(
		"$RK_BUILD_DIR/ubuntu/packages"
		"$COMMON_LOCAL_PACKAGE_DIR"
		"$BOARD_LOCAL_PACKAGE_DIR"
	)
	local build_root="$RK_OUTDIR/ubuntu/deb-build"
	local source_root source control package version arch work deb
	local -a sources=() packages=()

	for source_root in "${source_roots[@]}"; do
		[ -d "$source_root" ] || continue
		for source in "$source_root"/*; do
			[ -d "$source" ] || continue
			control="$source/DEBIAN/control"
			if [ ! -r "$control" ]; then
				ubuntu_log "Missing package control file: $control" 31 >&2
				return 1
			fi

			package="$(ubuntu_package_field "$control" Package)"
			if [ -z "$package" ]; then
				ubuntu_log "Missing package name: $control" 31 >&2
				return 1
			fi
			if printf '%s\n' "${packages[@]}" | grep -Fxq "$package"; then
				ubuntu_log "Duplicate local package: $package" 31 >&2
				ubuntu_log "  $control" 31 >&2
				return 1
			fi
			packages+=("$package")
			sources+=("$source")
		done
	done

	rm -rf "$dest" "$build_root"
	mkdir -p "$dest" "$build_root"

	for source in "${sources[@]}"; do
		control="$source/DEBIAN/control"
		package="$(ubuntu_package_field "$control" Package)"
		version="$(ubuntu_package_field "$control" Version)"
		arch="$(ubuntu_package_field "$control" Architecture)"
		if [ -z "$version" ] || [ -z "$arch" ]; then
			ubuntu_log "Incomplete package metadata: $control" 31 >&2
			return 1
		fi

		work="$build_root/$package"
		cp -a "$source" "$work"
		find "$work" -exec touch -h -d "@$UBUNTU_PACKAGE_EPOCH" {} +

		deb="$dest/${package}_${version}_${arch}.deb"
		SOURCE_DATE_EPOCH="$UBUNTU_PACKAGE_EPOCH" \
			dpkg-deb --root-owner-group --build "$work" "$deb" >/dev/null
		ubuntu_log "Built local package: $(basename "$deb")"
	done
}

ubuntu_download_extra_debs()
{
	local dest="$1"
	local manifest
	local expected url extra filename file
	local -A keep=()

	shift
	mkdir -p "$dest"
	for manifest in "$@"; do
		[ -n "$manifest" ] || continue
		case "$manifest" in
			/*) ;;
			*) manifest="$RK_SDK_DIR/$manifest" ;;
		esac

		if [ ! -r "$manifest" ]; then
			ubuntu_log "Third-party deb manifest not found: $manifest" 31 >&2
			return 1
		fi

		while IFS= read -r line || [ -n "$line" ]; do
			line="${line%$'\r'}"
			case "$line" in
				""|"#"*) continue ;;
			esac

			read -r expected url extra <<< "$line"
			if ! [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || [ -z "$url" ] || \
					[ -n "$extra" ]; then
				ubuntu_log "Invalid deb manifest entry: $line" 31 >&2
				return 1
			fi
			case "$url" in
				http://*|https://*) ;;
				*)
					ubuntu_log "Unsupported deb URL: $url" 31 >&2
					return 1
					;;
			esac

			filename="${url%%[?#]*}"
			filename="${filename##*/}"
			if [ -z "$filename" ]; then
				ubuntu_log "Cannot derive a filename from: $url" 31 >&2
				return 1
			fi
			file="$dest/${expected}-$filename"
			keep["${expected}-$filename"]=1

			if [ -s "$file" ] && \
					echo "$expected  $file" | sha256sum -c - &>/dev/null; then
				ubuntu_log "Using cached third-party deb: $filename"
				continue
			fi

			rm -f "$file" "$file.part"
			ubuntu_log "Downloading third-party deb: $url"
			curl -fL --retry 3 --retry-delay 2 -o "$file.part" "$url"
			echo "$expected  $file.part" | sha256sum -c -
			mv "$file.part" "$file"
		done < "$manifest"
	done

	for file in "$dest"/*.deb "$dest"/*.part; do
		[ -e "$file" ] || continue
		if [ -n "${keep[$(basename "$file")]:-}" ]; then
			continue
		fi
		rm -f "$file"
	done
}

ubuntu_download_base()
{
	local tar_file="$1"
	local url="$2"
	local expected="$3"

	if [ -s "$tar_file" ] && echo "$expected  $tar_file" | sha256sum -c - &>/dev/null; then
		ubuntu_log "Using cached Ubuntu Base: $tar_file"
		return 0
	fi

	rm -f "$tar_file" "$tar_file.part"
	ubuntu_log "Downloading Ubuntu Base: $url"
	curl -fL --retry 3 --retry-delay 2 -o "$tar_file.part" "$url"
	echo "$expected  $tar_file.part" | sha256sum -c -
	mv "$tar_file.part" "$tar_file"
}

ubuntu_cleanup_mounts()
{
	local target="$1"
	local qemu="$2"
	local rc=0
	local mountpoint

	set +e
	for mountpoint in dev/pts dev sys proc; do
		ubuntu_unmount "$target/$mountpoint" || rc=1
	done
	$UBUNTU_SUDO rm -f "$target/run/$qemu"
	set -e

	return "$rc"
}

ubuntu_unmount()
{
	local mountpoint="$1"
	[ -n "$mountpoint" ] || return 0
	mountpoint -q "$mountpoint" || return 0

	for _ in 1 2 3 4 5 6 7 8 9 10; do
		$UBUNTU_SUDO umount "$mountpoint" 2>/dev/null && return 0
		sleep 1
	done

	if mountpoint -q "$mountpoint"; then
		ubuntu_log "Refusing lazy unmount; still busy: $mountpoint" 31 >&2
		return 1
	fi
}

ubuntu_mounts_below()
{
	local root="$1"

	findmnt -r -n -o TARGET | awk -v root="$root" '
		$0 == root || index($0, root "/") == 1 {
			print length($0) "\t" $0
		}
	' | sort -rn | cut -f2-
}

ubuntu_unmount_tree()
{
	local target="$1"
	local mountpoint

	while IFS= read -r mountpoint; do
		[ -n "$mountpoint" ] || continue
		mountpoint -q "$mountpoint" || continue
		$UBUNTU_SUDO umount "$mountpoint" 2>/dev/null || {
			ubuntu_log "Refusing lazy unmount; still busy: $mountpoint" 31 >&2
			return 1
		}
	done < <(ubuntu_mounts_below "$target")

	[ -z "$(ubuntu_mounts_below "$target")" ] || {
		ubuntu_log "Unable to clear mounts below: $target" 31 >&2
		return 1
	}
}

ubuntu_remove_tree()
{
	local target="$1"

	case "$target" in
		""|"/"|"/.")
			ubuntu_log "Refusing to remove unsafe path: $target" 31 >&2
			return 1
			;;
	esac

	ubuntu_unmount_tree "$target"
	$UBUNTU_SUDO rm -rf --one-file-system -- "$target"
}

UBUNTU_CHROOT_TARGET=
UBUNTU_CHROOT_QEMU=
UBUNTU_APT_LISTS_READY=0

ubuntu_copy_cached_deb()
{
	local source="$1"
	local dest="$2"

	if [ -e "$dest" ] && cmp -s "$source" "$dest"; then
		return 0
	fi
	$UBUNTU_SUDO rm -f "$dest"
	$UBUNTU_SUDO cp --reflink=auto "$source" "$dest"
}

ubuntu_seed_apt_archives()
{
	local target="$1"
	local file dest count=0

	$UBUNTU_SUDO mkdir -p "$target/var/cache/apt/archives/partial"
	while IFS= read -r -d '' file; do
		dest="$target/var/cache/apt/archives/${file##*/}"
		ubuntu_copy_cached_deb "$file" "$dest"
		count=$((count + 1))
	done < <(find "$APT_ARCHIVE_CACHE_DIR" -maxdepth 1 \
		-type f -name '*.deb' -print0 2>/dev/null | sort -z)

	[ "$count" -eq 0 ] || \
		ubuntu_log "Seeded $count cached apt archives into the package layer"
}

ubuntu_save_apt_archives()
{
	local target="$1"
	local file name dest count=0

	mkdir -p "$APT_ARCHIVE_CACHE_DIR"
	while IFS= read -r -d '' file; do
		name="${file##*/}"
		dest="$APT_ARCHIVE_CACHE_DIR/$name"
		if [ -e "$dest" ] && cmp -s "$file" "$dest"; then
			continue
		fi
		ubuntu_copy_cached_deb "$file" "$dest"
		count=$((count + 1))
	done < <(find "$target/var/cache/apt/archives" -maxdepth 1 \
		-type f -name '*.deb' -print0 2>/dev/null | sort -z)

	[ "$count" -eq 0 ] || \
		ubuntu_log "Updated apt archive cache with $count package(s)"
}

ubuntu_apt_sources_key()
{
	local arch

	arch="$(ubuntu_target_arch)" || return 1
	{
		printf '%s\n' "format=1" "$RK_UBUNTU_SUITE" "$arch" \
			"$RK_UBUNTU_MIRROR" "main universe"
	} | sha256sum | cut -d' ' -f1
}

ubuntu_seed_apt_lists()
{
	local target="$1"
	local key cache

	key="$(ubuntu_apt_sources_key)" || return 1
	cache="$APT_LISTS_CACHE_DIR/$key"
	[ -d "$cache" ] || return 1
	compgen -G "$cache/*_Packages*" >/dev/null || return 1

	$UBUNTU_SUDO rm -rf "$target/var/lib/apt/lists"
	$UBUNTU_SUDO mkdir -p "$target/var/lib/apt/lists/partial"
	$UBUNTU_SUDO cp -a "$cache/." "$target/var/lib/apt/lists/"
	$UBUNTU_SUDO chown -R 0:0 "$target/var/lib/apt/lists"
}

ubuntu_save_apt_lists()
{
	local target="$1"
	local key cache tmp

	key="$(ubuntu_apt_sources_key)" || return 1
	cache="$APT_LISTS_CACHE_DIR/$key"
	tmp="$cache.tmp.$$"

	$UBUNTU_SUDO rm -rf "$tmp"
	$UBUNTU_SUDO mkdir -p "$tmp" "$APT_LISTS_CACHE_DIR"
	find "$target/var/lib/apt/lists" -maxdepth 1 -type f \
		! -name 'lock' -exec $UBUNTU_SUDO cp -a {} "$tmp/" + 2>/dev/null || true
	[ -n "$(find "$tmp" -type f -print -quit)" ] || {
		$UBUNTU_SUDO rm -rf "$tmp"
		return 1
	}
	$UBUNTU_SUDO rm -rf "$cache"
	$UBUNTU_SUDO mv "$tmp" "$cache"
	$UBUNTU_SUDO chown -R "$RK_OWNER_UID:$RK_OWNER_GID" \
		"$APT_LISTS_CACHE_DIR"

	# Lists are fully determined by the sources key; discard older layouts.
	while IFS= read -r -d '' dir; do
		[ "$dir" = "$cache" ] || $UBUNTU_SUDO rm -rf "$dir"
	done < <(find "$APT_LISTS_CACHE_DIR" -mindepth 1 -maxdepth 1 \
		-type d ! -name '*.tmp.*' -print0)
}

ubuntu_mount_chroot()
{
	local target="$1"
	local qemu="$2"

	UBUNTU_CHROOT_TARGET="$target"
	UBUNTU_CHROOT_QEMU="$qemu"
	trap 'ubuntu_cleanup_mounts "$UBUNTU_CHROOT_TARGET" "$UBUNTU_CHROOT_QEMU"' EXIT
	$UBUNTU_SUDO install -D -m 0755 "$(command -v "$qemu")" "$target/run/$qemu"
	$UBUNTU_SUDO mkdir -p "$target/dev/pts" "$target/proc" "$target/sys" "$target/run"
	$UBUNTU_SUDO mount -t proc proc "$target/proc"
	$UBUNTU_SUDO mount -t sysfs sysfs "$target/sys"
	$UBUNTU_SUDO mount --bind /dev "$target/dev"
	$UBUNTU_SUDO mount --bind /dev/pts "$target/dev/pts"
}

ubuntu_unmount_chroot()
{
	ubuntu_cleanup_mounts "$UBUNTU_CHROOT_TARGET" "$UBUNTU_CHROOT_QEMU"
	trap - EXIT
	UBUNTU_CHROOT_TARGET=
	UBUNTU_CHROOT_QEMU=
}

ubuntu_cleanup_build_configs()
{
	local target="$1"

	$UBUNTU_SUDO rm -f \
		"$target/usr/sbin/policy-rc.d" \
		"$target/etc/apt/apt.conf.d/99eidos-build" \
		"$target/etc/dpkg/dpkg.cfg.d/99eidos-build"
}

ubuntu_prepare_apt_chroot()
{
	local target="$1"

	# Use the host resolver while APT runs in the target chroot.
	$UBUNTU_SUDO rm -f "$target/etc/resolv.conf"
	$UBUNTU_SUDO sh -c "awk '/^nameserver / { print }' /etc/resolv.conf > '$target/etc/resolv.conf'"
	$UBUNTU_SUDO chmod 0644 "$target/etc/resolv.conf"

	# Keep maintainer scripts from starting services in the build chroot.
	$UBUNTU_SUDO sh -c "printf '#!/bin/sh\nexit 101\n' > '$target/usr/sbin/policy-rc.d'"
	$UBUNTU_SUDO chmod 0755 "$target/usr/sbin/policy-rc.d"
	$UBUNTU_SUDO mkdir -p "$target/etc/apt/sources.list.d" \
		"$target/etc/apt/apt.conf.d" "$target/etc/dpkg/dpkg.cfg.d"
	# Do not unpack documentation and translations into the runtime image.
	# Package copyright files are retained for licence compliance.
	$UBUNTU_SUDO tee "$target/etc/dpkg/dpkg.cfg.d/99eidos-build" >/dev/null <<'DPKG_CONFIG'
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/locale/*/LC_MESSAGES/*
DPKG_CONFIG
	$UBUNTU_SUDO sh -c "cat > '$target/etc/apt/sources.list.d/ubuntu.sources' <<SOURCES
Types: deb
URIs: ${RK_UBUNTU_MIRROR}
Suites: ${RK_UBUNTU_SUITE} ${RK_UBUNTU_SUITE}-updates ${RK_UBUNTU_SUITE}-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES"
	# The chroot is disposable, so avoid fsync storms while dpkg unpacks the
	# package set; the finished layer is cached only after apt succeeds.
	$UBUNTU_SUDO tee "$target/etc/apt/apt.conf.d/99eidos-build" >/dev/null <<'APT_CONFIG'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
Acquire::Retries "3";
Acquire::IndexTargets::deb::Contents-deb "false";
Acquire::IndexTargets::deb::DEP-11 "false";
APT::Color "false";
DPkg::Use-Pty "false";
DPkg::Options {
	"--force-confdef";
	"--force-confold";
	"--force-unsafe-io";
};
APT_CONFIG
	ubuntu_seed_apt_archives "$target"
	UBUNTU_APT_LISTS_READY=0
	if ubuntu_seed_apt_lists "$target"; then
		UBUNTU_APT_LISTS_READY=1
		ubuntu_log "Using cached APT indexes; skipping apt-get update"
	fi
}

ubuntu_write_package_manifest()
{
	local target="$1"
	local package
	local -a packages=()

	read -r -a packages <<< "$RK_UBUNTU_PACKAGES"
	{
		for package in "${packages[@]}"; do
			printf '%s\n' "$package"
		done
	} | $UBUNTU_SUDO tee "$target/.bootstrap-packages" >/dev/null
}

ubuntu_package_manifest_is_superset()
{
	local target="$1"
	local package
	local dpkg_status="$target/var/lib/dpkg/status"
	local -a current=()
	local -A current_set=()

	read -r -a current <<< "$RK_UBUNTU_PACKAGES"

	# The dpkg database is authoritative. This also lets us adopt a rootfs
	# produced before the bootstrap markers existed without rerunning apt.
	if [ -r "$dpkg_status" ]; then
		awk -v wanted="$RK_UBUNTU_PACKAGES" '
			/^Package: / { package = $2 }
			/^Status: / {
				if ($2 == "install" && $4 == "installed")
					installed[package] = 1
			}
			END {
				count = split(wanted, packages, " ")
				for (i = 1; i <= count; i++)
					if (!installed[packages[i]])
						exit 1
			}
		' "$dpkg_status"
		return
	fi

	[ -s "$target/.bootstrap-packages" ] || return 1
	for package in "${current[@]}"; do
		current_set["$package"]=1
	done
	while IFS= read -r package; do
		[ -n "$package" ] || continue
		[ -n "${current_set[$package]:-}" ] || return 1
	done < "$target/.bootstrap-packages"
}

ubuntu_finalize_package_layer()
{
	local target="$1"
	local setid_modes ubuntu_owner entry mode path dir legacy diverted

	setid_modes="$(dirname "$target")/setid-modes.$$"

	# Only the user's home needs an ownership fix after the chroot. Avoid a
	# recursive chown of the whole rootfs because chown clears file
	# capabilities such as the cap_net_raw on /usr/bin/ping.
	$UBUNTU_SUDO find "$target/home" -xdev \( -perm /4000 -o -perm /2000 \) \
		-printf '%m %P\0' > "$setid_modes"

	ubuntu_owner="$(awk -F: -v user="$RK_UBUNTU_USER" '$1 == user { print $3 ":" $4 }' \
		"$target/etc/passwd")"
	[ "$ubuntu_owner" ] || {
		ubuntu_log "Unable to determine the $RK_UBUNTU_USER user's UID/GID" 31 >&2
		return 1
	}
	ubuntu_log "Restoring home ownership ($RK_UBUNTU_USER=$ubuntu_owner)..."
	$UBUNTU_SUDO chown -R "$ubuntu_owner" "$target/home/$RK_UBUNTU_USER"

	# A recursive chown also clears setuid/setgid modes.
	while IFS= read -r -d '' entry; do
		mode="${entry%% *}"
		path="${entry#* }"
		[ -e "$target/$path" ] || continue
		$UBUNTU_SUDO chmod "$mode" "$target/$path"
	done < "$setid_modes"
	$UBUNTU_SUDO rm -f "$setid_modes"

	# dpkg keeps DEP17 diversions for the legacy usrmerge paths, but the
	# diverted directories are not part of an official merged-/usr rootfs.
	# Remove only empty leftovers whose canonical path is already a symlink.
	for dir in bin lib sbin lib32 lib64 libo32; do
		legacy="$target/$dir"
		diverted="$legacy.usr-is-merged"
		[ -L "$legacy" ] && [ -d "$diverted" ] || continue
		[ -z "$(find "$diverted" -mindepth 1 -print -quit)" ] || continue
		$UBUNTU_SUDO rmdir "$diverted"
	done
}

ubuntu_install_package_layer()
{
	local target="${1:?missing rootfs directory}"
	local arch qemu

	arch="$(ubuntu_target_arch)" || {
		ubuntu_log "Unsupported Ubuntu architecture: ${RK_UBUNTU_ARCH:-$RK_KERNEL_ARCH}" 31 >&2
		return 1
	}
	qemu="$(ubuntu_qemu_static "$arch")"
	"$RK_SCRIPTS_DIR/check-ubuntu.sh" "$arch" "$qemu"

	ubuntu_mount_chroot "$target" "$qemu"
	ubuntu_prepare_apt_chroot "$target"

	ubuntu_log "Installing Ubuntu packages..."
	$UBUNTU_SUDO chroot "$target" "/run/$qemu" /bin/bash -e -s -- \
		"$RK_UBUNTU_PACKAGES" "$UBUNTU_APT_LISTS_READY" <<'SCRIPT'
		export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
		export DEBIAN_FRONTEND=noninteractive
		export APT_LISTCHANGES_FRONTEND=none
		export NEEDRESTART_MODE=a

		extra_packages="$1"
		apt_lists_ready="$2"
		read -r -a package_array <<< "$extra_packages"

		apt_install() {
			apt-get -q install -y "$@" \
				--no-install-recommends --no-install-suggests \
				systemd-sysv systemd systemd-resolved \
				file kmod openssh-server sudo passwd psmisc ethtool \
				e2fsprogs iproute2 iputils-ping ca-certificates \
				"${package_array[@]}"
		}

		if [ "$apt_lists_ready" != 1 ]; then
			apt-get -q update
		fi
		if ! apt_install --no-upgrade; then
			echo "Cached APT indexes or installed dependencies were insufficient; refreshing." >&2
			rm -rf /var/lib/apt/lists/*
			apt-get -q update
			if ! apt_install --no-upgrade; then
				echo "Package dependencies require an upgrade; retrying with the full resolver." >&2
				apt_install
			fi
		fi
SCRIPT

	# Keep verified downloads and package indexes outside the rootfs before
	# cleaning APT's working directories.
	ubuntu_save_apt_archives "$target"
	if ! ubuntu_save_apt_lists "$target"; then
		ubuntu_log "Unable to cache APT indexes; the package layer is still valid" 33
	fi
	$UBUNTU_SUDO rm -rf "$target/var/lib/apt/lists"
	$UBUNTU_SUDO find "$target/var/cache/apt/archives" -maxdepth 1 \
		-type f -name '*.deb' -delete

	if [ -z "$RK_UBUNTU_USER_PASSWORD" ]; then
		ubuntu_log "ROOTFS_UBUNTU_PASSWORD is empty; locking $RK_UBUNTU_USER." 33
	fi
	ubuntu_cleanup_build_configs "$target"
	ubuntu_unmount_chroot
	ubuntu_write_package_manifest "$target"
}

ubuntu_configure_image()
{
	local target="$1"
	local apt_key="$2"
	local marker="$target/.bootstrap-config-key"
	local config_key arch qemu

	config_key="$({
		printf '%s\n' \
			"format=2" "apt=$apt_key" \
			"user=$RK_UBUNTU_USER" "user_password=$RK_UBUNTU_USER_PASSWORD" \
			"root_password=$RK_UBUNTU_ROOT_PASSWORD" "locale=$RK_UBUNTU_LOCALE" \
			"$(sha256sum "${BASH_SOURCE[0]}")"
	} | sha256sum | cut -d' ' -f1)"

	if [ "${FORCE:-0}" != 1 ] && [ -s "$marker" ] && \
		[ "$(cat "$marker")" = "$config_key" ] && \
		[ -x "$target/bin/bash" ]; then
		ubuntu_log "Ubuntu image configuration is up to date"
		return 0
	fi

	arch="$(ubuntu_target_arch)"
	qemu="$(ubuntu_qemu_static "$arch")"
	"$RK_SCRIPTS_DIR/check-ubuntu.sh" "$arch" "$qemu"

	ubuntu_log "Configuring Ubuntu image users, locales and services..."
	ubuntu_mount_chroot "$target" "$qemu"
	$UBUNTU_SUDO sh -c "printf '#!/bin/sh\nexit 101\n' > '$target/usr/sbin/policy-rc.d'"
	$UBUNTU_SUDO chmod 0755 "$target/usr/sbin/policy-rc.d"
	printf '%s\n%s\n' "$RK_UBUNTU_USER" "$RK_UBUNTU_USER_PASSWORD" | \
		$UBUNTU_SUDO tee "$target/run/eidos-image-credentials" >/dev/null
	$UBUNTU_SUDO chmod 0600 "$target/run/eidos-image-credentials"

	$UBUNTU_SUDO chroot "$target" "/run/$qemu" /bin/bash -e -s -- \
		"$RK_UBUNTU_LOCALE" <<'SCRIPT'
		export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
		export DEBIAN_FRONTEND=noninteractive

		image_locale="$1"
		locale_encoding="${image_locale#*.}"
		if [ "$locale_encoding" = "$image_locale" ]; then
			locale_encoding=UTF-8
		fi
		printf '%s %s\n' "$image_locale" "$locale_encoding" > /etc/locale.gen
		printf '%s\n' \
			"locales locales/locales_to_be_generated multiselect $image_locale $locale_encoding" \
			"locales locales/default_environment_locale select $image_locale" | \
			debconf-set-selections

		rm -f /usr/lib/locale/locale-archive
		locale-gen
		update-locale LANG="$image_locale"

		credential_file=/run/eidos-image-credentials
		[ -r "$credential_file" ] || {
			echo "missing build-only credential file" >&2
			exit 1
		}
		IFS= read -r image_user < "$credential_file"
		IFS= read -r image_password < <(sed -n '2p' "$credential_file")
		rm -f "$credential_file"

		for group in sudo video render input; do
			if ! /usr/bin/getent group "$group" >/dev/null; then
				/usr/sbin/groupadd --system "$group"
			fi
		done
		if /usr/bin/id -u "$image_user" >/dev/null 2>&1; then
			/usr/sbin/usermod --append --groups sudo,video,render,input "$image_user"
		else
			/usr/sbin/useradd --create-home --shell /bin/bash \
				--groups sudo,video,render,input "$image_user"
		fi
		if [ -n "$image_password" ]; then
			printf '%s:%s\n' "$image_user" "$image_password" | /usr/sbin/chpasswd
		else
			/usr/sbin/usermod -p '*' "$image_user"
		fi

		systemctl enable NetworkManager.service systemd-resolved.service ssh.service
		systemctl enable wpa_supplicant.service 2>/dev/null || true
		systemctl disable systemd-networkd.service systemd-networkd.socket \
			systemd-networkd-wait-online.service 2>/dev/null || true
		systemctl mask systemd-networkd.service systemd-networkd.socket \
			systemd-networkd-wait-online.service

		rm -f /etc/resolv.conf
		ln -s ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
SCRIPT

	if [ "$RK_UBUNTU_ROOT_PASSWORD" ]; then
		ubuntu_log "Setting the configured root password..."
		printf 'root:%s\n' "$RK_UBUNTU_ROOT_PASSWORD" | \
			$UBUNTU_SUDO chroot "$target" "/run/$qemu" /usr/sbin/chpasswd
	else
		ubuntu_log "RK_UBUNTU_ROOT_PASSWORD is empty; locking the root password." 34
		$UBUNTU_SUDO chroot "$target" "/run/$qemu" /usr/sbin/usermod -p '*' root
	fi

	$UBUNTU_SUDO rm -f "$target/usr/sbin/policy-rc.d"
	ubuntu_unmount_chroot
	ubuntu_finalize_package_layer "$target"
	printf '%s\n' "$config_key" | \
		$UBUNTU_SUDO tee "$marker" >/dev/null
}

build_ubuntu_rootfs()
{
	local target="${1:?missing rootfs directory}"
	local arch qemu base_url tar_name tar_file

	arch="$(ubuntu_target_arch)" || {
		ubuntu_log "Unsupported Ubuntu architecture: ${RK_UBUNTU_ARCH:-$RK_KERNEL_ARCH}" 31 >&2
		return 1
	}
	qemu="$(ubuntu_qemu_static "$arch")"
	case "$arch" in
		arm64|armhf)
			base_url="${RK_UBUNTU_BASE_URL:-https://cdimage.ubuntu.com/ubuntu-base/releases/$RK_UBUNTU_VERSION/release}"
			;;
	esac
	base_url="${base_url%/}"
	tar_name="ubuntu-base-${RK_UBUNTU_VERSION}-base-${arch}.tar.gz"
	tar_file="$RK_OUTDIR/ubuntu-base/$tar_name"

	mkdir -p "$(dirname "$tar_file")"
	ubuntu_download_base "$tar_file" "$base_url/$tar_name" "$RK_UBUNTU_SHA256"

	ubuntu_log "Extracting Ubuntu Base..."
	ubuntu_remove_tree "$target"
	$UBUNTU_SUDO mkdir -p "$target"
	$UBUNTU_SUDO tar --numeric-owner --acls --xattrs \
		--xattrs-include='*' -xpf "$tar_file" -C "$target"

	ubuntu_install_package_layer "$target"
	ubuntu_log "Ubuntu base layer ready: $target"
}

update_ubuntu_rootfs()
{
	local target="${1:?missing rootfs directory}"

	ubuntu_install_package_layer "$target"
	ubuntu_log "Ubuntu base layer updated incrementally: $target"
}

ubuntu_install_local_debs()
{
	local target="$1"
	local local_deb_dir="$2"
	local extra_deb_dir="$3"
	local marker="$target/var/lib/eidos-local-debs.sha256"
	local target_deb_dir="/var/tmp/eidos-debs"
	local qemu input_hash deb
	local -a debs=()

	while IFS= read -r -d '' deb; do
		debs+=("$deb")
	done < <(find "$local_deb_dir" "$extra_deb_dir" -maxdepth 1 \
		-type f -name '*.deb' -print0 2>/dev/null | sort -z)
	[ "${#debs[@]}" -gt 0 ] || return 0

	input_hash="$({
		printf '%s\n' "format=1"
		sha256sum "${debs[@]}"
	} | sha256sum | cut -d' ' -f1)"
	if [ "${FORCE:-0}" != 1 ] && [ -s "$marker" ] && \
		[ "$(cat "$marker")" = "$input_hash" ]; then
		ubuntu_log "Local packages are up to date"
		return 0
	fi

	qemu="$(ubuntu_qemu_static "$(ubuntu_target_arch)")"
	"$RK_SCRIPTS_DIR/check-ubuntu.sh" "$(ubuntu_target_arch)" "$qemu"
	ubuntu_mount_chroot "$target" "$qemu"
	$UBUNTU_SUDO sh -c "printf '#!/bin/sh\nexit 101\n' > '$target/usr/sbin/policy-rc.d'"
	$UBUNTU_SUDO chmod 0755 "$target/usr/sbin/policy-rc.d"
	$UBUNTU_SUDO rm -rf "$target$target_deb_dir"
	$UBUNTU_SUDO mkdir -p "$target$target_deb_dir"
	for deb in "${debs[@]}"; do
		$UBUNTU_SUDO install -m 0644 "$deb" "$target$target_deb_dir/${deb##*/}"
	done

	ubuntu_log "Installing local and third-party packages..."
	$UBUNTU_SUDO chroot "$target" "/run/$qemu" /usr/bin/env \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		DEBIAN_FRONTEND=noninteractive \
		/bin/sh -c 'dpkg -i "$1"/*.deb; rc=$?; rm -rf "$1"; exit $rc' \
		sh "$target_deb_dir"
	ubuntu_cleanup_build_configs "$target"
	ubuntu_unmount_chroot
	$UBUNTU_SUDO mkdir -p "$(dirname "$marker")"
	printf '%s\n' "$input_hash" | $UBUNTU_SUDO tee "$marker" >/dev/null
}

rootfs_apt_key()
{
	local arch

	arch="$(ubuntu_target_arch)"
	{
		printf '%s\n' \
			"$ROOTFS_PACKAGE_CACHE_VERSION" \
			"$RK_UBUNTU_VERSION" "$RK_UBUNTU_SUITE" "$arch" \
			"$RK_UBUNTU_MIRROR" "$RK_UBUNTU_BASE_URL" "$RK_UBUNTU_SHA256" \
			"$RK_UBUNTU_PACKAGES"
	} | sha256sum | cut -d' ' -f1
}

ubuntu_write_bootstrap_metadata()
{
	local target="$1"
	local key="$2"

	printf '%s\n' "$key" | $UBUNTU_SUDO tee "$target/.bootstrap-key" >/dev/null
	printf '%s\n' "$ROOTFS_PACKAGE_CACHE_VERSION" | \
		$UBUNTU_SUDO tee "$target/.bootstrap-version" >/dev/null
}

ubuntu_package_layer_is_ready()
{
	local target="$1"
	local version

	[ -x "$target/bin/bash" ] || return 1
	version="$(cat "$target/.bootstrap-version" 2>/dev/null || true)"
	[ -z "$version" ] || [ "$version" = "$ROOTFS_PACKAGE_CACHE_VERSION" ] || return 1
	ubuntu_package_manifest_is_superset "$target"
}

ubuntu_legacy_package_layer_cache()
{
	local cache

	cache="$(ls -1t "$CACHE_DIR"/ubuntu-package-layer-*.tar.zst \
		2>/dev/null | head -n 1 || true)"
	[ -n "$cache" ] && [ -s "$cache" ] || return 1
	printf '%s\n' "$cache"
}

restore_ubuntu_cache()
{
	local cache="$1"
	local restore="$2"
	local backup="$ROOTFS_ROOT.old.$$"

	ubuntu_remove_tree "$restore"
	$UBUNTU_SUDO mkdir -p "$restore"
	if ! $UBUNTU_SUDO tar --numeric-owner --acls --xattrs \
		--xattrs-include='*' -I 'zstd -d -T0' \
		-xf "$cache" -C "$restore"; then
		ubuntu_remove_tree "$restore"
		return 1
	fi
	if ! ubuntu_unmount_tree "$ROOTFS_ROOT"; then
		ubuntu_remove_tree "$restore"
		return 1
	fi

	ubuntu_remove_tree "$backup"
	if [ -e "$ROOTFS_ROOT" ]; then
		$UBUNTU_SUDO mv "$ROOTFS_ROOT" "$backup"
	fi
	if ! $UBUNTU_SUDO mv "$restore" "$ROOTFS_ROOT"; then
		[ ! -e "$backup" ] || $UBUNTU_SUDO mv "$backup" "$ROOTFS_ROOT"
		return 1
	fi
	ubuntu_remove_tree "$backup"
}

cache_ubuntu_package_layer()
{
	local cache="$1"
	local tmp="$cache.tmp.$$"

	mkdir -p "$(dirname "$cache")"
	ubuntu_unmount_tree "$ROOTFS_ROOT"
	$UBUNTU_SUDO rm -f "$tmp"
	ubuntu_log "Caching Ubuntu base layer: $cache"
	# Preserve ACLs and extended attributes, including security.capability.
	$UBUNTU_SUDO tar --numeric-owner --acls --xattrs \
		--xattrs-include='*' -I 'zstd -3 -T0' \
		-cf "$tmp" -C "$ROOTFS_ROOT" .
	$UBUNTU_SUDO chown "$RK_OWNER_UID:$RK_OWNER_GID" "$tmp"
	mv "$tmp" "$cache"

	# These are caches from the old monolithic layout and are no longer read.
	find "$ROOTFS_BASE_CACHE_DIR" -maxdepth 1 -type f \
		-name 'ubuntu-package-layer-*.tar.zst' -delete
	find "$CACHE_DIR" -maxdepth 1 -type f \
		-name 'ubuntu-package-layer-*.tar.zst' -delete
}

ubuntu_install_local_packages()
{
	local rootfs_dir

	rootfs_dir="$(dirname "$ROOTFS_ROOT")"
	ubuntu_build_local_debs "$rootfs_dir/debs/local"
	ubuntu_download_extra_debs "$rootfs_dir/debs/third-party" \
		"$COMMON_EXTRA_DEB_MANIFEST" "$BOARD_EXTRA_DEB_MANIFEST"
	ubuntu_install_local_debs "$ROOTFS_ROOT" \
		"$rootfs_dir/debs/local" "$rootfs_dir/debs/third-party"
}

main()
{
	local key cache marker restore need_build=0 updated=0
	local restore_cache legacy_cache cached_version

	mkdir -p "$OUTPUT_DIR"
	exec 9>"$OUTPUT_DIR/.bootstrap-rootfs.lock"
	flock -n 9 || {
		ubuntu_log "Another bootstrap-rootfs.sh process is already running" 31 >&2
		exit 1
	}

	mkdir -p "$ROOTFS_DIR" "$CACHE_DIR" \
		"$ROOTFS_BASE_CACHE_DIR" "$APT_ARCHIVE_CACHE_DIR" \
		"$APT_LISTS_CACHE_DIR"
	key="$(rootfs_apt_key)"
	cache="$ROOTFS_BASE_CACHE_DIR/ubuntu-package-layer.tar.zst"
	marker="$ROOTFS_ROOT/.bootstrap-key"
	restore_cache="$cache"
	if [ ! -s "$restore_cache" ] && \
		legacy_cache="$(ubuntu_legacy_package_layer_cache)"; then
		restore_cache="$legacy_cache"
	fi

	if [ "${FORCE:-0}" != 1 ] && \
		ubuntu_package_layer_is_ready "$ROOTFS_ROOT"; then
		ubuntu_log "Using existing Ubuntu base layer: $ROOTFS_ROOT"
		[ "$(cat "$marker" 2>/dev/null)" = "$key" ] || \
			ubuntu_write_bootstrap_metadata "$ROOTFS_ROOT" "$key"
		[ -s "$cache" ] || updated=1
	elif [ "${FORCE:-0}" != 1 ] && [ -s "$restore_cache" ]; then
		ubuntu_log "Restoring cached Ubuntu base layer: $restore_cache"
		restore="$ROOTFS_ROOT.restore.$$"
		if restore_ubuntu_cache "$restore_cache" "$restore"; then
			cached_version="$(cat "$ROOTFS_ROOT/.bootstrap-version" 2>/dev/null || true)"
			if [ -n "$cached_version" ] && \
				[ "$cached_version" != "$ROOTFS_PACKAGE_CACHE_VERSION" ]; then
				ubuntu_log "Cached base layer is incompatible; rebuilding it" 33
				rm -f "$restore_cache"
				ubuntu_remove_tree "$ROOTFS_ROOT"
				need_build=1
			elif ! ubuntu_package_manifest_is_superset "$ROOTFS_ROOT"; then
				ubuntu_log "Cached Ubuntu base layer needs additional packages..."
				update_ubuntu_rootfs "$ROOTFS_ROOT"
				ubuntu_write_bootstrap_metadata "$ROOTFS_ROOT" "$key"
				updated=1
			else
				ubuntu_log "Using restored Ubuntu base layer: $ROOTFS_ROOT"
				ubuntu_write_bootstrap_metadata "$ROOTFS_ROOT" "$key"
				if [ "$restore_cache" != "$cache" ]; then
					ubuntu_log "Migrating legacy package-layer cache"
					mv "$restore_cache" "$cache"
				fi
			fi
		else
			ubuntu_log "Cached Ubuntu base layer is corrupt; rebuilding it" 33
			rm -f "$restore_cache"
			need_build=1
		fi
	elif [ "${FORCE:-0}" != 1 ] && [ -x "$ROOTFS_ROOT/bin/bash" ] && \
		[ "$(cat "$ROOTFS_ROOT/.bootstrap-version" 2>/dev/null)" = "$ROOTFS_PACKAGE_CACHE_VERSION" ]; then
		ubuntu_log "Adding missing packages to existing Ubuntu base layer..."
		update_ubuntu_rootfs "$ROOTFS_ROOT"
		ubuntu_write_bootstrap_metadata "$ROOTFS_ROOT" "$key"
		updated=1
	else
		need_build=1
	fi

	if [ "$need_build" -eq 1 ]; then
		ubuntu_log "Ubuntu package cache miss; rebuilding base layer" 33
		build_ubuntu_rootfs "$ROOTFS_ROOT"
		ubuntu_write_bootstrap_metadata "$ROOTFS_ROOT" "$key"
		cache_ubuntu_package_layer "$cache"
	elif [ "$updated" -eq 1 ]; then
		cache_ubuntu_package_layer "$cache"
	fi

	ubuntu_install_local_packages
	ubuntu_cleanup_build_configs "$ROOTFS_ROOT"
	ubuntu_configure_image "$ROOTFS_ROOT" "$key"
}

main "$@"
