import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  title: "Strato",
  description: "Fast, secure, and easy to deploy private cloud platform",
  base: '/',

  themeConfig: {
    // https://vitepress.dev/reference/default-theme-config
    logo: '/logo.svg',

    nav: [
      { text: 'Home', link: '/' },
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'Architecture', link: '/architecture/overview' },
      { text: 'Deployment', link: '/deployment/overview' }
    ],

    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'What is Strato?', link: '/guide/what-is-strato' },
          { text: 'Getting Started', link: '/guide/getting-started' },
          { text: 'Quick Start', link: '/guide/quick-start' }
        ]
      },
      {
        text: 'Architecture',
        items: [
          { text: 'Overview', link: '/architecture/overview' },
          { text: 'Scheduler', link: '/architecture/scheduler' }
        ]
      },
      {
        text: 'Development',
        items: [
          { text: 'Development with Skaffold', link: '/development/skaffold' },
          { text: 'Migration Guide', link: '/development/migration-guide' },
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
          { text: 'IAM & Permissions', link: '/deployment/iam' },
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
