{ config, lib, pkgs, ... }:
let
  cfg = config.services.friendica;
  inherit (lib) mkIf mkOption types;
  inherit (pkgs) stdenvNoCC;
  php = (pkgs.php.buildEnv {
    extensions = ({ enabled, all }: with all; enabled ++ [
      curl gd gmp pdo mbstring intl mysqli zip openssl imagick
      # friendica docs also ask for hash, but:
      # https://www.php.net/manual/en/hash.installation.php
      # > As of PHP 5.1.2, the Hash extension is bundled and compiled into PHP
      # > by default.
      # friendica's website *doesn't* mention the imagick plugin, but the
      # in-tree docs and friendica's own install checks do (as optional)
      # I'm also supposed to have xml in there, but then I get:
      # PHP Warning:  Module "xml" is already loaded in Unknown on line 0
      # which hits: https://github.com/friendica/friendica/issues/14461
      # I think this was because some other extension automatically loads xml,
      # though I forget which one (maybe dom?)
    ]);
    extraConfig = lib.strings.concatLines [
      # technically we only want this for command-line php, but shrug
      "register_argc_argv = true;"
      "display_errors = Off;"
    ];
  }).override {
    # without doing this override we see:
    # Failed loading /nix/store/...-php-opcache-8.2.24/lib/php/extensions/opcache.so:  /nix/store/...-php-opcache-8.2.24/lib/php/extensions/opcache.so: undefined symbol: zend_signal_globals_offset
    # zend_signal_globals_offset is defined conditionally in PHP based on
    # whether you enabled ZTS:
    # https://github.com/php/php-src/blob/57bfca9045a8b548d322635ddb4d0c7a24735b0d/Zend/zend_signal.c#L47
    # which defaults to apxs2Support in the PHP nix package:
    # https://github.com/NixOS/nixpkgs/blob/d51c28603def282a24fa034bcb007e2bcb5b5dd0/pkgs/development/interpreters/php/generic.nix#L62C9-L62C10
    # we also see that these two overrides are done to your PHP package by the
    # apache httpd nixos module:
    # https://github.com/NixOS/nixpkgs/blob/d51c28603def282a24fa034bcb007e2bcb5b5dd0/nixos/modules/services/web-servers/apache-httpd/default.nix#L21
    # so my guess is that the error is from some mismatch between a non-threaded
    # command line PHP and a threaded apache PHP.
    # with the overrides, we still get this spam in apache error.log:
    # Cannot load Zend OPcache - it was already loaded
    # but that seems less likely to be harmful
    apxs2Support = true;
    apacheHttpd = config.services.httpd.package;
  };
  version = "2024.08";
  addons = pkgs.fetchFromGitHub {
    owner = "friendica";
    repo = "friendica-addons";
    rev = version;
    hash = "sha256-h/WQUngIUEdTnpErWeoFHiJR+fuBBI8z57hY6P78fHE=";
  };
  friendica = pkgs.callPackage ./friendica-src-with-deps.nix {
    inherit php version;
    outputHash = "sha256-Qb79rS1+aNniwlxlYfWYW6uuf69ETxrgqtb6ErF07y0=";
  };
  configFile = pkgs.writeText "local.config.php" ''
    <?php
    return [
      'database' => [
        'socket' => '/run/mysqld/mysqld.sock',
        'username' => '${cfg.user}',
        'database' => 'friendica',
        'charset' => 'utf8mb4',
      ],
      'config' => [
        'admin_email' => '${cfg.adminEmail}',
        'sender_email' => '${cfg.senderEmail}',
        'sitename' => '${cfg.virtualHost}',
        'register_policy' => \Friendica\Module\Register::OPEN,
        'register_text' => "",
        'php_path' => '${php}/bin/php',
      ],
      'system' => [
        # Necessary until you upgrade to a version with the fix for
        # https://github.com/friendica/friendica/pull/14390
        'admin_inactivity_limit' => '0',
        'default_timezone' => '${config.time.timeZone}',
        'language' => 'en',
        'url' => 'https://${cfg.virtualHost}',
      ],
    ];
    ?>
  '';
  # Some paths under the friendica root need to be writable by the server. This
  # symlinks them to paths in the user home directory, which will be created by
  # Apache's pre-start hook.
  friendicaRoot = pkgs.runCommand "friendica-root" {
      inherit addons friendica configFile;
    } ''
    mkdir $out
    pushd $friendica
    find . -false \
      -o -path . \
      -o -path ./view/smarty3 -exec ln -s ${cfg.stateDir}/{} $out/{} \; -prune \
      -o -path ./.htaccess-dist -exec cp {} $out/.htaccess \; \
      -o -type d -exec mkdir $out/{} \; \
      -o -type f -exec cp --reflink=auto {} $out/{} \;
    cp $configFile $out/config/local.config.php
    ln -s ${cfg.stateDir}/log $out/log
    ln -s $addons $out/addon
    popd
  '';
