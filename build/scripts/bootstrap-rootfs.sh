#!/bin/bash -e

# Build and cache the Ubuntu package layer. Common/board overlays, kernel, DTB
# and modules are applied later by configure-rootfs.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
BUILD_DIR="${BUILD_DIR:-$SDK_ROOT/build}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$BUILD_DIR/scripts}"
OUTPUT_DIR="${OUTPUT_DIR:-$SDK_ROOT/output}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$OUTPUT_DIR/downloads}"
CACHE_DIR="${CACHE_DIR:-$OUTPUT_DIR/cache}"
BOARD_DIR="${BOARD_DIR:-$SDK_ROOT/boards/ampheck/eidos-alpha}"
COMMON_LOCAL_PACKAGE_DIR="${COMMON_LOCAL_PACKAGE_DIR:-$SDK_ROOT/common/packages/local}"
COMMON_EXTRA_DEB_MANIFEST="${COMMON_EXTRA_DEB_MANIFEST:-$SDK_ROOT/common/packages/third-party-debs.txt}"
BOARD_LOCAL_PACKAGE_DIR="${BOARD_LOCAL_PACKAGE_DIR:-$BOARD_DIR/packages/local}"
BOARD_EXTRA_DEB_MANIFEST="${BOARD_EXTRA_DEB_MANIFEST:-$BOARD_DIR/packages/third-party-debs.txt}"
ROOTFS_DIR="${ROOTFS_DIR:-$OUTPUT_DIR/rootfs}"
ROOTFS_ROOT="${ROOTFS_ROOT:-$ROOTFS_DIR/root}"

# Keep the package-building code below independent from the old Kconfig layer.
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
# Bump when package-layer construction changes in a way that cannot be
# represented by the package lists, manifests, or local package hashes.
ROOTFS_PACKAGE_CACHE_VERSION=1

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

	shift
	rm -rf "$dest"
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

