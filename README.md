# dune-nix: granular nix builds for dune projects

Nix wrapping suitable for multi-package dune repositories that employs use of nix cache on a package level.

## Motivation

Using [tweag/opam-nix](https://github.com/tweag/opam-nix) it's possible to assemble dune project's opam dependencies and write a derivation where these depdenencies will be in `buildInputs` with build phase as simple as `dune build`.

However, this means that the whole dune project will be compiled in one go. Sadly, this is not great for large projects: compilation and running tests may take significant time, and needs to be re-executed (on CI) even after the smallest change.

Contrary to that, _dune-nix_ will split up the dune project to a dependency tree of packages and then provide a set of derivations where each package gets a single derivation and its dependencies are used as part of `buildInputs`. This allows to leverage nix's excellent support for caching build results on a package level.

When integrated to [MinaProtocol/mina](https://github.com/MinaProtocol/mina/pulls), it reduced running time of building+tests from 20 minutes on every change to a range of 3 minutes to 20 minutes, depending on how deep down the dependency stack was the change (with biggest boost coming from non-running expensive tests when relevant packages weren't touched).

## Usage

Assuming a dune project root has an `opam.export` file for project's opam dependencies:

```
deps = opam-nix.opamListToQuery (opam-nix.importOpam ../opam.export).installed;
depsScope = opam-nix.defsToScope pkgs { } (opam-nix.queryToDefs repos deps);
dune-nix = inputs.dune-nix.lib.${pkgs.system};
describe-dune = inputs.describe-dune.defaultPackage.${pkgs.system};

base-libs = dune-nix.squashOpamNixDeps scope.ocaml.version
  (pkgs.lib.attrVals (builtins.attrNames deps) scope);

dune-description = pkgs.stdenv.mkDerivation {
  pname = "dune-description";
  version = "dev";
  src = pkgs.lib.sources.sourceFilesBySuffices ./. [
    "dune"
    "dune-project"
    ".inc"
    ".opam"
  ];
  phases = [ "unpackPhase" "buildPhase" ];
  buildPhase = ''
    ${describe-dune}/bin/describe-dune > $out
  '';
};

duneDescLoaded = builtins.fromJSON (builtins.readFile dune-description);
info = dune-nix.info duneDescLoaded;
allDeps = dune-nix.allDeps info;
commonOverrides = {
  DUNE_PROFILE = "dev";
  buildInputs = [ base-libs ];
};

testsToIgnoreByDefault =
  dune-nix.packageHasUnit ({ src, ... }: pkgs.lib.hasPrefix "src/heavy-tests/" src);

overlay = self: _:
  dune-nix.outputs' commonOverrides ./. allDeps info testsToIgnoreByDefault self;
```

Applying the resulting `overlay` will add a number of derivations that allow to build individual packages and all packages/tests at once.
