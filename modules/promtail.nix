{ pkgs, lib, config, ... }:
let
  inherit (lib) mkIf mkEnableOption mkOption;
  inherit (lib.types) undefined attrsOf submodule port;
  cfg = config.services.promtail;

  configJson = pkgs.toPrettyJSON "promtail" {
    server = {
      http_listen_port = cfg.server.http_listen_port;
      grpc_listen_port = cfg.server.grpc_listen_port;
    };

    clients = [{
      url =
        "http://${config.cluster.instances.monitoring.privateIP}:3100/loki/api/v1/push";
    }];

    positions = { filename = "/var/lib/promtail/positions.yaml"; };

    scrape_configs = [
      {
        ec2_sd_configs = [{ region = config.cluster.region; }];

        job_name = "ec2-logs";

        relabel_configs = [
          {
            action = "replace";
            source_labels = [ "__meta_ec2_tag_Name" ];
            target_label = "name";
          }
          {
            action = "replace";
            source_labels = [ "__meta_ec2_instance_id" ];
            target_label = "instance";
          }
          {
            action = "replace";
            source_labels = [ "__meta_ec2_availability_zone" ];
            target_label = "zone";
          }
          {
            action = "replace";
            replacement = "/var/log/**.log";
            target_label = "__path__";
          }
          {
            regex = "(.*)";
            source_labels = [ "__meta_ec2_private_dns_name" ];
            target_label = "__host__";
          }
        ];
      }
      {
        job_name = "journal";
        journal = {
          json = false;
          labels = {
            job = "systemd-journal";
            region = config.cluster.region;
          };
          max_age = "12h";
          path = "/var/log/journal";
        };
        relabel_configs = [
          {
            source_labels = [ "__journal__systemd_unit" ];
            target_label = "unit";
          }
          {
            source_labels = [ "__journal__hostname" ];
            target_label = "host";
          }
          {
            source_labels = [ "__journal_syslog_identifier" ];
            target_label = "syslog_identifier";
          }
          {
            source_labels = [ "__journal_container_tag" ];
            target_label = "container_tag";
          }
          {
            source_labels = [ "__journal_namespace" ];
            target_label = "namespace";
          }
          {
            source_labels = [ "__journal_container_name" ];
            target_label = "container_name";
          }
          {
            source_labels = [ "__journal_image_name" ];
            target_label = "image_name";
          }
        ];
      }
    ];
  };
in {
  options = {
    services.promtail = {
      enable = mkEnableOption "Enable Promtail";

      server = mkOption {
        default = { };
        type = submodule {
          options = {
            http_listen_port = mkOption {
              type = port;
              default = 3101;
            };

            grpc_listen_port = mkOption {
              type = port;
              default = 0;
            };
          };
        };
      };
    };
  };

  config = mkIf cfg.enable {
    systemd.services.promtail = {
      description = "Promtail service for Loki";
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart =
          "${pkgs.grafana-loki}/bin/promtail --config.file ${configJson}";
        Restart = "on-failure";
        RestartSec = "20s";
        SuccessExitStatus = 143;
        StateDirectory = "promtail";
        # DynamicUser = true;
        # User = "promtail";
        # Group = "promtail";
      };
    };
  };
}
