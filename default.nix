{ config, lib, pkgs, ... }:
let
  cfg = config.services.friendica;
  inherit (lib) mkIf mkMerge mkOption types;
  inherit (pkgs) stdenvNoCC;
  php = pkgs.php.buildEnv {
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
  };
  version = "2024.12";
  addons = pkgs.fetchFromGitHub {
    owner = "friendica";
    repo = "friendica-addons";
    rev = version;
    hash = "sha256-nv1BRuFK99QEN/2gTfUIlTKvHP5Dulio1Ct6bH9PkZ8=";
  };
  friendica = pkgs.callPackage ./friendica-src-with-deps.nix {
    inherit php version;
    outputHash = "sha256-5j2ZV5CNpOPc29q2BwWTGfIMOmnHNa706wrsi9b6ovQ=";
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
  # symlinks them to paths in cfg.stateDir, which will be created by
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
    popd
    cp $configFile $out/config/local.config.php
    ln -s ${cfg.stateDir}/log $out/log
    mkdir $out/addon
    for a in $addons/*
    do
      ln -s "$a" $out/addon/$(basename "$a")
    done
    for a in ${lib.strings.concatStringsSep " " cfg.addonsFromStateDir}
    do
      ln -s ${cfg.stateDir}/addon/"$a" $out/addon/"$a"
    done
  '';
  # set it to a writable path if you want to modify the code after deployment
  # (you'll have to copy it from friendicaRoot yourself in that case)
  documentRoot = friendicaRoot;
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
        description = "Where to find SSL certificates. Expects $sslDir/$virtualHost.crt and $sslDir/$virtualHost.key to be readable by the web server.";
      };
      user = mkOption {
        type = types.str;
        default = "friendica";
        description = "The code runs as this user, and this is also the user created on the database.";
      };
      group = mkOption {
        type = types.str;
        default = "friendica";
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
      addonsFromStateDir = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Addons to be read from the state directory. If set, the webserver user
          will be added to `cfg.group` and the permissions of `cfg.stateDir`
          will be set to allow access.
        '';
      };
    };
  };
  config = mkIf cfg.enable (mkMerge [
    {
      services.phpfpm.pools.friendica = {
        user = cfg.user;
        group = cfg.group;
        settings = {
          "listen.owner" = config.services.httpd.user;
          # copied from https://wiki.nixos.org/wiki/Phpfpm
          "pm" = "dynamic";
          "pm.max_children" = 32;
          "pm.max_requests" = 500;
          "pm.start_servers" = 2;
          "pm.min_spare_servers" = 2;
          "pm.max_spare_servers" = 5;
          "php_admin_value[error_log]" = "stderr";
          "php_admin_flag[log_errors]" = true;
          "catch_workers_output" = true;
        };
        phpEnv.PATH = lib.makeBinPath [ php pkgs.bash pkgs.which ];
        phpPackage = php;
      };
      services.httpd = {
        enable = true;
        extraModules = [ "proxy" "proxy_fcgi" ];
        virtualHosts.${cfg.virtualHost} = {
          forceSSL = true;
          enableACME = false;
          sslServerCert = "${cfg.sslDir}/${cfg.virtualHost}.crt";
          sslServerKey = "${cfg.sslDir}/${cfg.virtualHost}.key";
          inherit documentRoot;
          extraConfig = let
              # This is annoying to get right. We want static media to be served
              # by Apache, and other stuff to be forwarded to Friendica.
              # We characterise static media as "has a file extension, except
              # for .pcss", and a file extension means a dot in the last path
              # component. (Just matching a dot anywhere doesn't work because
              # stuff under .well-known/ is handled by Friendica).
              toProxy = "^((?:.*/)*[^.]*(?:\.pcss)?)$";
            in ''
            <Directory "${cfg.stateDir}">
              Options FollowSymLinks
              AllowOverride None
              Require all granted
            </Directory>
            RewriteEngine on
            RewriteRule "(^|/)\.git" - [F]
            RewriteCond "${documentRoot}/%{REQUEST_URI}" !-f
            RewriteRule "${toProxy}" unix:${config.services.phpfpm.pools.friendica.socket}|fcgi://127.0.0.1:9000${documentRoot}/index.php?pagename=$1 [E=HTTP_AUTHORIZATION:%{HTTP:Authorization},L,QSA,B,P]
          '';
        };
      };
      users.users.${cfg.user} = {
        isSystemUser = true;
        createHome = true;
        home = cfg.stateDir;
        group = cfg.group;
        # not sure if this matters
        useDefaultShell = true;
      };
      users.groups.${cfg.group} = {
        members =
          lib.optional
            (cfg.addonsFromStateDir != [])
            config.services.httpd.user;
      };
      systemd.services."friendica-setup" =
        let
          grantHttpdAccessToAddon =
            lib.optionalString (cfg.addonsFromStateDir != []) ''
              chmod g+x ~
              chmod -R g+rX ~/addon
            '';
        in {
        # friendica uses shell_exec('which ' . $phppath)
        path = [ pkgs.bash php pkgs.which ];
        script = ''
          ${grantHttpdAccessToAddon}
          [ -d ~/log ] || mkdir -m 700 -p ~/log
          [ -d ~/view/smarty3 ] || mkdir -m 700 -p ~/view/smarty3
          if [ -z "$(echo "SHOW TABLES" | ${config.services.mysql.package}/bin/mysql friendica)" ]
          then
            cd ${friendicaRoot}
            bash bin/console dbstructure update
          fi
        '';
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
        };
        wantedBy = [ "httpd.service" ];
      };
      systemd.services."friendica-worker" = {
        path = [ php ];
        script = "php bin/worker.php";
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          WorkingDirectory = "${friendicaRoot}";
        };
        wants = [ "friendica-setup.service" ];
      };
      systemd.timers."friendica-worker" = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnActiveSec = "0";
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
    }
  ]);
}
