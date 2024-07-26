# Some definitions to export information about dune project to text form
{ pkgs, deps, ... }@args:
let
  pruneListDeps = acc: field:
    if acc ? "${field}" then
      acc // { "${field}" = builtins.attrNames acc."${field}"; }
    else
      acc;
  pruneMultiDeps = acc: field:
    if acc ? "${field}" then
      acc // {
        "${field}" = builtins.mapAttrs (_: builtins.attrNames) acc."${field}";
      }
    else
      acc;
  pruneDepMap = with pkgs.lib;
    (flip pkgs.lib.pipe [
      (filterAttrs (_: val: val != { }))
      (flip (builtins.foldl' pruneListDeps) [ "files" "pkgs" ])
      (flip (builtins.foldl' pruneMultiDeps) [ "exes" "libs" ])
    ]);

  allDepsToJSON = { files, units }:
    builtins.toJSON {
      files = builtins.mapAttrs (_: pruneDepMap) files;
      units = builtins.mapAttrs (_: # iterating packages
        builtins.mapAttrs (_: # iterating types
          builtins.mapAttrs (_: # iterating names
            pruneDepMap))) units;
    };

  packagesDotGraph = allUnitDeps:
    let
      sep = "\n  ";
      nonTransitiveDeps = pkg:
        let
          pkgDeps = deps.packageDeps allUnitDeps "pkgs" pkg;
          transitiveDeps = builtins.foldl' (acc: depPkg:
            if allUnitDeps ? "${depPkg}" then
              acc // deps.packageDeps allUnitDeps "pkgs" depPkg
            else
              acc) { } (builtins.attrNames pkgDeps);
        in builtins.attrNames
        (builtins.removeAttrs pkgDeps (builtins.attrNames transitiveDeps));
      escape = builtins.replaceStrings [ "-" ] [ "_" ];
      genEdges = pkg:
        pkgs.lib.concatMapStringsSep sep (dep: "${escape pkg} -> ${escape dep}")
        (nonTransitiveDeps pkg);
    in "digraph packages {\n  "
    + pkgs.lib.concatMapStringsSep sep genEdges (builtins.attrNames allUnitDeps)
    + ''

      }'';

  perPackageDotGraph = allUnitDeps: pkg:
    let
      pkgDeps = deps.packageDeps allUnitDeps "pkgs" pkg;
      pkgNames = builtins.attrNames pkgDeps;
    in packagesDotGraph (pkgs.lib.getAttrs pkgNames allUnitDeps);

  perPackageDotGraphs = allUnitDeps:
    builtins.mapAttrs (k: _: perPackageDotGraph allUnitDeps k) allUnitDeps;

in {
  inherit allDepsToJSON packagesDotGraph perPackageDotGraph perPackageDotGraphs;
}
