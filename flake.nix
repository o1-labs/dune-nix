{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11-small";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pathFilter = import ./filter.nix { inherit pkgs; };
        util = import ./util.nix { inherit pkgs pathFilter; };
        depsNonpromoted = import ./deps-nonpromoted.nix { inherit pkgs util; };
        deps = import ./deps.nix { inherit pkgs util depsNonpromoted; };
        show = import ./show.nix { inherit pkgs deps; };
        vm = import ./vm.nix { inherit pkgs util; };
        output =
          import ./output.nix { inherit pkgs util pathFilter deps show; };
        info = import ./info.nix { inherit pkgs util; };
      in {
        formatter = pkgs.nixfmt;
        lib = {
          inherit info;
          inherit (output) outputs outputs';
          inherit (util)
            fixupSymlinksInSource skippedTest packageHasTestDefs packageHasUnit
            makefileTest squashOpamNixDeps;
          inherit (show) allDepsToJSON packagesDotGraph;
          inherit (vm) testWithVm testWithVm';
          inherit (deps) allDeps;
          inherit pathFilter util depsNonpromoted deps show vm output;
        };
      });
}
