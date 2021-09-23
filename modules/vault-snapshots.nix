{ config, pkgs, lib, ... }:

let
  inherit (lib) mkIf mkEnableOption mkOption types;
  inherit (types) addCheck bool int str submodule;

  cfg = config.services.vault-snapshots;

  snapshotJobConfig = submodule {
    options = {
      enable = mkOption {
        type = bool;
        default = true;
        description = ''
          Creates a systemd service and timer to automatically save Vault snapshots.
        '';
      };

      backupCount = mkOption {
        type = addCheck int (x: x >= 0);
        default = null;
        description = ''
          The number of snapshots to keep.  A sensible value matched to the onCalendar
          interval parameter should be used.  Examples of sensible suggestions may be:

            168 backupCount for "hourly" interval (1 week of backups)
            30  backupCount for "daily" interval (1 month of backups)
        '';
      };

      backupDirPrefix = mkOption {
        type = str;
        default = "/var/lib/private/vault/snapshots";
        description = ''
          The top level location to store the snapshots.  The actual storage location
          of the files will be this prefix path with the snapshot job name appended,
          where the job is one of "hourly", "daily" or "custom".

          Therefore, saved snapshot files will be found at:

            $backupDirPrefix/$job/*.snap
        '';
      };

      backupSuffix = mkOption {
        type = addCheck str (x: x != "");
        default = null;
        description = ''
          Sets the saved snapshot filename with a descriptive suffix prior to the file
          extension.  This will enable selective snapshot job pruning.  The form is:

            vault-$(hostname)-$(date +"%Y-%m-%d_%H%M%SZ")-$backupSuffix.snap
        '';
      };

      fixedRandomDelay = mkOption {
        type = bool;
        default = true;
        description = ''
          Makes randomizedDelaySec fixed between service restarts if true.
          This will reduce jitter and allow the interval to remain fixed,
          while still allowing start time randomization to avoid leader overload.
        '';
      };

      includeLeader = mkOption {
        type = bool;
        default = true;
        description = ''
          Whether to include the leader in the servers which will save snapshots.
          This may reduce load on the leader slightly, but by default snapshot
          saves are proxied through the leader anyway.

          Reducing leader load from snapshots may be best done by fixed time
          snapshot randomization so snapshot concurrency remains 1.
        '';
      };

      interval = mkOption {
        type = addCheck str (x: x != "");
        default = null;
        description = ''
          The default onCalendar systemd timer string to trigger snapshot backups.
          Any valid systemd OnCalendar string may be used here.  Sensible
          defaults for backupCount and randomizedDelaySec should match this parameter.
          Examples of sensible suggestions may be:

            hourly: 3600 randomizedDelaySec, 168 backupCount (1 week)
            daily:  86400 randomizedDelaySec, 30 backupCount (1 month)
        '';
      };

      randomizedDelaySec = mkOption {
        type = addCheck int (x: x >= 0);
        default = 0;
        description = ''
          A randomization period to be added to each systemd timer to avoid
          leader overload.  By default fixedRandomDelay will also be true to minimize
          jitter and maintain fixed interval snapshots.  Sensible defaults for
          backupCount and randomizedDelaySec should match this parameter.
          Examples of sensible suggestions may be:

            3600  randomizedDelaySec for "hourly" interval (1 hr randomization)
            86400 randomizedDelaySec for "daily" interval (1 day randomization)
        '';
      };

      owner = mkOption {
        type = str;
        default = "vault:vault";
        description = ''
          The user and group to own the snapshot storage directory and snapshot files.
        '';
      };

      vaultAddress = mkOption {
        type = str;
        default = "https://127.0.0.1:8200";
        description = ''
          The local vault server address, including protocol and port.
        '';
      };
    };
  };

  snapshotTimer = job: {
    partOf = [ "vault-snapshots-${job}.service" ];
    timerConfig = {
      OnCalendar = cfg.${job}.interval;
      RandomizedDelaySec = cfg.${job}.randomizedDelaySec;
      FixedRandomDelay = cfg.${job}.fixedRandomDelay;
      AccuracySec = "1us";
    };
    wantedBy = [ "timers.target" ];
  };

  snapshotService = job: {
    path = with pkgs; [ coreutils curl findutils gawk hostname jq vault-bin ];

    environment = {
      OWNER = cfg.${job}.owner;
      BACKUP_DIR = "${cfg.${job}.backupDirPrefix}/${job}";
      BACKUP_SUFFIX = "-${cfg.${job}.backupSuffix}";
      INCLUDE_LEADER = lib.boolToString cfg.${job}.includeLeader;
      VAULT_ADDR = cfg.${job}.vaultAddress;
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "30s";
      ExecStart = pkgs.writeBashChecked "vault-snapshot-${job}-script" ''
        set -exuo pipefail

        SNAP_NAME="$BACKUP_DIR/vault-$(hostname)-$(date +"%Y-%m-%d_%H%M%SZ''${BACKUP_SUFFIX}").snap"

        applyPerms () {
          TARGET="$1"
          PERMS="$2"

          chown "$OWNER" "$TARGET"
          chmod "$PERMS" "$TARGET"
        }

        checkBackupDir () {
          if [ ! -d "$BACKUP_DIR" ]; then
            mkdir -p "$BACKUP_DIR"
            applyPerms "$BACKUP_DIR" 0700
          fi
        }

        exportToken () {
          VAULT_TOKEN="$(< /run/keys/vault-token)"
          export VAULT_TOKEN
        }

        isNotLeader () {
          [ "$INCLUDE_LEADER" = "true" ] || \
            vault status | jq -e '(.is_self or false) == false'
        }

        isNotRaftStorage () {
          vault status | jq -e '.storage_type != "raft"'
        }

        takeVaultSnapshot () {
          vault operator raft snapshot save "$SNAP_NAME"
          applyPerms "$SNAP_NAME" 0400
        }

        if isNotRaftStorage; then
          echo "Vault storage backend is not raft."
          echo "Ensure the appropriate storage backend is being snapshotted, ex: Consul."
          exit 0
        fi

        export VAULT_ADDR
        exportToken

        if isNotLeader; then
          checkBackupDir
          takeVaultSnapshot
        fi

        find "$BACKUP_DIR" \
          -type f \
          -name "*''${BACKUP_SUFFIX}.snap" \
          -printf "%T@ %p\n" \
          | sort -r -n \
          | tail -n +${toString (cfg.${job}.backupCount + 1)} \
          | awk '{print $2}' \
          | xargs -r rm
      '';
    };
  };

in {
  options = {
    services.vault-snapshots = {
      enable = mkEnableOption ''
        Enable Vault snapshots.

        By default hourly snapshots will be taken and stored for 1 week on each vault server.
        Modify services.vault-snapshots.hourly options to customize or disable.

        By default daily snapshots will be taken and stored for 1 month on each vault server.
        Modify services.vault-snapshots.daily options to customize or disable.

        By default customized snapshots are disabled.
        Modify services.vault-snapshots.custom options to enable and customize.
      '';

      hourly = mkOption {
        type = snapshotJobConfig;
        default = {
          enable = true;
          backupCount = 168;
          backupSuffix = "hourly";
          interval = "hourly";
          randomizedDelaySec = 3600;
        };
      };

      daily = mkOption {
        type = snapshotJobConfig;
        default = {
          enable = true;
          backupCount = 30;
          backupSuffix = "daily";
          interval = "daily";
          randomizedDelaySec = 86400;
        };
      };

      custom = mkOption {
        type = snapshotJobConfig;
        default = {
          enable = false;
          backupSuffix = "custom";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    # Hourly snapshot configuration
    systemd.timers.vault-snapshots-hourly =
      mkIf cfg.hourly.enable (snapshotTimer "hourly");
    systemd.services.vault-snapshots-hourly =
      mkIf cfg.hourly.enable (snapshotService "hourly");

    # Daily snapshot configuration
    systemd.timers.vault-snapshots-daily =
      mkIf cfg.daily.enable (snapshotTimer "daily");
    systemd.services.vault-snapshots-daily =
      mkIf cfg.daily.enable (snapshotService "daily");

    # Custom snapshot configuration
    systemd.timers.vault-snapshots-custom =
      mkIf cfg.custom.enable (snapshotTimer "custom");
    systemd.services.vault-snapshots-custom =
      mkIf cfg.custom.enable (snapshotService "custom");
  };
}
