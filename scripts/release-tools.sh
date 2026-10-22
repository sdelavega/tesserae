#!/usr/bin/env bash
# Tesserae: a disk-space visualizer.
# Copyright (C) 2026 Stephen de la Vega
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.


# Every child starts with a fresh allowlisted environment, including functions.
# Transfer values privately: even gh's allowed credential never enters argv.
tool() (
    local name
    local allow_gh=0
    local -a allowed=()
    if [[ ${PUBLISH_GH_AUTH:-0} == 1 && $1 == "${GH:-gh}" ]]; then allow_gh=1; fi
    for name in $(builtin compgen -e); do
        case "$name" in
            PATH|HOME|TMPDIR|LANG|LC_*|USER|DEVELOPER_DIR) allowed+=("$name=${!name}") ;;
            GH_TOKEN)
                if [[ $allow_gh == 1 ]]; then
                    allowed+=("$name=${!name}")
                fi ;;
        esac
    done
    /usr/bin/env -i /bin/bash --noprofile --norc -c '
        allow_gh=$1; shift
        while IFS= builtin read -r -d "" entry <&9; do
            name=${entry%%=*}
            [[ $entry == *=* && $name != *[!a-zA-Z0-9_]* ]] || continue
            case "$name" in
                PATH|HOME|TMPDIR|LANG|LC_*|USER|DEVELOPER_DIR) builtin export "$entry" ;;
                GH_TOKEN) if [[ $allow_gh == 1 ]]; then builtin export "$entry"; fi ;;
            esac
        done
        exec 9<&-
        exec "$@"
    ' bash "$allow_gh" "$@" 9< <(builtin printf '%s\0' "${allowed[@]}")
)
# Feed redaction values through a private pipe, never argv or a disk file.
redactions() {
    local name
    for name in $(builtin compgen -e); do
        case "$name" in
            *TOKEN*|*KEY*|*SECRET*|*PASSWORD*|DEVELOPER_ID_P12_BASE64) builtin printf '%s\0' "${!name}" ;;
        esac
    done
}

# A missing branch is the first release; transport/authentication errors fail.
fetch_appcast() {
    local remote_status=0
    if tool "${GIT:-git}" ls-remote --exit-code origin refs/heads/gh-pages >/dev/null; then
        tool "${GIT:-git}" fetch origin +refs/heads/gh-pages:refs/remotes/origin/gh-pages
        tool "${GIT:-git}" show origin/gh-pages:appcast.xml > "$1"
    else
        remote_status=$?
        [[ $remote_status == 2 ]] || return "$remote_status"
        : > "$1"
    fi
}
