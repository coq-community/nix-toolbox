# This file is a toolbox file to parse a .nix directory and make
# 1. a nix overlay
# 2. a shell and a build derivation
with builtins;
let
  toolboxDir = ./.;
  get-path = src: f: let local = src + "/.nix/${f}"; in
    if pathExists local then local else ./. + "/.nix/${f}";
in
{
  src ? ./., # provide the current directory
  config-file ? get-path src "config.nix",
  fallback-file ? get-path src "fallback-config.nix",
  nixpkgs-file ? get-path src "nixpkgs.nix",
  shellHook-file ? get-path src "shellHook.sh",
  overlays-dir ? get-path src "overlays",
  coq-overlays-dir ? get-path src "coq-overlays",
  ocaml-overlays-dir ? get-path src "ocaml-overlays",
  ci-matrix ? false,
  config ? {},
  override ? {},
  ocaml-override ? {},
  global-override ? {},
  withEmacs ? false,
  print-env ? false,
  do-nothing ? false,
  update-nixpkgs ? false,
  ci-job ? null,
  ci ? (!isNull ci-job),
  inNixShell ? null
}@args:
let
  optionalImport = f: d:
    if (isPath f || isString f) && pathExists f then import f else d;
  do-nothing = (args.do-nothing or false) || update-nixpkgs || ci-matrix;
  initial = {
    config = (optionalImport config-file (optionalImport fallback-file {}))
              // config;
    nixpkgs = optionalImport nixpkgs-file (throw "cannot find nixpkgs");
    pkgs = import initial.nixpkgs {};
    src = src;
    lib = (initial.pkgs.coqPackages.lib or tmp-pkgs.lib)
          // { diag = f: x: f x x; };
    inherit overlays-dir coq-overlays-dir ocaml-overlays-dir;
    inherit global-override override ocaml-override;
  };
  my-throw = x: throw "Coq nix toolbox error: ${x}";
in
with initial.lib; let
  inNixShell = args.inNixShell or trivial.inNixShell;
  setup = switch initial.config.format [
    { case = "1.0.0";        out = import ./config-parser-1.0.0 initial; }
    { case = x: !isString x; out = my-throw "config.format must be a string."; }
  ] (my-throw "config.format ${initial.config.format} not supported");
  instances = setup.instances;
  selected-instance = instances."${setup.config.select}";
  shellHook = readFile shellHook-file
      + optionalString print-env "\nprintNixEnv; exit"
      + optionalString update-nixpkgs "\nupdateNixpkgsUnstable; exit"
      + optionalString ci-matrix "\nnixTasks; exit";
  jsonTasks = toJSON (attrNames setup.fixed-task);
  jsonTaskSet = toJSON setup.fixed-task;
  jsonTask = toJSON selected-instance.task;
  emacs = with selected-instance.pkgs; emacsWithPackages
    (epkgs: with epkgs.melpaStablePackages; [ proof-general ]);
  emacsInit = ./emacs-init.el;

  jsonSetupConfig = toJSON setup.config;
  jsonCI = toJSON (mapAttrs
    (_: v: mapAttrs (_: x: map (x: x.name) x) v.ci.set)
    setup.instances);

  nix-shell = with selected-instance; this-shell-pkg.overrideAttrs (old: {
    inherit (setup.config) nixpkgs coqproject;
    inherit jsonTask jsonTasks jsonSetupConfig jsonCI jsonTaskSet
            shellHook toolboxDir;

    coq_version = pkgs.coqPackages.coq.coq-version;

    nativeBuildInputs = optionals (!do-nothing)
      (old.propagatedBuildInputs or []) ++
      (with selected-instance.pkgs; [ remarshal ]);

    buildInputs = optionals (!do-nothing)
      (old.buildInputs or []);

    propagatedBuildInputs = optionals (!do-nothing)
      (old.propagatedBuildInputs or []);
  }
  // optionalAttrs withEmacs {
      inherit emacsInit;
      emacsBin = "${emacs}" + "/bin/emacs";
  });

  nix-ci = job: flatten (mapAttrsToList (_: i: i.ci.subpkgs job) instances);
  nix-ci-for = name: job: instances.${name}.ci.subpkgs job;
  nix-default = selected-instance.this-shell-pkg;
  nix-auto = switch-if [
    { cond = inNixShell;  out = nix-shell; }
    { cond = ci == true;  out = nix-ci ci-job; }
    { cond = isString ci; out = nix-ci-for ci ci-job; }
  ] nix-default;
  in
nix-shell.overrideAttrs (o: {
  passthru = (o.passthru or {})
             // { inherit initial setup shellHook;
                  inherit nix-shell nix-default;
                  inherit nix-ci nix-ci-for nix-auto; };
})
