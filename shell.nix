with import <nixpkgs> {};

let
  unstable = import
    (builtins.fetchTarball https://nixos.org/channels/nixos-unstable/nixexprs.tar.xz)
    # reuse the current configuration
    { config = config; };
in
pkgs.mkShell {
    buildInputs = with pkgs; [
        SDL2
        SDL2.dev
        glfw
    ];
  nativeBuildInputs = with pkgs; [
    unstable.zig_0_13
    unstable.zls
  ];
  PKG_CONFIG_PATH = "${SDL2.dev}/lib/pkgconfig:${glfw}/lib/pkgconfig";
}
