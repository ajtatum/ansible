#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "Run as root (Semaphore: become: true)."

# Prevent simultaneous runs of this script.
exec 9>/run/lock/debian-release-upgrade.lock
flock -n 9 || die "Another upgrade script is already running."

source /etc/os-release
[[ ${ID:-} == debian && ${VERSION_CODENAME:-} == bookworm ]] ||
    die "This script requires Debian 12 (Bookworm)."

backup=""
trap 'rc=$?; printf "Upgrade failed at line %s (exit %s). Backup: %s\nInspect the package state before retrying; do not simply restore old repositories.\n" "$LINENO" "$rc" "${backup:-not created}" >&2; exit "$rc"' ERR

# Supported source-file locations. Unknown active sources require review.
sources=()
debian_sources=0
shopt -s nullglob

for file in \
    /etc/apt/sources.list \
    /etc/apt/sources.list.d/*.list \
    /etc/apt/sources.list.d/*.sources
do
    [[ -f "$file" ]] || continue

    # Ignore empty files and files containing only comments.
    if ! grep -Eq '^[[:space:]]*[^#[:space:]]' "$file"; then
        continue
    fi

    case "$file" in
        /etc/apt/sources.list|\
        /etc/apt/sources.list.d/debian.list|\
        /etc/apt/sources.list.d/debian.sources)
            debian_sources=$((debian_sources + 1))
            ;;
        /etc/apt/sources.list.d/tailscale.list)
            ;;
        *)
            die "Review and disable additional source file first: $file"
            ;;
    esac

    # This conservative check also rejects commented backports entries.
    if grep -Eq 'backports|proposed-updates' "$file"; then
        die "Remove backports/proposed-updates entries first: $file"
    fi

    grep -q 'bookworm' "$file" ||
        die "Expected Bookworm sources in $file; review it manually."

    sources+=("$file")
done

(( debian_sources > 0 )) || die "No supported Debian source file found."

# Refuse common mixed-release or moving-suite configurations.
for file in "${sources[@]}"; do
    if grep -Ev '^[[:space:]]*(#|$)' "$file" |
        grep -Eq '(^|[[:space:]/])(bullseye|trixie|forky|sid|stable|oldstable|testing|unstable)([-/[:space:]]|$)'
    then
        die "Mixed-release or moving-suite source found: $file"
    fi
done

# Do not start with an incomplete package operation or held packages.
audit="$(dpkg --audit)"
[[ -z "$audit" ]] || die "Resolve dpkg issues first: $audit"

holds="$(apt-mark showhold)"
[[ -z "$holds" ]] || die "Review held packages first: $holds"

backup="$(mktemp -d /root/debian-upgrade-backup.XXXXXXXX)"
cp -a /etc/apt "$backup/apt"
cp -a /var/lib/dpkg/status "$backup/dpkg-status"
dpkg --get-selections > "$backup/package-selections.txt"
printf 'Configuration backup: %s\n' "$backup"

# Use default conffile decisions, otherwise retain local configuration.
apt_options=(
    -y
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
)

printf '\nUpdating Debian 12 before changing repositories...\n'
apt-get -o APT::Update::Error-Mode=any update
apt-get "${apt_options[@]}" dist-upgrade

printf '\nChanging repositories to Debian 13...\n'
for file in "${sources[@]}"; do
    sed -i 's/bookworm/trixie/g' "$file"
done

apt-get -o APT::Update::Error-Mode=any update

printf '\nPerforming minimal upgrade...\n'
apt-get "${apt_options[@]}" upgrade

printf '\nPerforming full upgrade...\n'
apt-get "${apt_options[@]}" dist-upgrade

audit="$(dpkg --audit)"
[[ -z "$audit" ]] || die "Post-upgrade package issues: $audit"

source /etc/os-release
[[ ${VERSION_CODENAME:-} == trixie ]] ||
    die "Upgrade finished, but the OS does not report Trixie."

printf '\nUpgrade complete: %s\n' "$PRETTY_NAME"
printf 'Backup retained at: %s\n' "$backup"
printf 'Restart this container and verify its services before proceeding.\n'