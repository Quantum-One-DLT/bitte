{ lib, config, pkgs, nodeName, ... }:
let
  inherit (builtins) split typeOf length attrNames;
  inherit (lib)
    mkIf mkEnableOption mkOption flip pipe concatMapStrings isList toLower
    mapAttrs' nameValuePair fileContents filterAttrs hasPrefix mapAttrsToList
    makeBinPath;
  inherit (lib.types) attrs str enum submodule listOf ints nullOr;
  inherit (builtins) toJSON;

  sanitize = obj:
    lib.getAttr (typeOf obj) {
      bool = obj;
      int = obj;
      string = obj;
      str = obj;
      list = map sanitize obj;
      null = null;
      set = if (length (attrNames obj) == 0) then
        null
      else
        pipe obj [
          (filterAttrs
            (name: value: name != "_module" && name != "_ref" && value != null))
          (mapAttrs'
            (name: value: nameValuePair (snakeCase name) (sanitize value)))
        ];
    };

  snakeCase = flip pipe [
    (split "([^a-z])")
    (concatMapStrings (s: if isList s then "_${toString s}" else s))
    toLower
  ];

  toPrettyJSON = name: value:
    let
      json = toJSON value;
      mini = pkgs.writeText "${name}.mini.json" json;
    in pkgs.runCommandNoCCLocal "${name}.json" { } ''
      ${pkgs.jq}/bin/jq -S < ${mini} > $out
    '';

  storageRaftType = submodule {
    options = {
      path = mkOption {
        type = str;
        default = cfg.storagePath;
      };

      nodeId = mkOption {
        type = nullOr str;
        default = null;
      };

      retryJoin = mkOption {
        type = listOf (submodule {
          options = {
            leaderApiAddr = mkOption {
              type = str;
              description = ''
                Address of a possible leader node.
              '';
            };

            leaderCaCertFile = mkOption {
              type = nullOr str;
              default = null;
              description = ''
                File path to the CA cert of the possible leader node.
              '';
            };

            leaderCaCert = mkOption {
              type = nullOr str;
              default = null;
              description = ''
                CA cert of the possible leader node.
              '';
            };

            leaderClientCertFile = mkOption {
              type = nullOr str;
              default = null;
              description = ''
                File path to the client certificate for the follower
                node to establish client authentication with the
                possible leader node.
              '';
            };

            leaderClientCert = mkOption {
              type = nullOr str;
              default = null;
              description = ''
                Client certificate for the follower node to establish
                client authentication with the possible leader node.
              '';
            };

            leaderClientKeyFile = mkOption {
              type = nullOr str;
              default = null;
              description = ''
                File path to the client key for the follower node to
                establish client authentication with the possible
                leader node.
              '';
            };

            leaderClientKey = mkOption {
              type = nullOr str;
              default = null;
              description = ''
                Client key for the follower node to establish client
                authentication with the possible leader node.
              '';
            };
          };
        });
        default = [ ];
      };
    };
  };

  storageConsulType = submodule {
    options = {
      address = mkOption {
        type = nullOr str;
        default = null;
      };

      scheme = mkOption {
        type = nullOr (enum [ "http" "https" ]);
        default = null;
      };

      tlsCaFile = mkOption {
        type = nullOr str;
        default = null;
      };

      tlsCertFile = mkOption {
        type = nullOr str;
        default = null;
      };

      tlsKeyFile = mkOption {
        type = nullOr str;
        default = null;
      };
    };
  };

  cfg = config.services.vault;
