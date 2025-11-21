import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  title: "Strato",
  description: "Fast, secure, and easy to deploy private cloud platform",
  base: '/strato/',

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
          { text: 'IAM & Permissions', link: '/deployment/iam' }
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
      message: 'Released under the ISC License.',
      copyright: 'Copyright © 2025 Strato Contributors'
    }
  }
})