in
{
  options = {
    services.friendica = {
      enable = lib.mkEnableOption "friendica";
      virtualHost = mkOption {
        type = types.str;
        description = "Friendica will be hosted at https://$virtualHost";
      };
      sslDir = mkOption {
        type = types.str;
        description = "Where to find SSL certificates. Expects $sslDir/$virtualHost.crt and $sslDir/$virtualHost.key to be readable by $user.";
      };
      user = mkOption {
        type = types.str;
        default = "friendica";
        description = "The code runs as this user, and this is also the user created on the database.";
      };
      group = mkOption {
        type = types.str;
        # This is because this group has read access to the SSL certs on my
        # system. I'm not sure if it makes sense in general.
        default = "wwwrun";
        description = "Set as the group of $user (e.g. so it can read SSL certs)";
      };
      adminEmail = mkOption {
        type = types.str;
        default = "admin@${cfg.virtualHost}";
        description = "Registering with this e-mail will give you admin access.";
      };
      senderEmail = mkOption {
        type = types.str;
        default = "noreply@${cfg.virtualHost}";
        description = "E-mails from Friendica will be sent using this account.";
      };
      stateDir = mkOption {
        type = types.str;
        default = "/var/lib/friendica";
        description = "Directory where friendica will store file state. Created if it doesn't exist.";
      };
    };
  };
  config = mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      createHome = true;
      home = cfg.stateDir;
      group = cfg.group;
      # not sure if this matters
      useDefaultShell = true;
    };
    services.httpd =
      let
        # this is here to allow easy switching between "have the document root
        # in the nix store" and "have the document root in the home directory,
        # but copy it in from the nix store", where the latter is useful when I
        # want to make changes to the friendica code, usually for debugging
        # reasons
        documentRoot = friendicaRoot;
      in {
      enable = true;
      enablePHP = true;
      phpPackage = php;
      virtualHosts.${cfg.virtualHost} = {
        forceSSL = true;
        enableACME = false;
        sslServerCert = "${cfg.sslDir}/${cfg.virtualHost}.crt";
        sslServerKey = "${cfg.sslDir}/${cfg.virtualHost}.key";
        inherit documentRoot;
        extraConfig = ''
          <Directory "${documentRoot}">
            Options FollowSymlinks
            AllowOverride All
          </Directory>
        '';
        locations."/" = {
          index = "index.php";
        };
      };
      user = cfg.user; # mysql needs this to match the db user
    };
    systemd.services.httpd = {
      # friendica uses shell_exec('which ' . $phppath)
      path = [ pkgs.bash php pkgs.which ];
      preStart = ''
        [ -d ~/log ] || mkdir -p ~/log
        [ -d ~/view/smarty3 ] || mkdir -p ~/view/smarty3
        if [ -z "$(echo "SHOW TABLES" | ${config.services.mysql.package}/bin/mysql friendica)" ]
        then
          cd ${friendicaRoot}
          bash bin/console dbstructure update
        fi
      '';
    };
    systemd.services."friendica-worker" = {
      path = [ php ];
      script = "php bin/worker.php";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        # this should probably be documentRoot instead, but that's not currently
        # available at this scope
        WorkingDirectory = "${friendicaRoot}";
      };
    };
    systemd.timers."friendica-worker" = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnUnitActiveSec = "600";
        Unit = "friendica-worker.service";
      };
    };
    services.mysql = {
      enable = true;
      package = pkgs.mariadb;
      ensureDatabases = [ "friendica" ];
      ensureUsers = [
        {
          name = cfg.user;
          ensurePermissions = {
            "friendica.*" = "ALL PRIVILEGES";
          };
        }
      ];
    };
    warnings =
      if config ? services.mail.sendmailSetuidWrapper.source
      then []
      else [ ''
          Friendica tries to send mail with sendmail. User registration will be
          pretty janky if you don't have one. I don't see a value for
          services.mail.sendmailSetuidWrapper.source, which I think sendmail
          providers usually set, but I'm not certain this is a reliable test.
        '' ];
  };
}
