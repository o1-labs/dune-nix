# dune-nix: granular nix builds for dune projects

Nix wrapping suitable for multi-package dune repositories that employs use of nix cache on a package level.

## Motivation

Using [tweag/opam-nix](https://github.com/tweag/opam-nix) it's possible to assemble dune project's opam dependencies and write a derivation where these depdenencies will be in `buildInputs` with build phase as simple as `dune build`.

However, this means that the whole dune project will be compiled in one go. Sadly, this is not great for large projects: compilation and running tests may take significant time, and needs to be re-executed (on CI) even after the smallest change.

Contrary to that, _dune-nix_ will split up the dune project to a dependency tree of packages and then provide a set of derivations where each package gets a single derivation and its dependencies are used as part of `buildInputs`. This allows to leverage nix's excellent support for caching build results on a package level.

When integrated to [MinaProtocol/mina](https://github.com/MinaProtocol/mina), it reduced running time of building+tests from 20 minutes on every change to a range of 3 minutes to 20 minutes, depending on how deep down the dependency stack was the change (with biggest boost coming from non-running expensive tests when relevant packages weren't touched).

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

## Build methodology

Dune files are analyzed by the [o1-labs/describe-dune](https://github.com/o1-labs/describe-dune) tool. Libraries, executables, tests and generated files, along with their mutual dependencies (as present by dune files) are extracted.

After that, dependencies between all of the units (libraries, executables, tests) and files are determined. Then a greedy algorithm attempts to "upgrade" each library/executable dependency to a package dependency. It ends with an error if it fails. But if it succeeds, it comes up with a dependency tree (that can be plotted with `nix build .#info.deps-graph`) that allows compilation of project's Ocaml code to be executed package-by-package.

Then packages are compiled one by one using `dune`, with dependencies of a package built before it and then provided to the package via `OCAMLPATH` environment variable. Code of each package is isolated from its dependencies and packages that depend on it.

A note on building process and treatment of packages. All of the code is build on a package level. That is, for compilation units (executables, libraries, tests) that are assigned to a package, they are compiled with `dune build --only-packages <package>`. Any of dependencies are pre-built the same way and are provided to `dune` via `OCAMLPATH`.

For compilation units that have no package defined, a synthetic package name is generated. Path to dune directory with these units is quoted by replacing `.` with `__` and `/` with `-` in the package path, and also prepending and appending the resulting string with `__`. E.g. for path `src/test/command_line_tests` a synthetic package `__src-test-command_line_tests__` is generated. Such synthetic packages are built with `dune build <path-to-dune-directory>` (isolation is ensured by filtering out all of irrelevant Ocaml sources).

## Examples

Some example CLI commands (to be executed from project's root after integrating the overlay to `flake.nix`):

| Description | Command |
|--------------|-------------|
| Build all Ocaml code, run "default" tests | `nix build .` |
| Build all Ocaml code and run all unit tests | `nix build .#all-tested` |
| Build all Ocaml code without running tests | `nix build .#all` |
| Build `mina_lib` package | `nix build .#pkgs.mina_lib` |
| Build `mina_net2` package and run its tests | `nix build .#tested.mina_net2` |
| Build `validate_keypair` executable | `nix build .#exes.validate_keypair` |
| Run tests from `src/lib/staged_ledger/test` | `nix build .#tested.__src-lib-staged_ledger-test__` |
| Plot dependencies of package `mina_lib` | `nix build .#info.deps-graphs.mina_lib` |
| Plot dependency graph of dune project | `nix build .#info.deps-graph` |
| Extract json description of dependencies | `nix build .#info.deps` |

Dependency description generated via `nix build .#info.deps --out-link deps.json` is useful for investigation of depencies in a semi-automated way. E.g. to check which executables implicitly depend on `mina_lib`, just run the following `jq` command:

```bash
$ jq '[.units | to_entries | .[] | { key: .key, value: [ .value.exe? | to_entries? | .[]? | select(.value.pkgs? | contains(["mina_lib"])?) | .key ] } | select (.value != []) | .key ]' <deps.json
[
  "__src-app-batch_txn_tool__",
  "__src-app-graphql_schema_dump__",
  "__src-app-test_executive__",
  "cli",
  "zkapp_test_transaction"
]
```

## Combined derivations

Derivations that combine all packages: all of the Ocaml code is built, three options vary in which unit tests are executed.

- `#all`
  - builds all the Ocaml code discovered in the dune root (libraries, executables, tests)
  - tests aren't executed
- `#default`
  - `#all` + running default tests
- `#all-tested`
  - `#all` + running all discovered tests
  - discovery of tests is done by finding `test` stanzas and libraries with `inline_tests` stanza

## Individual compilation units

These allow every package to be compiled/tested in isolation, without requiring all of the other packages to be built (except for dependencies, of course).

- `#pkgs.<package>`
  - takes sources of the package and builds it with `dune build <package>`
  - all library dependencies are provided via `OCAMLPATH`
  - derivation contains everything from the `_build` directory
- `#src.pkgs.<package>`
  - show sources of a package (and some relevant files, like `dune` from the parent directory), as filtered for building the `#pkgs.<package>`
- `#files.<path>`
  - build all file rules in the `<path>` used by stanzas in other directories
  - defined only for generated files that are used outside `<path>/dune` scope
- `#src.files.<path>`
  - source director used for building `#files.<path>`
- `#tested.<package>`
  - same as `#pkgs.<package>`, but also runs tests for the package
  - note that tests for package's dependencies aren't executed

There are also a few derivations that help build a particular executable. These are merely shortcuts for building a package with an executable and then copying the executable to another directory.

- `#all-exes.<package>.<exe>`
  - builds a derivation with a single file `bin/<exe>` that is executable with name `<exe>` from package `<package>`
  - when a public name is available, `<exe>` stands for executable's public name (and private name otherwise)
- `#exes.<exe>`
  - shortcut for `#all-exes.<package>.<exe>`
  - if `<exe>` is defined for multiple packages, error is printed
  - if `<exe>` is defined in a single package `<pkg>`, it's same as `#all-exes.<pkg>.<exe>`

## Metadata/debug information

- `#info.src`
  - mapping from dune directory path `dir` to metadata related to files outside of dune directory that is needed for compilation
  - in particular the following fields:
     - `subdirs`, containing list of file paths (relative to the `dir`) that contain dune files with compilation units
     - `file_deps`, containing list of file paths from other dirs which should be included into source when compiling units from `dir` (e.g. some top-level `dune` files which use `env` stanza)
     - `file_outs`, containing a mapping from absolute path of a file generated by some `rule` stanza of the dune file to type of this file output (for type being one of `promote`, `standard` and `fallback`)
- `#info.exe`
  - mapping from executable path (in format like `src/app/archive/archive.exe`) to an object with fields `name` and `package`
  - `package` field contains name of the package that declares the executable
  - `name` is either `public_name` of executable (if defined) or simply `name`
- `#info.package`
  - mapping from package name to an object containing information about all of the units defined by the package
  - object schema is the following:
     ```
     { exe | lib | test : { public_name: string (optional), name: string, src: string, type: exe | lib | test, deps: [string] }
     ```
  - this object contains raw data extracted from dune files
  - `deps` contains opam library names exactly as defined by dune (ppx-related libraries are concatenated to `libraries`)
- `#info.separated-libs`
  - when there is a package-to-package circular dependency, this would be a non-empty object in the format similar to `#info.deps` containing information about edges in dependency graph that form a cycle
  - useful for debugging when an error `Package ${pkg} has separated lib dependency to packages` which may occur after future edits to dune files
- `#info.deps`
  - mapping from files and units to their dependencies
  - external dependencies (defined outside of repository) are ignored
  - schema:
     ```
     { files: { <path> : { exes: { <package> : [<exe>] } } },
       units: { <package> : { exe | lib | test : { <name> : { 
          exes: { <package> : <exe> },
          files: [<dune dir path>],
          libs: { <package> : [<lib name>] },
          pkgs: [ <package> ]
       } } 
     }
     ```
- `#dune-description`
  - raw description of dune files as parsed by [o1-labs/describe-dune](https://github.com/o1-labs/describe-dune) tool
- `#base-libs`
  - a derivation that builds an opam repo-like file structure with all of the dependencies from `opam.export` (plus some extra opam packages for building)

## Dependency graphs

- `#info.deps-graph`
  - generates a dot graph of all packages in the dune project
  - see [example](https://drive.google.com/file/d/1G_8REbd4-rKJpWBkNOFI4P6_3sWAp2io/view?usp=sharing) (after generating an svg with `nix build .#info.deps-graph --out-link all.dot && dot -Tsvg -o all.svg all.dot`)
- `#info.deps-graphs.<package>`
  - plots package dependencies for the `<package>`

Here's example of graph generated:

![Dependencies of mina_wire_types](https://storage.googleapis.com/o1labs-doc-images/mina_wire_types_dep_diagram.png)

Note that there are a few details of this graph. Graph generated for a package `p` displays may omit some of transitive dependencies of a dependency package if they're formed by units on which `p` has no dependency itself. And dependencies `A -> B` and `B -> C` do not always imply `A -> C`: package `B` may have a test dependent on package `C`, but `A` doesn't depend on that tests, only libraries it uses.

True meaning of this graph is that one can build package by package following edges backwards, building all of the units of a package all at once on each step. Interpretation of a graph for dependency analysis is handy, just it's useful to keep in mind certain details.
