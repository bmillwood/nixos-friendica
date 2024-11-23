# lib stuff:
{ stdenvNoCC
# packages:
, php, cacert, git, unzip
# required arguments:
, version, outputHash
}:

# we can't use nixpkgs' PHP support for this because the build-local-repo
# plugin that it uses requires composer 2, and friendica is still stuck on
# composer 1, see e.g. https://github.com/friendica/friendica/issues/8583
stdenvNoCC.mkDerivation rec {
  pname = "friendica";
  inherit (version);
  # I really thought this was the default, but it complains if I don't define
  # it
  name = "${pname}-${version}";

  # avoid fetchFromGitHub so that we don't have to specify the output hash for
  # both this *and* the overall derivation
  src = fetchTarball "https://github.com/friendica/friendica/archive/${version}.tar.gz";

  nativeBuildInputs = [
    # these are all used by composer when fetching / unpacking dependencies
    cacert
    git
    unzip
    # arguable whether php is a build-time or run-time dependency, because this
    # derivation isn't really "run" anyway, it mostly just exists to fetch the
    # vendor stuff in a fixed-output derivation. I think it isn't (obviously)
    # important for the php used here to be the same php that is used to
    # actually run friendica, so it seems ok to make it a nativeBuildInput
    php
  ];

  # removing all the .git directories that composer fetches because (AIUI) git
  # will install sample hooks that reference nix store paths, and then we get
  # "illegal path references in fixed-output derivation"
  buildPhase = ''
    php bin/composer.phar install --no-dev
    find . -path '*/.git/*' -delete
  '';

  # to avoid "illegal path references in fixed-output derivation"
  dontPatchShebangs = true;

  # the fixupPhase doesn't do anything we need to do and does some things we
  # don't need (it moves doc to share/doc, unnecessarily, and patches
  # shebangs, which we turn off anyway, see above)
  dontFixup = true;

  # this used to include more custom steps like moving .htaccess-dist to
  # .htaccess and symlinking the addons dir, but I stopped needing that --
  # TODO double check what the default install phase does and if this is now
  # redundant
  installPhase = ''
    mkdir $out
    cp -r . $out/
  '';

  # I'm not confident this derivation really is fixed-output, but it seems to
  # reproduce with the same hash when I try
  inherit outputHash;
  outputHashMode = "recursive";
}
