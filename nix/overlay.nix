final: prev: {
  gtk4 = prev.gtk4.overrideAttrs (prevAttrs: {
    version = "4.23.3";
    src = prev.fetchurl {
      url = "mirror://gnome/sources/gtk/4.23/gtk-4.23.3.tar.xz";
      hash = "sha256-yBkSsIKlvqrR2ElEgFv3zA+Gxqkz4TFmTa09sybt6SQ=";
    };

    # Patch in Nixpkgs isn't needed anymore
    patches = [ ];

    buildInputs = (prevAttrs.buildInputs or [ ]) ++ [
      prev.libthai
    ];

    # Removed a nonexistent (?) `moveToOutput` call
    postInstall = ''
      PATH="$OLD_PATH"
    ''
    + prev.lib.optionalString (!prev.stdenv.hostPlatform.isDarwin) ''
      # The updater is needed for nixos env and it's tiny.
      moveToOutput bin/gtk4-update-icon-cache "$out"
      # Launcher
      moveToOutput bin/gtk-launch "$out"
      # Broadway daemon
      moveToOutput bin/gtk4-broadwayd "$out"
    '';
  });

  libadwaita = prev.libadwaita.overrideAttrs {
    # For some reason checks are failing with the new GTK 4 version
    doCheck = false;
  };

  zenity = prev.zenity.overrideAttrs {
    # Manpage build fails. No idea why
    mesonFlags = [ "-Dmanpage=false" ];
  };
}
