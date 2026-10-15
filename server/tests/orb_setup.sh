#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Isolate profile behavior from downloads/builds. Installation is validated by
# running the real setup separately; these stand-ins implement its tool probes.
for active in .profile .bash_login .bash_profile none; do
    home="$scratch/$active"
    mkdir -p "$home/.cargo/bin" "$home/.local/share/zig-0.16.0"
    printf '#!/bin/sh\nexit 0\n' > "$home/.cargo/bin/rustup"
    printf '#!/bin/sh\nexit 0\n' > "$home/.cargo/bin/cargo"
    printf '#!/bin/sh\necho 0.16.0\n' > "$home/.local/share/zig-0.16.0/zig"
    chmod +x "$home/.cargo/bin/"* "$home/.local/share/zig-0.16.0/zig"
    if [[ "$active" != none ]]; then
        printf 'export PROFILE_SENTINEL=%s\n' "$active" > "$home/$active"
        # Lower-precedence files must remain unchanged and must not be sourced.
        if [[ "$active" != .profile ]]; then
            printf 'export PROFILE_SENTINEL=wrong\n' > "$home/.profile"
        fi
        if [[ "$active" == .bash_profile ]]; then
            printf 'export PROFILE_SENTINEL=wrong\n' > "$home/.bash_login"
        fi
    fi
    for run in 1 2; do
        HOME="$home" bash "$repo_root/.agents/setup" >/dev/null 2>&1
    done
    target="$active"
    [[ "$target" != none ]] || target=.bash_profile
    [[ "$(grep -Fc '# multiplexer orb toolchains' "$home/$target")" == 1 ]]
    if [[ "$active" == .profile || "$active" == .bash_login ]]; then
        [[ ! -e "$home/.bash_profile" ]]
    fi
    (
        cd "$repo_root"
        env -i HOME="$home" PATH=/usr/bin:/bin EXPECTED="$active" bash -lc '
            [[ "${PROFILE_SENTINEL:-none}" == "$EXPECTED" ]]
            [[ "$(command -v cargo)" == "$HOME/.cargo/bin/cargo" ]]
            [[ "$(command -v zig)" == "$HOME/.local/bin/zig" ]]
            [[ "$(zig version)" == 0.16.0 ]]
        '
    )
    # The hook is repository-scoped, including when .profile is read by sh.
    (
        cd "$scratch"
        env -i HOME="$home" PATH=/usr/bin:/bin bash -lc '
            [[ "$PATH" != *"$HOME/.cargo/bin"* ]]
        '
    )
    if [[ "$active" == .profile ]]; then
        env -i HOME="$home" PATH=/usr/bin:/bin /bin/sh -c '. "$HOME/.profile"'
    fi
    echo "PASS $active: original login initialization and one scoped PATH hook"
done
