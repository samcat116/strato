# NixOS Flake Configuration

This repository provides a Nix flake for building and deploying the Strato Agent on NixOS systems.

## Features

- **Declarative Package**: Build the Strato Agent using Nix
- **NixOS Module**: Run the agent as a systemd service with full configuration options
- **Development Shell**: Pre-configured development environment with all dependencies

## Quick Start

### Building the Agent

```bash
# Build the agent package
nix build

# Run the agent directly
nix run

# Enter development shell
nix develop
```

### Using the NixOS Module

Add the Strato flake to your NixOS configuration:

#### Flake-based Configuration

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    strato.url = "github:samcat116/strato";
  };

  outputs = { self, nixpkgs, strato }: {
    nixosConfigurations.your-hostname = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        strato.nixosModules.default
        {
          services.strato-agent = {
            enable = true;
            controlPlaneUrl = "ws://control-plane.example.com:8080/agent/ws";
            logLevel = "info";
            networkMode = "ovn";
            enableKvm = true;
          };
        }
      ];
    };
  };
}
```

#### Traditional Configuration (with Flakes enabled)

```nix
# /etc/nixos/configuration.nix
{ config, pkgs, ... }:

let
  strato = builtins.getFlake "github:samcat116/strato";
in
{
  imports = [
    strato.nixosModules.default
  ];

  services.strato-agent = {
    enable = true;
    controlPlaneUrl = "ws://192.168.1.100:8080/agent/ws";
    qemuSocketDir = "/var/run/qemu";
    logLevel = "info";
    networkMode = "ovn";
    enableKvm = true;
  };
}
```

## Configuration Options

The NixOS module provides the following configuration options:

### `services.strato-agent.enable`
- **Type**: boolean
- **Default**: `false`
- **Description**: Enable the Strato Agent service

### `services.strato-agent.controlPlaneUrl`
- **Type**: string
- **Required**: yes
- **Example**: `"ws://control-plane.example.com:8080/agent/ws"`
- **Description**: WebSocket URL for connecting to the Control Plane

### `services.strato-agent.qemuSocketDir`
- **Type**: string
- **Default**: `"/var/run/qemu"`
- **Description**: Directory where QEMU creates domain sockets for VM communication

### `services.strato-agent.logLevel`
- **Type**: enum
- **Default**: `"info"`
- **Options**: `"trace"`, `"debug"`, `"info"`, `"notice"`, `"warning"`, `"error"`, `"critical"`
- **Description**: Logging level for the agent

### `services.strato-agent.networkMode`
- **Type**: enum or null
- **Default**: `"ovn"`
- **Options**: `"ovn"`, `"user"`
- **Description**: Networking mode - OVN/OVS or user-mode networking

### `services.strato-agent.enableKvm`
- **Type**: boolean or null
- **Default**: `true`
- **Description**: Enable KVM hardware acceleration

### `services.strato-agent.user`
- **Type**: string
- **Default**: `"strato-agent"`
- **Description**: User account under which the agent runs

### `services.strato-agent.group`
- **Type**: string
- **Default**: `"strato-agent"`
- **Description**: Group under which the agent runs

## Development

### Development Shell

The flake provides a development shell with all necessary dependencies:

```bash
nix develop
```

This gives you access to:
- Swift toolchain (version as provided by nixpkgs-unstable)
- QEMU
- OVN/OVS (on Linux)
- glib and other build dependencies

### Building from Source

```bash
# Enter development shell
nix develop

# Build the agent
cd agent && swift build

# Run tests
cd agent && swift test

# Run the agent (requires control plane)
cd agent && swift run StratoAgent --control-plane-url ws://localhost:8080/agent/ws
```

### Using direnv (Optional)

If you use [direnv](https://direnv.net/), create a `.envrc` file:

```bash
use flake
```

Then run `direnv allow` to automatically load the development environment when you enter the directory.

## System Requirements

### Linux (Production)
- NixOS 23.05 or later
- x86_64 or aarch64 architecture
- KVM kernel module support
- Hardware virtualization support (Intel VT-x or AMD-V)

### macOS (Development)
- macOS 14.0 or later
- Apple Silicon or Intel processor
- Hypervisor.framework support

## Networking Setup

### OVN/OVS (Linux, Production)

When `networkMode = "ovn"`, the module automatically:
- Enables Open vSwitch service
- Adds the agent user to necessary groups
- Configures capabilities for network management

### User-mode (macOS/Development)

When `networkMode = "user"`:
- Uses QEMU's built-in SLIRP networking
- No additional network configuration needed
- Limited to outbound connectivity only

## Security

The NixOS module applies security hardening:
- Runs as unprivileged user (`strato-agent`)
- Limited capabilities (`CAP_NET_ADMIN`, `CAP_SYS_ADMIN`)
- Private `/tmp` directory
- Protected system directories
- Device access limited to `/dev/kvm` and `/dev/net/tun`

## Troubleshooting

### Agent won't start

Check the service status:
```bash
systemctl status strato-agent
journalctl -u strato-agent -f
```

### KVM not available

Ensure virtualization is enabled in BIOS and KVM module is loaded:
```bash
lsmod | grep kvm
ls -l /dev/kvm
```

### Network issues with OVN

Check Open vSwitch service:
```bash
systemctl status ovs-vswitchd
ovs-vsctl show
```

### Permission denied for /dev/kvm

Ensure the agent user is in the `kvm` group:
```bash
groups strato-agent
```

## Contributing

When modifying the flake:

1. Test the package builds: `nix build`
2. Test the development shell: `nix develop`
3. Test the NixOS module in a VM:
   ```bash
   nixos-rebuild build-vm -I nixos-config=./test-configuration.nix
   ```
4. Update flake.lock: `nix flake update`

## License

See LICENSE file in the repository root.
