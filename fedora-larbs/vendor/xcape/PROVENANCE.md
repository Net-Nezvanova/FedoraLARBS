# Vendored xcape

Upstream `https://github.com/alols/xcape` was **deleted**. It had ~2.1k stars
and 112 forks, but the surviving forks are either divergent variants (for
example `ollef/xcape`, 7 commits, remaps control rather than the modifier we
want) or unvetted copies. Pointing the installer at one of them would mean
trusting an arbitrary account with code that runs on every login.

So the source here is vendored instead, taken from **Debian's packaged
`xcape` 1.2-3**, which is distribution-reviewed and archived:

    https://sources.debian.org/src/xcape/1.2-3/

Files are upstream's, unmodified: `xcape.c`, `Makefile`, `xcape.1`, `LICENSE`,
`README.md`. Debian's own `debian/` packaging directory is not included.

Copyright 2015 Albin Olsson. GPL-3.0 — see `LICENSE`.

## What uses it

Exactly one line, in the dotfiles' `.local/bin/remaps`:

    xcape -e 'Super_L=Escape'

`setxkbmap -option caps:super` makes capslock act as Super, which is what every
dwm keybinding is built on. xcape adds the other half: a capslock *tapped* on
its own sends Escape. Without it the dwm bindings still work and you use the
real Escape key.

## Building

`fedora.sh` builds this via the `build_xcape` recipe (`R,xcape` in
`progs.csv`), installing to `/usr/local`. It needs `libX11-devel`,
`libXtst-devel` and `pkgconf-pkg-config`, all of which are already in the
script's bootstrap package list.
