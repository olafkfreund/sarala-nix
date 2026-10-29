{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_11,
  nodejs_22,
  cargo-tauri,
  pkg-config,
  wrapGAppsHook3,
  cmake,
  webkitgtk_4_1,
  gtk3,
  librsvg,
  libayatana-appindicator,
  glib-networking,
  wayland,
  dbus,
  alsa-lib,
  openblas,
  curl,
  xdg-utils,
  withVoice ? true,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "sarala";
  version = "1.4.2";

  src = fetchFromGitHub {
    owner = "solancer";
    repo = "sarala";
    tag = "v${finalAttrs.version}";
    hash = "sha256-p4d+mClhL2bYeSNGAKP4SeDwMvCy2gapEdjMZGB9Ags=";
  };

  cargoRoot = "src-tauri";
  buildAndTestSubdir = "src-tauri";
  cargoHash = "sha256-O0wrgkZBN2QH5RMu6toYkAen+V9Xve0r8spOzCVVPAE=";

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_11;
    fetcherVersion = 5;
    hash = "sha256-84+JK2rjGnJqZPsPk8JOWOygcJTVz4IMsb+PilqFlpw=";
  };

  nativeBuildInputs = [
    cargo-tauri.hook
    pnpmConfigHook
    pnpm_11
    nodejs_22
    pkg-config
    wrapGAppsHook3
  ]
  ++ lib.optional withVoice cmake;

  buildInputs = [
    webkitgtk_4_1
    gtk3
    librsvg
    libayatana-appindicator
    glib-networking
    wayland
    dbus
  ]
  ++ lib.optionals withVoice [
    alsa-lib
    openblas
  ];

  buildNoDefaultFeatures = !withVoice;
  buildFeatures = lib.optional withVoice "voice";

  # GGML_NATIVE=OFF: a native build bakes the builder's CPU into a cached binary.
  # x86 flags match upstream's release build; voice/mod.rs already refuses pre-AVX2 CPUs.
  env.TRANSCRIBE_CMAKE_ARGS = lib.concatStringsSep " " (
    [
      "-DGGML_NATIVE=OFF"
      "-DBLA_VENDOR=OpenBLAS"
    ]
    ++ lib.optionals stdenv.hostPlatform.isx86_64 [
      "-DGGML_AVX=ON"
      "-DGGML_AVX2=ON"
      "-DGGML_FMA=ON"
      "-DGGML_F16C=ON"
      "-DGGML_AVX512=OFF"
    ]
  );

  # No updater signing key exists here, and Nix owns updates.
  tauriBuildFlags = [
    "--config"
    ''{"bundle":{"createUpdaterArtifacts":false}}''
  ];

  # The unpatched build relies on can_self_update() returning false for a
  # non-dpkg/rpm/AppImage install; fail loudly if upstream drops that gate.
  postPatch = ''
    grep -q 'fn can_self_update' src-tauri/src/main.rs
  '';

  doCheck = false;

  postInstall = ''
    mv $out/share/applications/Sarala.desktop $out/share/applications/sarala.desktop
  ''
  + lib.optionalString withVoice ''
    patchelf --print-needed $out/bin/sarala | grep -q libopenblas
  '';

  # Voice model downloads shell out to curl; "reveal in folder" to xdg-open.
  preFixup = ''
    gappsWrapperArgs+=(--prefix PATH : ${
      lib.makeBinPath [
        curl
        xdg-utils
      ]
    })
  '';

  # Upstream's jsdom unit suites (pnpm test); e2e and perf need a browser.
  passthru.tests.frontend = stdenv.mkDerivation {
    pname = "sarala-frontend-tests";
    inherit (finalAttrs) version src pnpmDeps;
    nativeBuildInputs = [
      pnpmConfigHook
      pnpm_11
      nodejs_22
    ];
    buildPhase = ''
      runHook preBuild
      pnpm test
      runHook postBuild
    '';
    installPhase = "touch $out";
  };

  meta = {
    description = "WYSIWYG Markdown editor with live rendering, math and diagrams";
    homepage = "https://github.com/solancer/sarala";
    license = lib.licenses.gpl3Plus;
    mainProgram = "sarala";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
})
