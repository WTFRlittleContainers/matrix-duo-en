# Running Morpheus on NixOS — what the shell does and why

`nix-shell` in this directory gives you everything the laptop side of
[`matrix-duo`](https://github.com/Matrix-Hardline/matrix-duo) needs. Then follow
the repo's README: `sh Morpheus.AppImage`.

## Verified platform (NixOS 26.05, Hyprland, x86_64)

| Check | Result |
|---|---|
| `sh Morpheus.AppImage` | unpacks 1.2 GB, sha256-checks the factory image, launches |
| Front end window | paints maximised, 2× scaling detected, stays alive |
| `adb` / `fastboot` | from the shell (host) and bundled in the AppImage |
| `nix-ld` loader for the bundled ELF | present (`/lib64/ld-linux-x86-64.so.2`) |
| `ip` / `xdg-user-dir` / `gsettings` / `zstd` / `ssh` | provided by the shell |
| Install (= helper scripts) | **blocked until `/bin/bash` exists** — see below |
| Device access | not yet exercised — no Duo was plugged in |

## The five host-side facts that mattered

1. **A stale `<nixpkgs>` (23.11, glibc 2.38) breaks it.**
   The bundled front end references `GLIBC_2.39` symbols, so it needs a host
   loader ≥ 2.39. `shell.nix` therefore pins `nixos-26.05` (glibc 2.42) instead
   of `<nixpkgs>`. Override with `--arg nixpkgs …` if you prefer.

2. **The front end `dlopen`s unversioned sonames** — `libwayland-client.so`
   and `libEGL.so` — which nixpkgs only ships as `.so.N`. `shell.nix` builds a
   small shim derivation with the unversioned links and puts it first on
   `LD_LIBRARY_PATH`. Without it the app dies with
   `The wayland library could not be loaded`.

3. **The AppImage is not a FUSE mount.** It is `/bin/sh` + a tar at byte 16385
   that unpacks once into `~/.cache/morpheus/<id>` and `exec`s
   `x86_64/AppRun`. So `appimage-run`/FUSE is not needed; what is needed is
   `tar`, `sha256sum`, `df`, `awk` — hence coreutils/gawk/gnutar in the shell.

4. **Morpheus' «Allow access» button cannot work on NixOS.** It runs
   `pkexec sh -c 'cat > /etc/udev/rules.d/51-morpheus-duo.rules; udevadm …'`,
   and `/etc/udev/rules.d` is a read-only symlink to `/etc/static/udev/rules.d`.
   It is also **not needed for adb/fastboot**: systemd's built-in
   `70-uaccess.rules` already tags `*:ff4201:*` / `*:ff4203:*` / `*:dc0201:*`
   with `uaccess`. That is why `pkgs.android-udev-rules` was dropped from
   nixpkgs ("superseded by built-in systemd uaccess rules").

5. **The helper scripts are `#!/bin/bash`, and NixOS only ships `/bin/sh`.**
   `morpheus-live.sh`, `duo-fedora.sh`, `morpheus-lieferant.sh` and
   `morpheus-recovery.sh` ship inside the AppImage as `x86_64/usr/bin/*.sh`,
   all `#!/bin/bash`; the front end execs them directly (the binary contains no
   `bash` string, so nothing re-interprets them). On the verified host:

   ```
   $ ./morpheus-live.sh
   timeout: failed to run command './morpheus-live.sh': No such file or directory   # 127
   ```

   That is the whole job of a missing interpreter. It is the one thing the
   shell cannot supply — `/bin` is system-owned. See below.

## The one system change still required: /bin/bash

```nix
# configuration.nix — makes the AppImage's helper scripts executable
system.activationScripts.binbash.text = "ln -sfn ${pkgs.bash}/bin/bash /bin/bash";
```

Then `nixos-rebuild switch` (no reboot needed). The shell hook reports whether
this is in place.

Related, and unfixable from a shell: the *privileged* paths run `ip` and
`udevadm` through `pkexec`, whose PATH is the hardcoded
`/usr/sbin:/usr/bin:/sbin:/bin` — none of which exist on NixOS. So:
* the usb-rule path fails regardless (expected, and unnecessary);
* `morpheus-netz.sh` falls back to `nmcli`, which is why NetworkManager must be
  running — it was running on the verified host, so the USB network came up
  without a password
  prompt. Without `nmcli` the script needs root for `ip addr add`.

## If Morpheus still reports «No access»

Add the vendor rule declaratively — Morpheus' own copy is in
`51-morpheus-duo.rules` next to this file:

```nix
# hosts/<host>/hardware-configuration.nix (next to the existing EDL rule)
services.udev.extraRules = builtins.readFile ./51-morpheus-duo.rules;
```

then `nixos-rebuild switch`. Replug the Duo afterwards.

## Watch the disk: 26 GB free is tight

* The first start needs ~1.5 GB free next to the cache (checked by the shell
  hook; relocate with `MORPHEUS_CACHE=/path/with/room`).
* The installer's recommended **full backup** streams every partition through
  `zstd -3` to `~/Sicherungen/surface-duo-<serial>/vollsicherung-<date>/`
  (`morpheus/laptop/morpheus-lieferant.sh:20-42`). On a 128 GB or 256 GB Duo
  that is easily more than the 26 GB left on `/`. **Point it at an external
  drive** — `$HOME/Sicherungen` is on `/`.
* Verification of that backup runs `zstd -dc` **on the laptop** (line 38),
  which is why `zstd` is in the shell.

## Building the images from source (not needed for installing)

The repo's build scripts do not compile against the host toolchain:

* `boot/*.sh` pull `quay.io/droidian/build-essential:current-{arm64,amd64}`
  and build inside **podman** (`boot/1-kernel-bauen.sh:18,21`,
  `boot/2-initramfs-holen.sh:5,7`).
* `system/bau-*.sh` drive `dnf --installroot=… --releasever=42` into a
  **Fedora 42** root (e.g. `system/bau-mesa-42.sh:6,7`), i.e. they assume a
  Fedora host with `dnf` and root.

On NixOS that means podman plus a Fedora 42 container, not nixpkgs packages.
`podman` is not provided by this shell (it needs subuid/subgid setup); enable
`virtualisation.podman` in the system config if you want to go down that road.
Credentials, chroots and `--installroot` mkosi-style steps are outside what a
`shell.nix` can honestly provide.

## Running the apps locally to review English (fork addition)

The apps are plain Wayland clients, so a laptop is enough to review a
translation change — no image, no Duo. Two things are needed on NixOS:

1. **The unversioned-soname shim.** The window house `dlopen`s
   `libwayland-client.so` and `libEGL.so`; nixpkgs ships only `.so.N`. The
   `libShim` derivation in `shell.nix` creates the links — enter the shell, or
   reuse the pattern:

   ```nix
   runCommand "morpheus-lib-shim" {} ''
     mkdir -p $out/lib
     ln -s ${pkgs.wayland}/lib/libwayland-client.so.0 $out/lib/libwayland-client.so
     ln -s ${pkgs.libglvnd}/lib/libEGL.so.1        $out/lib/libEGL.so
   ''
   ```

2. **A catalogue to read.** The shipping path
   `/usr/share/matrix/sprache/en.tsv` does not exist on a laptop, so without
   this the apps fall back to the 14 compiled pairs. Point them at the file in
   this repository:

   ```sh
   cargo build -p matrix-settings
   MATRIX_LANGUAGE=en-GB \
   MATRIX_CATALOGUE=$PWD/morpheus/sprache/en.tsv \
     ./target/debug/matrix-settings
   ```

   `MATRIX_LANGUAGE` takes the language chain («en-GB», «de-CH»);
   `MATRIX_CATALOGUE` is read once at start; neither is set on a Duo.

3. **What stayed German.** `MATRIX_LANGUAGE_MISSES=/tmp/misses.txt` appends
   every painted text the catalogue could not translate, once each. It records
   content as well as chrome (host name, CPU model, memory figures), so filter
   it before treating it as a work list — a German-looking test is enough.

Measured with `matrix-settings`: 66 texts missed without a
catalogue (34 of them German UI), 32 with it (none German — all hardware data).

