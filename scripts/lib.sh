# Sourced by the other scripts in this directory; not run on its own.
#
# Homebrew's cargo can precede ~/.cargo/bin on PATH, and it ignores
# rust-toolchain.toml, so a bare `cargo` would build with the wrong toolchain
# (and without the pinned components and targets). Putting rustup's own shims
# first makes every script, and so every `just` recipe, use the toolchain the
# repository pins. In CI ~/.cargo/bin is already first, so this changes
# nothing there.
export PATH="$HOME/.cargo/bin:$PATH"
