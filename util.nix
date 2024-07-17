{ pkgs, pathFilter, ... }@args:
let
  canonicalizePath = ps:
    let
      p = pkgs.lib.splitString "/" ps;
      p' = builtins.foldl' (acc: el:
        if el == "." then
          acc
        else if acc == [ ] then
          [ el ]
        else if el == ".." && pkgs.lib.last acc != ".." then
          pkgs.lib.init acc
        else
          acc ++ [ el ]) [ ] p;
    in pkgs.lib.concatStringsSep "/" p';

  # Utility function that builds a path with symlinks replaced with
  # contents of their targets.
  # Takes three arguments:
  #  - prefix of derivation name (string)
  #  - original path (path)
  #  - root of the newly created path (path)
  # It returns a derivation without symlinks that contains
  # everything from the original path, rearranged as relative
  # to the root.
  fixupSymlinksInSource = pkgName: src: root:
    let
      depListDrv = pkgs.stdenv.mkDerivation {
        inherit src;
        name = "${pkgName}-symlink-targets";
        phases = [ "unpackPhase" "installPhase" ];
        installPhase = ''
          find -type l -exec bash -c 'echo "$(dirname {})/$(readlink {})"' ';' > $out
          find \( -type f -o -type l \) >> $out
        '';
      };
      fileListTxt = builtins.readFile depListDrv;
      fileList =
        builtins.map canonicalizePath (pkgs.lib.splitString "\n" fileListTxt);
      filters = builtins.map pathFilter.all fileList;
    in pathFilter.filterToPath {
      path = root;
      name = "source-${pkgName}-with-correct-symlinks";
    } (pathFilter.merge filters);

  quote = builtins.replaceStrings [ "." "/" ] [ "__" "-" ];

  # Overriding a test.xyz attribute with this derivation would mute a particular test
  # (useful when test is temporarily non-functioning)
  skippedTest = pkgs.stdenv.mkDerivation {
    name = "skipped-test";
    phases = [ "installPhase" ];
    installPhase = ''
      echo "echo test is skipped" > $out
    '';
  };

  # Overriding a test.xyz attribute with this derivation allows
  # test to be executed in a custom manner via Makefile provided in the
  # test directory
  makefileTest = root: pkg: src: super:
    let path = root + "/${src}/Makefile";
    in super.pkgs."${pkg}".overrideAttrs {
      pname = "test-${pkg}";
      installPhase = "touch $out";
      dontCheck = false;
      buildPhase = ''
        runHook preBuild
        cp ${path} ${src}/Makefile
        make -C ${src}
        runHook postBuild
      '';
    };

  # Some attrsets helpers
  attrFold = f: acc: attrs:
    builtins.foldl' (acc: { fst, snd }: f acc fst snd) acc
    (pkgs.lib.zipLists (builtins.attrNames attrs) (builtins.attrValues attrs));
  attrAll = f: attrFold (acc: key: value: acc && f key value) true;
  setAttrByPath = val: attrs: path:
    if path == [ ] then
      val
    else
      let
        hd = builtins.head path;
        tl = builtins.tail path;
      in attrs // { "${hd}" = setAttrByPath val (attrs."${hd}" or { }) tl; };

  # Evaluates predicate against units of a given package
  # and returns true if any of units satisfy the predicate
  packageHasUnit = predicate: pkgDef:
    builtins.foldl' (acc0: v0:
      builtins.foldl' (acc: v: acc || predicate v) acc0
      (builtins.attrValues v0)) false (builtins.attrValues pkgDef);

  # Evaluates to true if any of the units of a package has tests
  packageHasTestDefs =
    packageHasUnit (v: (v.has_inline_tests or false) || v.type == "test");

  artifactEnvVar = pkgs.lib.concatMapStringsSep "_"
    (builtins.replaceStrings [ "-" "." "/" ] [ "___" "__" "___" ]);

  squashOpamNixDeps = ocamlVersion: buildInputs:
    pkgs.stdenv.mkDerivation {
      name = "squashed-ocaml-dependencies";
      phases = [ "installPhase" ];
      inherit buildInputs;
      installPhase = ''
        mkdir -p $out/lib/ocaml/${ocamlVersion}/site-lib/stublibs $out/nix-support $out/bin
        {
          echo -n 'export OCAMLPATH=$'
          echo -n '{OCAMLPATH-}$'
          echo '{OCAMLPATH:+:}'"$out/lib/ocaml/${ocamlVersion}/site-lib"
          echo -n 'export CAML_LD_LIBRARY_PATH=$'
          echo -n '{CAML_LD_LIBRARY_PATH-}$'
          echo '{CAML_LD_LIBRARY_PATH:+:}'"$out/lib/ocaml/${ocamlVersion}/site-lib/stublibs"
        } > $out/nix-support/setup-hook
        for input in $buildInputs; do
          [ ! -d "$input/lib/ocaml/${ocamlVersion}/site-lib" ] || {
            find "$input/lib/ocaml/${ocamlVersion}/site-lib" -maxdepth 1 -mindepth 1 -not -name stublibs | while read d; do
              ln -s "$d" "$out/lib/ocaml/${ocamlVersion}/site-lib/"
            done
          }
          [ ! -d "$input/lib/ocaml/${ocamlVersion}/site-lib/stublibs" ] || cp -Rs "$input/lib/ocaml/${ocamlVersion}/site-lib/stublibs"/* "$out/lib/ocaml/${ocamlVersion}/site-lib/stublibs/"
          [ ! -d "$input/bin" ] || cp -Rs $input/bin/* $out/bin
          [ ! -f "$input/nix-support/propagated-build-inputs" ] || { cat "$input/nix-support/propagated-build-inputs" | sed -r 's/\s//g'; echo ""; } >> $out/nix-support/propagated-build-inputs.draft
          echo $input >> $out/nix-support/propagated-build-inputs.ref
        done
        sort $out/nix-support/propagated-build-inputs.draft | uniq | grep -vE '^$' > $out/nix-support/propagated-build-inputs.draft.unique
        sort $out/nix-support/propagated-build-inputs.ref | uniq | grep -vE '^$' > $out/nix-support/propagated-build-inputs.ref.unique
        comm -2 -3 $out/nix-support/propagated-build-inputs.{draft,ref}.unique > $out/nix-support/propagated-build-inputs
        rm $out/nix-support/propagated-build-inputs.*
      '';
    };

in {
  inherit fixupSymlinksInSource quote skippedTest attrFold attrAll setAttrByPath
    packageHasTestDefs packageHasUnit artifactEnvVar makefileTest
    squashOpamNixDeps;
}
