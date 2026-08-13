import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  title: "Strato",
  description: "Fast, secure, and easy to deploy private cloud platform",
  base: '/strato/',

  // Internal agent-tooling config lives under docs/agents/; keep it out of the published site.
  srcExclude: ['agents/**'],

  themeConfig: {
    // https://vitepress.dev/reference/default-theme-config
    logo: '/logo.svg',

    nav: [
      { text: 'Home', link: '/' },
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'Architecture', link: '/architecture/overview' },
      { text: 'API', link: '/api-reference' },
      { text: 'Deployment', link: '/deployment/overview' }
    ],

    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'What is Strato?', link: '/guide/what-is-strato' },
          { text: 'Getting Started', link: '/guide/getting-started' }
        ]
      },
      {
        text: 'Guides',
        items: [
          { text: 'Instance Metadata', link: '/guide/instance-metadata' },
          { text: 'Graphics Console', link: '/guide/graphics-console' },
          { text: 'Windows Guests', link: '/guide/windows-guests' }
        ]
      },
      {
        text: 'Architecture',
        items: [
          { text: 'Overview', link: '/architecture/overview' },
          { text: 'Control Plane', link: '/architecture/control-plane' },
          { text: 'Agent', link: '/architecture/agent' },
          { text: 'Wire Protocol', link: '/architecture/wire-protocol' },
          { text: 'Frontend', link: '/architecture/frontend' },
          { text: 'Scheduler', link: '/architecture/scheduler' },
          { text: 'Multi-Replica Control Plane', link: '/architecture/multi-replica' },
          { text: 'Networking', link: '/architecture/networking' },
          { text: 'DNS', link: '/architecture/dns' },
          { text: 'Storage', link: '/architecture/storage' },
          { text: 'Distributed Storage (Proposal)', link: '/architecture/distributed-storage' },
          { text: 'Sandboxes', link: '/architecture/sandboxes' },
          { text: 'IAM', link: '/architecture/iam' },
          { text: 'Guest Identity (Proposal)', link: '/architecture/guest-identity' },
          { text: 'Webhooks', link: '/architecture/webhooks' },
          { text: 'Agent Updates', link: '/architecture/agent-updates' }
        ]
      },
      {
        text: 'Architecture Decisions',
        items: [
          { text: 'ADR 0001: Declarative Agent Protocol', link: '/adr/0001-declarative-agent-protocol' },
          { text: 'ADR 0002: Ceph for Distributed Block Storage', link: '/adr/0002-ceph-for-distributed-block-storage' },
          { text: 'ADR 0003: IMDS Chassis Namespace', link: '/adr/0003-imds-chassis-namespace' },
          { text: 'ADR 0004: Cedar for Authorization', link: '/adr/0004-cedar-for-authorization' },
          { text: 'ADR 0005: Agent Drives libvirt', link: '/adr/0005-agent-drives-libvirt-not-qemu' },
          { text: 'ADR 0006: IMDS Session Auth', link: '/adr/0006-imds-session-auth' },
          {
            text: 'ADR 0007: CoreDNS per Chassis Namespace (superseded)',
            link: '/adr/0007-coredns-per-chassis-namespace',
          },
          {
            text: 'ADR 0008: Resolver in the Host Namespace',
            link: '/adr/0008-resolver-in-host-namespace',
          },
          { text: 'Authorization Edge Audit (July 2026)', link: '/architecture/authorization-edge-audit' }
        ]
      },
      {
        text: 'API',
        items: [
          { text: 'API Reference', link: '/api-reference' }
        ]
      },
      {
        text: 'Development',
        items: [
          { text: 'Local Development', link: '/development/local-development' },
          { text: 'End-to-End Testing', link: '/development/e2e-testing' },
          { text: 'Code Review', link: '/development/code-review' },
          { text: 'Troubleshooting Kubernetes', link: '/development/troubleshooting-k8s' }
        ]
      },
      {
        text: 'Deployment',
        items: [
          { text: 'Overview', link: '/deployment/overview' },
          { text: 'Docker Compose', link: '/deployment/docker-compose' },
          { text: 'Kubernetes (Helm)', link: '/deployment/kubernetes' },
          { text: 'Agents', link: '/deployment/agents' },
          { text: 'VM Manifest Cutover', link: '/deployment/vm-manifest-cutover' },
          { text: 'OVN Stable ID Cutover', link: '/deployment/ovn-stable-id-cutover' },
          { text: 'IAM & Permissions', link: '/deployment/iam' },
          { text: 'Health Checks & Zero-Downtime Deploys', link: '/deployment/health-checks' },
          { text: 'Rate Limiting', link: '/deployment/rate-limiting' },
          { text: 'Logging', link: '/deployment/logging' },
          { text: 'Audit Logging', link: '/deployment/audit-logging' },
          { text: 'Shared Signals (SSF)', link: '/deployment/shared-signals' },
          { text: 'Observability', link: '/deployment/observability' }
        ]
      },
      {
        text: 'Debugging',
        items: [
          { text: 'WebAuthn Debugging', link: '/debugging/webauthn' }
        ]
      }
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/samcat116/strato' }
    ],

    search: {
      provider: 'local'
    },

    editLink: {
      pattern: 'https://github.com/samcat116/strato/edit/main/docs/:path',
      text: 'Edit this page on GitHub'
    },

    footer: {
      message: 'Released under the Functional Source License (FSL-1.1-MIT).',
      copyright: 'Copyright © 2025 Strato Contributors'
    }
  }
})
