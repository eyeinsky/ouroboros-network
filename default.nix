{ system ? builtins.currentSystem, crossSystem ? null
  # allows to cutomize haskellNix (profiling, see ./nix/ouroboros-network.nix)
, config ? { }
  # allows to override dependencies of the project without modifications,
  # eg. to test build against local checkout of nixpkgs and iohk-nix:
  # nix build -f default.nix cardano-ledger-byron --arg sourcesOverride '{
  #   iohk-nix = ../iohk-nix;
  # }'
, sourcesOverride ? { }
  # pinned version of nixpkgs augmented with overlays (iohk-nix and our packages).
, pkgs ? import ./nix { inherit system crossSystem config sourcesOverride; }
, gitrev ? pkgs.iohkNix.commitIdFromGitRepoOrZero ./.git }:
with pkgs;
with commonLib;
let
  haskellPackages = recRecurseIntoAttrs
    # the Haskell.nix package set, reduced to local packages.
    (selectProjectPackages ouroborosNetworkHaskellPackages);

  coveredProject =
    ouroborosNetworkHaskellPackages.appendModule { coverage = true; };

  haskellPackagesWithTVarCheck = recRecurseIntoAttrs
    (selectProjectPackages ouroborosNetworkHaskellPackagesWithTVarCheck);

  self = {
    inherit haskellPackages network-docs coveredProject;

    inherit (haskellPackages.ouroboros-network.identifier) version;

    # `tests` are the test suites which have been built.
    tests = collectComponents' "tests" haskellPackages;
    # `benchmarks` (only built, not run).
    benchmarks = collectComponents' "benchmarks" haskellPackages;

    libs = collectComponents' "library" haskellPackages;

    exes = collectComponents' "exes" haskellPackages;

    checks = recurseIntoAttrs {
      # `checks.tests` collect results of executing the tests:
      tests = collectChecks' haskellPackages;
      styles = recurseIntoAttrs {
        check-nixfmt = callPackage ./nix/check-nixfmt.nix { };
        check-stylish = callPackage ./nix/check-stylish.nix { };
      };
    };

    nightly-checks.tvar-invariant-checks = recurseIntoAttrs {
      inherit haskellPackagesWithTVarCheck;
      tests = collectChecks' haskellPackagesWithTVarCheck;
    };

    shell = import ./shell.nix {
      inherit pkgs;
      withHoogle = true;
    };
  };
in self
