# shell.nix — Matrix for the Surface Duo, host side (NixOS)
#
#   nix-shell                 # enter
#   sh Morpheus.AppImage      # then follow the repo's README
#
# What this shell is for
# ----------------------
# Morpheus.AppImage is a /bin/sh preamble + tar (offset 16385) that unpacks
# itself once into ~/.cache/morpheus and then exec's a Rust front end
# (x86_64/usr/bin/matrix-morpheus-duo). It bundles adb/fastboot and the Duo
# images, but it does NOT bundle a C library, libwayland or libEGL: those come
# from the host. The front end is an ELF with interpreter
# /lib64/ld-linux-x86-64.so.2 and it dlopen()s the *unversioned* sonames
# "libwayland-client.so" and "libEGL.so", which nixpkgs only ships as .so.N.
# Hence: a shim dir with the unversioned links, first on LD_LIBRARY_PATH.
#
# Why nixpkgs is pinned
# ---------------------
# The front end references GLIBC_2.39 symbols, so the host loader must be
# >= 2.39. A stale <nixpkgs> (23.11 root channel, glibc 2.38) silently
# breaks the AppImage. nixos-26.05 is pinned to
# match the running system (glibc 2.42, mesa 25.3). Override with e.g.
#   nix-shell --arg nixpkgs 'builtins.getFlake "nixpkgs"'
{
  nixpkgs ? builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-26.05.tar.gz",
}:

let
  pkgs = import nixpkgs { };

  libShim = pkgs.runCommand "morpheus-lib-shim" { } ''
    mkdir -p $out/lib
    ln -s ${pkgs.wayland}/lib/libwayland-client.so.0    $out/lib/libwayland-client.so
    ln -s ${pkgs.wayland}/lib/libwayland-cursor.so.0    $out/lib/libwayland-cursor.so
    ln -s ${pkgs.wayland}/lib/libwayland-egl.so.1       $out/lib/libwayland-egl.so
    ln -s ${pkgs.libglvnd}/lib/libEGL.so.1              $out/lib/libEGL.so
    ln -s ${pkgs.libglvnd}/lib/libGLESv2.so.2           $out/lib/libGLESv2.so
    ln -s ${pkgs.libglvnd}/lib/libGL.so.1               $out/lib/libGL.so
    ln -s ${pkgs.libx11}/lib/libX11.so.6                $out/lib/libX11.so
  '';
in
pkgs.mkShell {
  name = "morpheus-duo";

  packages = with pkgs; [
    # loaded (dlopen / DT_NEEDED) by the front end
    wayland
    libxkbcommon
    libglvnd
    mesa
    xkeyboard-config
    libx11

    # /bin/sh preamble: tar, sha256sum, df, readlink, awk, cut
    coreutils
    findutils
    gawk
    gnugrep
    gnused
    gnutar
    util-linux

    # host-side Android tooling (AppImage brings its own; this is for
    # "adb devices" / "fastboot devices" outside Morpheus)
    android-tools
    usbutils

    # not bundled in the AppImage, but used by morpheus-laptop scripts:
    #   morpheus-lieferant.sh  -> ssh (backup/delivery) , zstd -dc (verify)
    openssh
    zstd
    # the /bin/sh preamble calls notify-send if it exists
    libnotify
    # morpheus-netz.sh brings up 172.16.42.2/24 on the Duo's USB interface
    # (nmcli preferred, ip as fallback); the front end also shells out to
    # xdg-user-dir (photo/backup dirs) and gsettings (accent colour).
    iproute2
    xdg-user-dirs
    glib

    # building the images from source (best effort, see NIXOS.md)
    squashfsTools
    cpio
    rsync
    openssl
  ];

  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
    libShim
    pkgs.wayland
    pkgs.libxkbcommon
    pkgs.libglvnd
    pkgs.mesa
    pkgs.libx11
  ];
  XKB_CONFIG_ROOT = "${pkgs.xkeyboard-config}/share/X11/xkb";
  LIBGL_DRIVERS_PATH = "/run/opengl-driver/lib/dri";

  shellHook = ''
    echo "── Morpheus / Matrix for the Surface Duo ──────────────────────────"

    # 1. nix-ld is what makes the AppImage's /lib64 interpreter resolve.
    if [ -L /lib64/ld-linux-x86-64.so.2 ]; then
      echo "  loader      : /lib64/ld-linux-x86-64.so.2 -> nix-ld  ok"
    else
      echo "  loader      : MISSING /lib64/ld-linux-x86-64.so.2"
      echo "                add to configuration.nix:"
      echo "                  programs.nix-ld.enable = true;"
    fi

    # 1b. Morpheus' own helper scripts (morpheus-live.sh, duo-fedora.sh,
    #     morpheus-lieferant.sh, morpheus-recovery.sh — shipped as
    #     x86_64/usr/bin/*.sh inside the AppImage) are all #!/bin/bash, and
    #     the front end execs them directly, without "bash" in between.
    #     NixOS ships only /bin/sh, so they die with ENOENT (exit 127).
    if [ -x /bin/bash ]; then
      echo "  /bin/bash   : present  ok"
    else
      echo "  /bin/bash   : MISSING — Morpheus' helper scripts cannot start"
      echo "                (symptom: the first install step fails at once)"
      echo "                add to configuration.nix, then nixos-rebuild switch:"
      echo '                  system.activationScripts.binbash.text = "ln -sfn ''${pkgs.bash}/bin/bash /bin/bash";'
    fi

    # 2. adb/fastboot access. systemd ships the Android uaccess rule
    #    (70-uaccess.rules matches *:ff4201:* / *:ff4203:* / *:dc0201:*),
    #    so ADB and Fastboot already work without any extra udev setup.
    #    Morpheus' own «Allow access» button cannot work on NixOS: it runs
    #    pkexec to write /etc/udev/rules.d/51-morpheus-duo.rules, and that
    #    path is a read-only symlink to /etc/static/udev/rules.d.
    if grep -qsE 'ff4201|dc0201' /run/current-system/sw/lib/udev/rules.d/*.rules /etc/udev/rules.d/*.rules; then
      echo "  adb/fastboot : uaccess via systemd 70-uaccess.rules  ok"
    else
      echo "  adb/fastboot : no Android uaccess rule found — add:"
      echo "                  services.udev.extraRules = builtins.readFile ./51-morpheus-duo.rules;"
    fi
    if grep -qs '0c26' /etc/udev/rules.d/*.rules; then
      echo "  duo vendor   : 045e:0c26/0c29/0c2f rule present  ok"
    else
      echo "  duo vendor   : 045e:0c26/0c29/0c2f rule absent (optional; only"
      echo "                 needed if Morpheus reports «No access»)"
    fi

    # 3. First start needs ~1.5 GB free where it unpacks.
    free=$(df -Pk "''${XDG_CACHE_HOME:-$HOME/.cache}" 2>/dev/null | awk 'NR==2{print int($4/1024)}')
    if [ -n "$free" ] && [ "$free" -lt 1600 ]; then
      echo "  cache space : ''${free} MB free in ~/.cache — too little for the 1.2 GB unpack"
      echo "                set MORPHEUS_CACHE to a roomier directory"
    else
      echo "  cache space : ''${free} MB free  ok"
    fi

    echo "  adb         : $(command -v adb)  ($(adb version 2>/dev/null | head -1))"
    echo "──────────────────────────────────────────────────────────────────"
    echo "  start with:  sh Morpheus.AppImage"
  '';
}
