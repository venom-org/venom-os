# venom-os

The final bundle: `venom-os up` supervises venomx, venom, venom-desk and the rest. It covers login/session integration, curated defaults, and a catalog of TUI apps. A distro image comes later.

Part of [Venom](https://venom.tools). Status: **alpha**; interfaces may still change. Documentation: [venom.tools](https://venom.tools).

Build from source with the Zig version in `.zigversion` (see [Build](#build)).

Licensed under the [MIT License](LICENSE). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Build

Zig 0.17 (see `.zigversion`). `zig build` fetches `venom-std` at the commit pinned in `build.zig.zon`; to build against a local checkout instead, add `--fork=../venom-std` to any `zig build` command:

```sh
zig build                    # zig-out/bin/venom-os
zig build test-unit          # unit tests
zig build test-conformance   # agent-contract conformance suite against `venom-os serve`
zig build test               # both, plus the `venom-os up` integration test
```

The integration test (`zig build test-up`) drives a real venomx: build
`../venomx` first (`zig build` there) or pass `-Dvenomx=<path>`. It runs in
temporary XDG directories and kills every process it starts.

## Usage

```console
$ venom-os up                     # supervise a persistent `venomx serve` until SIGTERM/SIGINT
$ venom-os defaults               # print the curated venomx defaults
$ venom-os defaults --dir=/etc/xdg   # packagers: install them as /etc/xdg/venomx/defaults.zon
$ venom-os status --json          # mode, installed defaults, supervised venomx
$ venom-os doctor                 # config, socket, defaults, venomx supervised and answering
$ venom-os --help                 # every command; `venom-os skill` for agents
```

venom-os follows the agent contract: `src/verbs.zon` and venom-std's
shared bundles generate the CLI, `venom-os mcp`, docs and completions; every
command takes `--json`. `venom-os up` *is* the daemon in up mode: it serves
`$XDG_RUNTIME_DIR/venom/venom-os.sock` like `venom-os serve` and also installs
the defaults and supervises venomx. `venom-os serve` never starts venomx.
`venom-os service disable --name=venomx` makes the next `up` skip venomx
(`service enable` undoes it); neither stops or starts a running venomx.

`venom-os up` installs `share/venomx/defaults.zon` as
`$XDG_DATA_HOME/venom/venom-os/xdg/venomx/defaults.zon` and puts that directory
first in the daemon's `$XDG_CONFIG_DIRS`. venomx reads it
read-only below your own `~/.config/venomx/config.zon`, so any key you set wins.
The defaults turn off `daemon.interactive_start` (a stray `venomx` never starts
a second daemon), enable durable checkpoints, put the status line
at the top with a curated segment order, and add a `leader g` table that opens
lazygit (`g`), yazi (`f`), helix (`e`) and btop (`t`) in a new window, and
`s` opens your venomx `config.zon` in `$EDITOR` as a popup. They also ship the
float presets `venom-os.launcher` and `venom-os.settings`;
resize them in your config under `floats.presets`.

The supervisor (venom-std `supervisor`) restarts venomx after any exit with
backoff and writes `$XDG_RUNTIME_DIR/venom/venom-os.status.json`. Typing
`venomx` in a terminal then opens a new session on that daemon; exiting the
last shell ends the session but not the daemon.

## Starting at login

`venom-os login install` makes `venom-os up` start at login and gives every
login session the same `$XDG_CONFIG_DIRS`, so a `venomx` typed in an ordinary
terminal reads the venom-os defaults even while the daemon is down (and fails
`unavailable.not_running` instead of starting a second, on-demand daemon). It
writes only under `$XDG_CONFIG_HOME`:

- `systemd/user/venom-os.service`, running `venom-os up` with the absolute
  paths of venom-os and venomx (`--venomx=<path>`; a bare name is resolved in
  `PATH` at install time);
- `systemd/user/default.target.wants/venom-os.service`, the link
  `systemctl --user enable` would make (`--enable=false` skips it);
- `environment.d/50-venom-os.conf`, putting venom-os's directory first in
  `$XDG_CONFIG_DIRS`;

and installs the defaults file. It never runs `systemctl`: start the unit now
with `systemctl --user daemon-reload && systemctl --user start venom-os.service`.
Sessions that do not read environment.d (a plain tty login, some window
managers) can add `eval "$(venom-os env)"` to their shell rc instead.
`venom-os login uninstall` removes exactly those files (files venom-os did not
write are never touched) and leaves a running unit running.

When a venomx that venom-os did not start already serves venomx's socket,
`venom-os up` exits with `conflict.venomx_running` (5) instead of restarting
a second venomx with backoff; the unit does not restart on that exit.
