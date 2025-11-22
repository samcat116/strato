{
  description = "Strato - Distributed Private Cloud Platform";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # NixOS module - only available on Linux systems
      nixosModule = { config, lib, pkgs, ... }:
        let
          cfg = config.services.strato-agent;
          configFile = pkgs.writeText "strato-agent-config.toml" ''
            control_plane_url = "${cfg.controlPlaneUrl}"
            qemu_socket_dir = "${cfg.qemuSocketDir}"
            log_level = "${cfg.logLevel}"
            ${lib.optionalString (cfg.networkMode != null) ''network_mode = "${cfg.networkMode}"''}
            ${lib.optionalString (cfg.enableKvm != null) ''enable_kvm = ${if cfg.enableKvm then "true" else "false"}''}
          '';
        in
        {
          options.services.strato-agent = {
            enable = lib.mkEnableOption "Strato Agent";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.strato-agent;
              defaultText = lib.literalExpression "self.packages.\${pkgs.system}.strato-agent";
              description = "The Strato Agent package to use.";
            };

            controlPlaneUrl = lib.mkOption {
              type = lib.types.str;
              example = "ws://control-plane.example.com:8080/agent/ws";
              description = "WebSocket URL for connecting to the Control Plane (required).";
            };

            qemuSocketDir = lib.mkOption {
              type = lib.types.str;
              default = "/var/run/qemu";
              description = "Directory where QEMU will create domain sockets for VM communication.";
            };

            logLevel = lib.mkOption {
              type = lib.types.enum [ "trace" "debug" "info" "notice" "warning" "error" "critical" ];
              default = "info";
              description = "Logging level for the agent.";
            };

            networkMode = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum [ "ovn" "user" ]);
              default = "ovn";
              description = "Networking mode: 'ovn' for OVN/OVS, 'user' for user-mode networking.";
            };

            enableKvm = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = true;
              description = "Enable KVM hardware acceleration.";
            };

            user = lib.mkOption {
              type = lib.types.str;
              default = "strato-agent";
              description = "User account under which the agent runs.";
            };

            group = lib.mkOption {
              type = lib.types.str;
              default = "strato-agent";
              description = "Group under which the agent runs.";
            };
          };

          config = lib.mkIf cfg.enable {
            # Ensure required system packages are available
            environment.systemPackages = with pkgs; [
              qemu_kvm
              openvswitch
              ovn
            ];

            # Create user and group for the agent
            users.users.${cfg.user} = {
              isSystemUser = true;
              group = cfg.group;
              description = "Strato Agent service user";
              extraGroups = [ "kvm" "libvirtd" ];
            };

            users.groups.${cfg.group} = {};

            # Ensure QEMU socket directory exists
            systemd.tmpfiles.rules = [
              "d ${cfg.qemuSocketDir} 0755 ${cfg.user} ${cfg.group} -"
            ];

            # Enable KVM module
            boot.kernelModules = lib.mkIf cfg.enableKvm [ "kvm-intel" "kvm-amd" ];

            # Enable OVN/OVS services
            virtualisation.openvswitch.enable = lib.mkIf (cfg.networkMode == "ovn") true;

            # Systemd service for the agent
            systemd.services.strato-agent = {
              description = "Strato Hypervisor Agent";
              after = [ "network.target" ] ++ lib.optional (cfg.networkMode == "ovn") "ovs-vswitchd.service";
              wants = [ "network-online.target" ] ++ lib.optional (cfg.networkMode == "ovn") "ovs-vswitchd.service";
              wantedBy = [ "multi-user.target" ];

              serviceConfig = {
                Type = "simple";
                User = cfg.user;
                Group = cfg.group;
                ExecStart = "${cfg.package}/bin/StratoAgent --config-file ${configFile}";
                Restart = "on-failure";
                RestartSec = "10s";

                # Security hardening
                NoNewPrivileges = true;
                PrivateTmp = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                ReadWritePaths = [ cfg.qemuSocketDir "/var/lib/strato" ];

                # Capabilities needed for VM management
                AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_SYS_ADMIN" ];
                CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_SYS_ADMIN" ];

                # Allow access to /dev/kvm
                DeviceAllow = [ "/dev/kvm rw" "/dev/net/tun rw" ];
              };
            };
          };
        };
    in
    {
      # NixOS module
      nixosModules.default = nixosModule;
      nixosModules.strato-agent = nixosModule;
    } //
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Build the Strato agent package
        strato-agent = pkgs.stdenv.mkDerivation {
          pname = "strato-agent";
          version = "0.1.0";

          src = ./.;

          nativeBuildInputs = with pkgs; [
            swift
            swiftpm
            swiftpm2nix
          ];

          buildInputs = with pkgs; [
            Foundation
            glib
            qemu
          ] ++ lib.optionals stdenv.isLinux [
            openvswitch
            ovn
          ];

          configurePhase = ''
            # Swift Package Manager setup
            export HOME=$TMPDIR
          '';

          buildPhase = ''
            # Build the agent
            cd agent
            swift build -c release --product StratoAgent
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp .build/release/StratoAgent $out/bin/
          '';

          meta = with pkgs.lib; {
            description = "Strato Hypervisor Agent - manages VMs on hypervisor nodes";
            homepage = "https://github.com/samcat116/strato";
            license = licenses.mit;
            platforms = platforms.linux ++ platforms.darwin;
            maintainers = [];
          };
        };

      in
      {
        packages = {
          default = strato-agent;
          strato-agent = strato-agent;
        };

        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            swift
            swiftpm
            qemu
            glib
            pkg-config
          ] ++ lib.optionals stdenv.isLinux [
            openvswitch
            ovn
            libvirt
          ];

          shellHook = ''
            echo "Strato Agent Development Environment"
            echo "Swift version: $(swift --version | head -n1)"
            echo ""
            echo "Available commands:"
            echo "  cd agent && swift build          - Build the agent"
            echo "  cd agent && swift test           - Run tests"
            echo "  cd agent && swift run StratoAgent - Run the agent"
            echo ""
          '';
        };

        # Checks
        checks = {
          build = strato-agent;
        };
      }
    );
}
