#!/bin/bash

eidos_verify_file()
{
	local file="$1"
	local sha256="$2"

	[ -s "$file" ] || return 1
	printf '%s  %s\n' "$sha256" "$file" | sha256sum -c - >/dev/null
}

eidos_download_verified()
{
	local url="$1"
	local dest="$2"
	local sha256="$3"
	local retries="${4:-3}"
	local label="${5:-$(basename "$dest")}"

	eidos_verify_file "$dest" "$sha256" && return 0

	mkdir -p "$(dirname "$dest")"
	rm -f "$dest" "$dest.part"
	echo "Downloading $label: $url"
	curl -fL --retry "$retries" --retry-delay 2 -o "$dest.part" "$url"
	eidos_verify_file "$dest.part" "$sha256" || {
		rm -f "$dest.part"
		return 1
	}
	mv "$dest.part" "$dest"
}

eidos_apply_patches()
{
	local source="$1"
	local label="$2"
	local patch_dir patch_file
	shift 2

	for patch_dir in "$@"; do
		[ -d "$patch_dir" ] || continue

		for patch_file in "$patch_dir"/*.patch; do
			[ -r "$patch_file" ] || continue

			if patch --batch --forward --dry-run -d "$source" -p1 \
				< "$patch_file" >/dev/null 2>&1; then
				echo "Applying $label patch: $(basename "$patch_file")"
				patch --batch --forward -d "$source" -p1 < "$patch_file"
			elif patch --batch --reverse --dry-run -d "$source" -p1 \
				< "$patch_file" >/dev/null 2>&1; then
				echo "Already applied $label patch: $(basename "$patch_file")"
			else
				echo "Cannot apply $label patch: $patch_file" >&2
				return 1
			fi
		done
	done
}

eidos_hash_files()
{
	local file

	[ "$#" -gt 0 ] || return 1
	for file in "$@"; do
		[ -r "$file" ] || {
			echo "missing input file: $file" >&2
			return 1
		}
		sha256sum "$file"
	done | sha256sum | cut -d' ' -f1
}

eidos_hash_tree()
{
	local root="$1"
	local privilege="${2:-}"
	local -a prefix=()

	[ -d "$root" ] || {
		echo "missing input directory: $root" >&2
		return 1
	}
	[ -z "$privilege" ] || prefix=("$privilege")

	{
		"${prefix[@]}" find "$root" -xdev \
			-printf '%P\0%y\0%m\0%U\0%G\0%s\0%T@\0%l\0'
		"${prefix[@]}" find "$root" -xdev -type f -print0 |
			sort -z |
			xargs -0 -r "${prefix[@]}" sha256sum
	} | sha256sum | cut -d' ' -f1
}
