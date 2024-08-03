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

  nonTransitiveDeps = allUnitDeps: getDeps: pkg:
    let
      deps0 = getDeps pkg;
      transitiveDeps = builtins.foldl' (acc: depPkg:
        if allUnitDeps ? "${depPkg}" then acc // getDeps depPkg else acc) { }
        (builtins.attrNames deps0);
      deps1 = builtins.removeAttrs deps0 (builtins.attrNames transitiveDeps);
    in builtins.intersectAttrs allUnitDeps deps1;

  packagesDotGraph = allUnitDeps:
    let
      sep = "\n  ";
      nonTransitiveDeps' = pkg:
        let
          pkgsAndLibs = pkg:
            deps.packageDeps allUnitDeps "pkgs" pkg
            // builtins.removeAttrs (deps.packageDeps allUnitDeps "libs" pkg)
            [ pkg ];
          exes = deps.packageDeps allUnitDeps "exes";
          pkgDeps = nonTransitiveDeps allUnitDeps pkgsAndLibs pkg;
          exeDeps = nonTransitiveDeps allUnitDeps exes pkg;
        in builtins.attrNames (pkgDeps // exeDeps);
      escape = builtins.replaceStrings [ "-" ] [ "_" ];
      genEdges = pkg:
        pkgs.lib.concatMapStringsSep sep (dep: "${escape pkg} -> ${escape dep}")
        (nonTransitiveDeps' pkg);
    in "digraph packages {\n  "
    + pkgs.lib.concatMapStringsSep sep genEdges (builtins.attrNames allUnitDeps)
    + ''

      }'';

  perPackageDotGraph = allUnitDeps: pkg:
    let
      exeDeps = deps.packageDeps allUnitDeps "exes" pkg;
      pkgDeps = deps.packageDeps allUnitDeps "pkgs" pkg;
      libDeps = deps.packageDeps allUnitDeps "libs" pkg;
      exeTransDeps = builtins.foldl' (acc: exePkg:
        if exePkg == pkg then
          acc
        else
          deps.packageDeps allUnitDeps "pkgs" exePkg
          // deps.packageDeps allUnitDeps "libs" exePkg // acc) { }
        (builtins.attrNames exeDeps);
      allDeps = pkgDeps // libDeps // exeDeps // exeTransDeps;
    in packagesDotGraph (builtins.intersectAttrs allDeps allUnitDeps);

  perPackageDotGraphs = allUnitDeps:
    builtins.mapAttrs (k: _: perPackageDotGraph allUnitDeps k) allUnitDeps;

in {
  inherit allDepsToJSON packagesDotGraph perPackageDotGraph perPackageDotGraphs;
}
