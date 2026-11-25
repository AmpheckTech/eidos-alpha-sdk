# shellcheck shell=bash
#
# Keep root's interactive shell in its home directory.
case "$-" in
*i*)
	# Let Ubuntu's ~/.bashrc use its standard color prompt when this shell is
	# attached to a terminal that actually supports ANSI colors.
	if [ -t 1 ] && command -v tput >/dev/null 2>&1 && \
			tput setaf 1 >/dev/null 2>&1; then
			export force_color_prompt=yes
	fi
	if [ "$(id -u)" -eq 0 ]; then
		export HOME=/root
	fi
	if [ "$(id -u)" -eq 0 ] && [ "$PWD" = "/" ] && [ -d "$HOME" ]; then
		cd "$HOME" || true
	fi
	;;
esac