in {
  options.services.vault = {
    enable = mkEnableOption "Vault daemon";

    storagePath = mkOption {
      type = str;
      default = "/var/lib/vault";
    };

    configDir = mkOption {
      type = str;
      default = "/vault.d";
    };

    extraConfig = mkOption {
      type = attrs;
      default = { };
    };

    ui = mkEnableOption "Enable web UI";

    logLevel = mkOption {
      type = enum [ "trace" "debug" "info" "warn" "err" ];
      default = "info";
    };

    disableMlock = mkEnableOption "Disable mlock";

    apiAddr = mkOption {
      type = nullOr str;
      default = null;
    };

    clusterAddr = mkOption {
      type = nullOr str;
      default = null;
    };

    storage = mkOption {
      type = submodule {
        options = {
          raft = mkOption {
            type = nullOr storageRaftType;
            default = null;
          };

          consul = mkOption {
            type = nullOr storageConsulType;
            default = null;
          };
        };
      };
    };

    listener = mkOption {
      type = submodule {
        options = {
          tcp = mkOption {
            type = submodule {
              options = {
                address = mkOption {
                  type = str;
                  default = "";
                };

                clusterAddress = mkOption {
                  type = str;
                  default = "";
                };

                tlsClientCaFile = mkOption {
                  type = str;
                  default = "";
                };

                tlsCertFile = mkOption {
                  type = str;
                  default = "";
                };

                tlsKeyFile = mkOption {
                  type = str;
                  default = "";
                };

                tlsMinVersion = mkOption {
                  type = enum [ "tls10" "tls11" "tls12" "tls13" ];
                  default = "tls12";
                };
              };
            };
            default = { };
          };
        };
      };
      default = { };
    };

    seal = mkOption {
      type = submodule {
        options = {
          awskms = mkOption {
            type = submodule {
              options = {
                kmsKeyId = mkOption { type = str; };
                region = mkOption { type = str; };
              };
            };
          };
        };
      };
      default = { };
    };

    serviceRegistration = mkOption {
      type = nullOr (submodule {
        options = {
          consul = mkOption {
            type = nullOr (submodule {
              options = {
                address = mkOption {
                  type = nullOr str;
                  default = null;
                };

                scheme = mkOption {
                  type = nullOr (enum [ "http" "https" ]);
                  default = null;
                };

                tlsClientCaFile = mkOption {
                  type = nullOr str;
                  default = null;
                };

                tlsCertFile = mkOption {
                  type = nullOr str;
                  default = null;
                };

                tlsKeyFile = mkOption {
                  type = nullOr str;
                  default = null;
                };
              };
            });
            default = null;
          };
        };
      });
      default = null;
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.vault-bin ];

    environment.etc."${cfg.configDir}/config.json".source =
      toPrettyJSON "config.json" (sanitize {
        inherit (cfg)
          serviceRegistration ui logLevel disableMlock apiAddr clusterAddr seal
          listener storage;
      });

    environment.etc."${cfg.configDir}/extra-config.json".source =
      toPrettyJSON "extra-config.json" cfg.extraConfig;

    systemd.services.vault = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "consul.service" ];

      restartTriggers = mapAttrsToList (_: d: d.source)
        (filterAttrs (n: _: hasPrefix "${cfg.configDir}/" n)
          config.environment.etc);

      unitConfig.RequiresMountsFor = [ cfg.storagePath ];

      serviceConfig = {
        ExecStartPre = let
          start-pre = pkgs.writeShellScriptBin "vault-start-pre" ''
            PATH="${makeBinPath [ pkgs.coreutils ]}"
            set -exuo pipefail
            chown --reference . --recursive .
          '';
        in "!${start-pre}/bin/vault-start-pre";

        ExecStart =
          "@${pkgs.vault-bin}/bin/vault vault server -config /etc/${cfg.configDir}";

        ExecReload = "${pkgs.coreutils}/bin/kill -SIGHUP $MAINPID";
        KillSignal = "SIGINT";

        StateDirectory = baseNameOf cfg.storagePath;
        WorkingDirectory = cfg.storagePath;

        DynamicUser = true;
        User = "vault";
        Group = "vault";

        LimitMEMLOCK = "infinity";
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectSystem = "full";
        ProtectHome = "read-only";
        AmbientCapabilities = "cap_ipc_lock";
        NoNewPrivileges = true;

        TimeoutStopSec = "30s";
        RestartSec = "30s";
        Restart = "on-failure";
        StartLimitInterval = "60s";
        StartLimitBurst = 3;
      };
    };

    systemd.services.vault-consul-token = {
      after = [ "consul.service" ];
      requires = [ "consul.service" ];
      wantedBy = [ "vault.service" ];
      before = [ "vault.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "30s";
      };

      path = with pkgs; [ consul curl jq ];

      script = ''
        set -exuo pipefail

        [ -s /etc/vault.d/consul-tokens.json ] && exit

        if [ -s /etc/consul.d/master-token.json ]; then
          CONSUL_HTTP_TOKEN="$(jq -e -r .acl.tokens.master /etc/consul.d/master-token.json)"
          export CONSUL_HTTP_TOKEN

          vaultToken="$(
            consul acl token create \
              -policy-name=vault-server \
              -description "vault-server ${nodeName} $(date +%Y-%m-%d-%H-%M-%S)" \
              -format json \
            | jq -e -r .SecretID
          )"

          echo '{}' \
          | jq --arg token "$vaultToken" '.storage.consul.token = $token' \
          | jq --arg token "$vaultToken" '.service_registration.consul.token = $token' \
          > /etc/vault.d/consul-tokens.json.new

          mv /etc/vault.d/consul-tokens.json.new /etc/vault.d/consul-tokens.json
        fi
      '';
    };

    systemd.services.vault-aws-addr = {
      wantedBy = [ "vault.service" ];
      before = [ "vault.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "30s";
      };

      path = with pkgs; [ curl jq ];

      script = ''
        set -exuo pipefail

        ip="$(curl -f -s http://169.254.169.254/latest/meta-data/local-ipv4)"
        addr="https://$ip"
        echo '{"cluster_addr": "'"$addr:8201"'", "api_addr": "'"$addr:8200"'"}' \
        | jq -S . \
        > /etc/vault.d/address.json
      '';
    };
  };
}