build_ubuntu_rootfs()
{
	local target="${1:?missing rootfs directory}"
	local rootfs_dir
	local local_deb_dir
	local extra_deb_dir
	local target_deb_dir
	local setid_modes
	local arch
	local qemu
	local base_url
	local tar_name
	local tar_file
	local ubuntu_owner
	local deb dir entry mode path
	local -a deb_files=()
	local -a target_debs=()

	rootfs_dir="$(dirname "$target")"
	local_deb_dir="$rootfs_dir/debs/local"
	extra_deb_dir="$rootfs_dir/debs/third-party"
	target_deb_dir="$target/var/tmp/eidos-debs"
	setid_modes="$rootfs_dir/setid-modes"

	arch="$(ubuntu_target_arch)" || {
		ubuntu_log "Unsupported Ubuntu architecture: ${RK_UBUNTU_ARCH:-$RK_KERNEL_ARCH}" 31 >&2
		return 1
	}
	qemu="$(ubuntu_qemu_static "$arch")"

	"$RK_SCRIPTS_DIR/check-ubuntu.sh" "$arch" "$qemu"

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

	ubuntu_log "Preparing Ubuntu package layers..."
	ubuntu_build_local_debs "$local_deb_dir"
	ubuntu_download_extra_debs "$extra_deb_dir" \
		"$COMMON_EXTRA_DEB_MANIFEST" "$BOARD_EXTRA_DEB_MANIFEST"

	while IFS= read -r -d '' deb; do
		deb_files+=("$deb")
	done < <(find "$local_deb_dir" "$extra_deb_dir" -maxdepth 1 \
		-type f -name '*.deb' -print0 2>/dev/null | sort -z)

	ubuntu_log "Extracting Ubuntu Base..."
	ubuntu_remove_tree "$target"
	$UBUNTU_SUDO mkdir -p "$target"
	$UBUNTU_SUDO tar --numeric-owner -xpf "$tar_file" -C "$target"

	$UBUNTU_SUDO install -D -m 0755 "$(command -v "$qemu")" "$target/run/$qemu"
	$UBUNTU_SUDO mkdir -p "$target/dev/pts" "$target/proc" "$target/sys" "$target/run"
	$UBUNTU_SUDO mount -t proc proc "$target/proc"
	$UBUNTU_SUDO mount -t sysfs sysfs "$target/sys"
	$UBUNTU_SUDO mount --bind /dev "$target/dev"
	$UBUNTU_SUDO mount --bind /dev/pts "$target/dev/pts"
	trap 'ubuntu_cleanup_mounts "$target" "$qemu"' EXIT

	# Use the host resolver while APT runs in the target chroot.
	$UBUNTU_SUDO rm -f "$target/etc/resolv.conf"
	$UBUNTU_SUDO sh -c "awk '/^nameserver / { print }' /etc/resolv.conf > '$target/etc/resolv.conf'"
	$UBUNTU_SUDO chmod 0644 "$target/etc/resolv.conf"

	# Keep maintainer scripts from starting services in the build chroot.
	$UBUNTU_SUDO sh -c "printf '#!/bin/sh\nexit 101\n' > '$target/usr/sbin/policy-rc.d'"
	$UBUNTU_SUDO chmod 0755 "$target/usr/sbin/policy-rc.d"
	$UBUNTU_SUDO mkdir -p "$target/etc/apt/sources.list.d"
	$UBUNTU_SUDO sh -c "cat > '$target/etc/apt/sources.list.d/ubuntu.sources' <<SOURCES
Types: deb
URIs: ${RK_UBUNTU_MIRROR}
Suites: ${RK_UBUNTU_SUITE} ${RK_UBUNTU_SUITE}-updates ${RK_UBUNTU_SUITE}-backports ${RK_UBUNTU_SUITE}-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES"

	if [ "${#deb_files[@]}" -gt 0 ]; then
		$UBUNTU_SUDO mkdir -p "$target_deb_dir"
		for deb in "${deb_files[@]}"; do
			$UBUNTU_SUDO install -m 0644 "$deb" "$target_deb_dir/${deb##*/}"
			target_debs+=("/var/tmp/eidos-debs/${deb##*/}")
		done
	fi
	printf '%s\n%s\n' "$RK_UBUNTU_USER" "$RK_UBUNTU_USER_PASSWORD" | \
		$UBUNTU_SUDO tee "$target/run/eidos-image-credentials" >/dev/null
	$UBUNTU_SUDO chmod 0600 "$target/run/eidos-image-credentials"

	ubuntu_log "Installing Ubuntu and third-party packages..."
	$UBUNTU_SUDO chroot "$target" "/run/$qemu" /bin/bash -e -s -- \
		"$RK_UBUNTU_PACKAGES" "$RK_UBUNTU_LOCALE" "${target_debs[@]}" <<'SCRIPT'
		export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
		export DEBIAN_FRONTEND=noninteractive
		export APT_LISTCHANGES_FRONTEND=none

		extra_packages="$1"
		image_locale="$2"
		shift 2
		read -r -a package_array <<< "$extra_packages"

		locale_encoding="${image_locale#*.}"
		if [ "$locale_encoding" = "$image_locale" ]; then
			locale_encoding=UTF-8
		fi
		printf '%s %s\n' "$image_locale" "$locale_encoding" > /etc/locale.gen
		printf '%s\n' \
			"locales locales/locales_to_be_generated multiselect $image_locale $locale_encoding" \
			"locales locales/default_environment_locale select $image_locale" | \
			debconf-set-selections

		apt-get update
		apt-get install -y --no-install-recommends \
			systemd-sysv systemd systemd-resolved \
				file kmod openssh-server sudo passwd psmisc ethtool \
			e2fsprogs iproute2 iputils-ping ca-certificates \
			"${package_array[@]}"

		if [ "$#" -gt 0 ]; then
			apt-get install -y --no-install-recommends "$@"
		fi

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

		apt-get clean
		rm -rf /var/lib/apt/lists/* /var/tmp/eidos-debs

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
	if [ -z "$RK_UBUNTU_USER_PASSWORD" ]; then
		ubuntu_log "ROOTFS_UBUNTU_PASSWORD is empty; locking $RK_UBUNTU_USER." 33
	fi
	$UBUNTU_SUDO rm -f "$target/usr/sbin/policy-rc.d"

	# Unmount the chroot filesystems before chowning or creating the image.
	ubuntu_cleanup_mounts "$target" "$qemu"
	trap - EXIT

	# A recursive chown clears setuid/setgid bits. Save package-provided modes.
	$UBUNTU_SUDO find "$target" -xdev \( -perm /4000 -o -perm /2000 \) \
		-printf '%m %P\0' > "$setid_modes"

	ubuntu_owner="$(awk -F: -v user="$RK_UBUNTU_USER" '$1 == user { print $3 ":" $4 }' \
		"$target/etc/passwd")"
	[ "$ubuntu_owner" ] || {
		ubuntu_log "Unable to determine the $RK_UBUNTU_USER user's UID/GID" 31 >&2
		return 1
	}
	ubuntu_log "Restoring rootfs ownership ($RK_UBUNTU_USER=$ubuntu_owner)..."
	$UBUNTU_SUDO chown -R 0:0 "$target"
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

	ubuntu_log "Ubuntu package layer ready: $target"
}

rootfs_cache_key()
{
	local package_dir manifest

	{
		printf '%s\n' \
			"$ROOTFS_PACKAGE_CACHE_VERSION" \
			"$UBUNTU_VERSION" "$UBUNTU_SUITE" "$UBUNTU_ARCH" \
			"$UBUNTU_MIRROR" "$UBUNTU_BASE_URL" "$UBUNTU_BASE_SHA256" \
			"$UBUNTU_PACKAGES" "$UBUNTU_ROOT_PASSWORD" "$RK_UBUNTU_LOCALE" \
			"$ROOTFS_UBUNTU_USER" "$ROOTFS_UBUNTU_PASSWORD" "$BOARD_DIR" \
			"$COMMON_LOCAL_PACKAGE_DIR" "$BOARD_LOCAL_PACKAGE_DIR"
		for package_dir in "$COMMON_LOCAL_PACKAGE_DIR" \
			"$BOARD_LOCAL_PACKAGE_DIR"; do
			if [ -d "$package_dir" ]; then
				find "$package_dir" -type f -print0 | \
					sort -z | xargs -0 -r sha256sum
			fi
		done
		for manifest in "$COMMON_EXTRA_DEB_MANIFEST" \
			"$BOARD_EXTRA_DEB_MANIFEST"; do
			if [ -r "$manifest" ]; then
				sha256sum "$manifest"
			fi
		done
	} | sha256sum | cut -d' ' -f1
}

restore_ubuntu_cache()
{
	local key="$1"
	local cache="$2"
	local restore="$3"
	local backup="$ROOTFS_ROOT.old.$$"

	ubuntu_remove_tree "$restore"
	$UBUNTU_SUDO mkdir -p "$restore"
	if ! $UBUNTU_SUDO tar --numeric-owner -I 'zstd -d -T0' \
		-xf "$cache" -C "$restore"; then
		ubuntu_remove_tree "$restore"
		return 1
	fi
	printf '%s\n' "$key" | $UBUNTU_SUDO tee "$restore/.bootstrap-key" >/dev/null
	if ! ubuntu_unmount_tree "$ROOTFS_ROOT"; then
		ubuntu_remove_tree "$restore"
		return 1
	fi

	if [ -e "$ROOTFS_ROOT" ]; then
		$UBUNTU_SUDO mv "$ROOTFS_ROOT" "$backup"
	fi
	if ! $UBUNTU_SUDO mv "$restore" "$ROOTFS_ROOT"; then
		[ ! -e "$backup" ] || $UBUNTU_SUDO mv "$backup" "$ROOTFS_ROOT"
		return 1
	fi
	[ ! -e "$backup" ] || ubuntu_remove_tree "$backup"
}

main()
{
	local key cache marker tmp restore

	mkdir -p "$OUTPUT_DIR"
	exec 9>"$OUTPUT_DIR/.bootstrap-rootfs.lock"
	flock -n 9 || {
		ubuntu_log "Another bootstrap-rootfs.sh process is already running" 31 >&2
		exit 1
	}

	mkdir -p "$ROOTFS_DIR" "$CACHE_DIR"
	key="$(rootfs_cache_key)"
	cache="$CACHE_DIR/ubuntu-package-layer-$key.tar.zst"
	marker="$ROOTFS_ROOT/.bootstrap-key"

	if [ -s "$cache" ]; then
		ubuntu_log "Restoring cached Ubuntu package layer: $cache"
		restore="$ROOTFS_ROOT.restore.$$"
		restore_ubuntu_cache "$key" "$cache" "$restore"
		return 0
	fi

	ubuntu_log "Ubuntu package cache miss; rebuilding package layer" 33
	build_ubuntu_rootfs "$ROOTFS_ROOT"
	printf '%s\n' "$key" | $UBUNTU_SUDO tee "$marker" >/dev/null

	tmp="$cache.tmp"
	rm -f "$tmp"
	ubuntu_log "Caching Ubuntu package layer: $cache"
	$UBUNTU_SUDO tar --numeric-owner -I 'zstd -3 -T0' \
		-cf "$tmp" -C "$ROOTFS_ROOT" .
	$UBUNTU_SUDO chown "$RK_OWNER_UID:$RK_OWNER_GID" "$tmp"
	mv "$tmp" "$cache"
	find "$CACHE_DIR" -maxdepth 1 -type f \
		-name 'ubuntu-package-layer-*.tar.zst' \
		! -name "$(basename "$cache")" -delete
}

main "$@"
