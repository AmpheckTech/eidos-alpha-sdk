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
