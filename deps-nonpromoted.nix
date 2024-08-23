# Compute dependencies between units (libraries, executables, tests),
# packages and generated files.
#
# When a unit depends on all units from a package, they're
# collapsed to a package dependency (this is called promotion).
#
# Functions in this file do not attempt to promote partial
# dependencies (when a unit depends on only a few dependencies
# from a package), unlike deps.nix.
{ pkgs, util, ... }@args:
let
  executePromote = { pkgs, libs, ... }@deps:
    promoted:
    deps // {
      pkgs = pkgs // args.pkgs.lib.genAttrs promoted (_: { });
      libs = builtins.removeAttrs libs promoted;
    };

  # Dep entry:
  # { libs : <pkg> -> <name> -> {}
  # , pkgs: <pkg> -> {}
  # , exes : <pkg> -> <name> -> {}
  # , files: <file's dune root> -> {}
  # }
  #
  # Deps:
  # { units: { <pkg> -> <lib|exe|test> -> <name> -> <dep entry> }
  # , files: { <file's dune root> -> { exes: ..., files: ...  } }
  # }
  allDepKeys = directDeps:
    let
      impl = deps: type:
        builtins.concatLists (pkgs.lib.mapAttrsToList (package: entries:
          builtins.map (name: { inherit name package type; })
          (builtins.attrNames entries)) deps);
    in builtins.map (src: {
      type = "file";
      inherit src;
    }) (builtins.attrNames (directDeps.files or { }))
    ++ impl (directDeps.exes or { }) "exe"
    ++ impl (directDeps.libs or { }) "lib";

  directFileDeps = info: dfArgs: src:
    let
      handleDirectDep = { exes, files }@acc:
        dep:
        if info.exes ? "${dep}" then
          let exe = info.exes."${dep}";
          in if dfArgs ? forExe && dfArgs.forExe == exe.name then
            acc
          else
            pkgs.lib.recursiveUpdate acc {
              exes."${exe.package}"."${exe.name}" = { };
            }
        else if info.fileOuts2Src ? "${dep}" then
          let depSrc = info.fileOuts2Src."${dep}";
          in if depSrc == src then
            acc
          else {
            inherit exes;
            files = files // { "${depSrc}" = { }; };
          }
        else
          acc;
      empty = {
        exes = { };
        files = { };
      };
      file_deps = info.srcInfo."${src}".file_deps;
      deps = builtins.foldl' handleDirectDep empty file_deps;
      duneDirs = builtins.concatMap (fd:
        if builtins.baseNameOf fd == "dune" then
          [ (builtins.dirOf fd) ]
        else
          [ ]) file_deps;
    in deps // { files = builtins.removeAttrs deps.files duneDirs; };

  depByKey = { files, units }:
    { type, ... }@key:
    if type == "file" then
      files."${key.src}"
    else
      units."${key.package}"."${key.type}"."${key.name}";

  trivialPromoted = info: libs:
    let
      promote_ = pkg: libs:
        let
          pkgDef = info.packages."${pkg}";
          libs_ = builtins.attrNames libs;
          rem = builtins.removeAttrs pkgDef.lib libs_;
          trivialCase = rem == { } && pkgDef.test == { } && pkgDef.exe == { };
        in if trivialCase then [ pkg ] else [ ];
    in builtins.concatLists (pkgs.lib.mapAttrsToList promote_ libs);

  computeDepsImpl = info: acc0: path: directDeps:
    let
      recLoopMsg = "Recursive loop in ${builtins.concatStringsSep "." path}";
      acc1 = util.setAttrByPath (throw recLoopMsg) acc0 path;
      directKeys = allDepKeys directDeps;
      acc2 = builtins.foldl' (computeDeps info) acc1 directKeys;
      # Inheritance logic:
      #  - inherit executables and files from all of dependencies
      #  - inherit libs, packages from all lib dependencies
      # (lib, pkg dependencies are not to be inherited from file, exe dependencies)
      depMap = builtins.foldl' (acc': key:
        let
          subdeps = depByKey acc2 key;
          update = if key.type == "lib" then
            subdeps
          else
            subdeps // {
              libs = { };
              pkgs = { };
            };
        in pkgs.lib.recursiveUpdate update acc') directDeps directKeys;
      depMap' = executePromote depMap (trivialPromoted info depMap.libs);
    in util.setAttrByPath depMap' acc2 path;

  directLibDeps = info: unit:
    let
      implementsDep = if unit ? "implements" then [ unit.implements ] else [ ];
    in { libs = util.organizeLibsByPackage info (implementsDep ++ unit.deps); };

  computeDeps = info:
    { files, units }@acc:
    { type, ... }@self:
    if type == "file" then
      if files ? "${self.src}" then
        acc
      else
        computeDepsImpl info acc [ "files" self.src ]
        (directFileDeps info { } self.src // {
          pkgs = { };
          libs = { };
        })
    else if units ? "${self.package}"."${self.type}"."${self.name}" then
      acc
    else
      let
        unit = info.packages."${self.package}"."${self.type}"."${self.name}";
        dfArgs = if self.type == "exe" then { forExe = unit.name; } else { };
        directDeps = directFileDeps info dfArgs unit.src
          // directLibDeps info unit // {
            pkgs = { };
          };
      in computeDepsImpl info acc [ "units" self.package self.type self.name ]
      directDeps;

  allUnitKeys = allUnits:
    builtins.concatLists (pkgs.lib.mapAttrsToList (package: units0:
      builtins.concatLists (pkgs.lib.mapAttrsToList (type: units:
        builtins.map (name: { inherit type name package; })
        (builtins.attrNames units)) units0)) allUnits);

  hasImplementation = deps:
    util.attrFold (res0: pkg: libs:
      builtins.foldl' (res: name:
        res || (deps.pkgs ? "${pkg}") || (deps.libs ? "${pkg}"."${name}")) res0
      (builtins.attrNames libs)) false;

  defaultImplementations = implementations: info: selfImplements: deps:
    util.attrFold (acc: pkg: pkgLibs:
      let
        defs = builtins.foldl' (acc: name:
          let unit = info.packages."${pkg}".lib."${name}";
          in if unit ? "default_implementation" then
            let
              defImplLib = util.toPubName info unit.default_implementation;
              # Check that default implementations do not contain package itself,
              # and there are indeed no implementations for the virtual library
            in if selfImplements != name
            && !(hasImplementation deps (implementations."${name}" or { })) then
              [ defImplLib ] ++ acc
            else
              acc
          else
            acc) [ ] (builtins.attrNames pkgLibs);
      in if defs == [ ] then acc else acc // { "${pkg}" = defs; }) { }
    deps.libs;

  insertDefImplWithDeps = preliminaryUnits: defImplPkg: deps0: defImplName:
    let deps1 = util.setAttrByPath { } deps0 [ "libs" defImplPkg defImplName ];
    in pkgs.lib.recursiveUpdate deps1
    preliminaryUnits."${defImplPkg}".lib."${defImplName}";

  allDepsNotFullyPromoted = info:
    let
      empty = {
        files = { };
        units = { };
      };
      preliminary =
        builtins.foldl' (computeDeps info) empty (allUnitKeys info.packages);
      implementations = util.attrFold (acc0: pkg:
        { lib, ... }:
        util.attrFold (acc: name: def:
          if def ? "implements" then
            let pname = util.toPubName info def.implements;
            in pkgs.lib.recursiveUpdate acc {
              "${pname}"."${pkg}"."${name}" = { };
            }
          else
            acc) acc0 lib) { } info.packages;
      units = builtins.mapAttrs (pkg:
        builtins.mapAttrs (type:
          builtins.mapAttrs (name: deps:
            let
              selfImplements =
                (info.packages."${pkg}"."${type}"."${name}".implements or "");
              selfImplements' = if selfImplements == "" then
                ""
              else
                util.toPubName info selfImplements;
              defImpls =
                defaultImplementations implementations info selfImplements'
                deps;
              deps' = util.attrFold (acc: defImplPkg:
                builtins.foldl'
                (insertDefImplWithDeps preliminary.units defImplPkg) acc) deps
                defImpls;
            in executePromote deps' (trivialPromoted info deps'.libs))))
        preliminary.units;
    in {
      inherit (preliminary) files;
      inherit units;
    };
in { inherit allDepsNotFullyPromoted executePromote; }
