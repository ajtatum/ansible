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

[[ $EUID -eq 0 ]] ||
    die "Run as root (Semaphore: become: true)."

# Prevent simultaneous runs of this script.
exec 9>/run/lock/debian-release-upgrade.lock
flock -n 9 || die "Another upgrade script is already running."

source /etc/os-release
[[ ${ID:-} == debian && ${VERSION_CODENAME:-} == bookworm ]] ||
    die "This script requires Debian 12 (Bookworm)."

backup=""

on_error() {
    local rc="$1"
    local line="$2"

    printf '\nUpgrade failed at line %s (exit %s).\n' "$line" "$rc" >&2
    printf 'Backup: %s\n' "${backup:-not created}" >&2
    printf '%s\n' \
        "Inspect the package state before retrying." \
        "Do not simply restore old repositories after a partial upgrade." >&2

    exit "$rc"
}

trap 'on_error "$?" "$LINENO"' ERR

sources=()
debian_sources=0
influx_source=/etc/apt/sources.list.d/influxdata.list

shopt -s nullglob

printf 'Checking repository files...\n'

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

        /etc/apt/sources.list.d/tailscale.list|\
        /etc/apt/sources.list.d/influxdata.list)
            ;;

        *)
            die "Review additional source file before upgrading: $file"
            ;;
    esac

    # Extract suite fields without examining release-like words in URLs.
    suites="$(
        awk '
            /^[[:space:]]*#/ { next }

            # deb822 format.
            /^[[:space:]]*Suites:/ {
                for (i = 2; i <= NF; i++) {
                    if ($i ~ /^#/) break
                    print $i
                }
                next
            }

            # Traditional format:
            # deb [options] URI suite components
            $1 == "deb" || $1 == "deb-src" {
                i = 2

                if ($i ~ /^\[/) {
                    while (i <= NF && $i !~ /\]$/) i++
                    i++
                }

                i++  # Skip repository URI.
                if (i <= NF) print $i
            }
        ' "$file"
    )"

    [[ -n "$suites" ]] ||
        die "Could not identify repository suites in $file"

    while IFS= read -r suite; do
        if [[ "$file" == "$influx_source" ]]; then
            [[ "$suite" == stable ]] ||
                die "Expected InfluxData suite 'stable', found '$suite' in $file"
        else
            case "$suite" in
                bookworm|bookworm-updates|bookworm-security)
                    ;;
                *)
                    die "Unexpected repository suite '$suite' in $file. Review it before upgrading."
                    ;;
            esac
        fi
    done <<< "$suites"

    sources+=("$file")
done

(( debian_sources > 0 )) ||
    die "No supported Debian source file found."

# Validate that the InfluxData exception actually points to InfluxData.
for file in "${sources[@]}"; do
    [[ "$file" == "$influx_source" ]] || continue

    influx_uris="$(
        awk '
            $1 == "deb" || $1 == "deb-src" {
                i = 2

                if ($i ~ /^\[/) {
                    while (i <= NF && $i !~ /\]$/) i++
                    i++
                }

                if (i <= NF) print $i
            }
        ' "$file"
    )"

    [[ -n "$influx_uris" ]] ||
        die "Could not identify InfluxData repository URL."

    while IFS= read -r uri; do
        case "$uri" in
            https://repos.influxdata.com/debian|\
            https://repos.influxdata.com/debian/)
                ;;
            *)
                die "Unexpected URL in InfluxData source: $uri"
                ;;
        esac
    done <<< "$influx_uris"
done

# Refuse to start with incomplete package operations or held packages.
audit="$(dpkg --audit)"
[[ -z "$audit" ]] ||
    die "Resolve dpkg issues first: $audit"

holds="$(apt-mark showhold)"
[[ -z "$holds" ]] ||
    die "Review held packages first: $holds"

# This is a configuration backup, not a full container rollback backup.
backup="$(mktemp -d /root/debian-upgrade-backup.XXXXXXXX)"
cp -a /etc/apt "$backup/apt"
cp -a /var/lib/dpkg/status "$backup/dpkg-status"
dpkg --get-selections > "$backup/package-selections.txt"

printf 'Configuration backup: %s\n' "$backup"

# Use default configuration-file decisions; otherwise retain local files.
apt_options=(
    -y
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
)

printf '\nUpdating Debian 12 before changing repositories...\n'
apt-get -o APT::Update::Error-Mode=any update
apt-get "${apt_options[@]}" dist-upgrade

printf '\nChanging Debian and Tailscale suites to Trixie...\n'
for file in "${sources[@]}"; do
    if [[ "$file" == "$influx_source" ]]; then
        printf 'Keeping InfluxData repository unchanged: %s\n' "$file"
        continue
    fi

    sed -i 's/bookworm/trixie/g' "$file"
done

apt-get -o APT::Update::Error-Mode=any update

printf '\nPerforming minimal upgrade...\n'
apt-get "${apt_options[@]}" upgrade

printf '\nPerforming full upgrade...\n'
apt-get "${apt_options[@]}" dist-upgrade

audit="$(dpkg --audit)"
[[ -z "$audit" ]] ||
    die "Post-upgrade package issues: $audit"

source /etc/os-release
[[ ${ID:-} == debian && ${VERSION_CODENAME:-} == trixie ]] ||
    die "Upgrade finished, but the OS does not report Debian Trixie."

printf '\nUpgrade complete: %s\n' "$PRETTY_NAME"
printf 'Backup retained at: %s\n' "$backup"
printf 'Restart this container and verify its applications.\n'