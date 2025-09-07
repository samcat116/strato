import Elementary
import ElementaryHTMX
import Vapor

struct LoginTemplate: HTMLDocument {
    var title = "Login - Strato"
    var oidcProviders: [OIDCProviderInfo]

    init(oidcProviders: [OIDCProviderInfo] = []) {
        self.oidcProviders = oidcProviders
    }

    var head: some HTML {
        meta(.charset("utf-8"))
        meta(.name("viewport"), .content("width=device-width, initial-scale=1.0"))
        link(.rel("icon"), .href("/favicon.svg"))
        link(.rel("icon"), .href("/favicon.ico"))
        link(.rel("stylesheet"), .href("/styles/app.generated.css"))
        script(.src("https://unpkg.com/htmx.org@1.9.10/dist/htmx.min.js")) { "" }
        script(.src("/js/webauthn.js")) { "" }
    }

    var body: some HTML {
        LoginPageContainer(oidcProviders: oidcProviders)
        LoginPageScript()
    }
}

struct OIDCProviderInfo {
    let providerID: UUID
    let providerName: String
    let organizationID: UUID
    let organizationName: String
}

struct LoginPageContainer: HTML {
    let oidcProviders: [OIDCProviderInfo]

    var content: some HTML {
        div(.class("bg-gray-100 min-h-screen flex items-center justify-center")) {
            div(.class("max-w-md w-full space-y-8")) {
                LoginHeader()
                LoginContent(oidcProviders: oidcProviders)
            }
        }
    }
}

struct LoginHeader: HTML {
    var content: some HTML {
        div {
            h2(.class("mt-6 text-center text-3xl font-extrabold text-gray-900")) {
                "Sign in to Strato"
            }
            p(.class("mt-2 text-center text-sm text-gray-600")) {
                "Use your Passkey for secure, passwordless authentication"
            }
        }
    }
}

struct LoginContent: HTML {
    let oidcProviders: [OIDCProviderInfo]

    var content: some HTML {
        div(.class("mt-8 space-y-6")) {
            if !oidcProviders.isEmpty {
                OIDCSection(oidcProviders: oidcProviders)
                DividerSection()
            }

            LoginFormSection()
            LoginFallbackSection()
            RegisterLinkSection()
        }
    }
}

struct OIDCSection: HTML {
    let oidcProviders: [OIDCProviderInfo]

    var content: some HTML {
        div(.class("space-y-3")) {
            ForEach(oidcProviders) { provider in
                OIDCButton(provider: provider, showOrg: oidcProviders.count > 1)
            }
        }
    }
}

struct OIDCButton: HTML {
    let provider: OIDCProviderInfo
    let showOrg: Bool

    var content: some HTML {
        a(
            .href("/auth/oidc/\(provider.organizationID)/\(provider.providerID)/authorize"),
            .class("group relative w-full flex justify-center py-2 px-4 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500")
        ) {
            "🏢 Sign in with \(provider.providerName)"
            if showOrg {
                span(.class("text-xs text-gray-500 ml-2")) {
                    "(\(provider.organizationName))"
                }
            }
        }
    }
}

struct DividerSection: HTML {
    var content: some HTML {
        div(.class("relative")) {
            div(.class("absolute inset-0 flex items-center")) {
                div(.class("w-full border-t border-gray-300")) {}
            }
            div(.class("relative flex justify-center text-sm")) {
                span(.class("bg-gray-100 px-2 text-gray-500")) {
                    "or continue with"
                }
            }
        }
    }
}

struct RegisterLinkSection: HTML {
    var content: some HTML {
        div(.class("text-center")) {
            a(.href("/register"), .class("text-indigo-600 hover:text-indigo-500")) {
                "Don't have an account? Sign up"
            }
        }
    }
}

struct LoginFormSection: HTML {
    var content: some HTML {
        div(.class("bg-white p-6 rounded-lg shadow passkey-only")) {
            div(.class("space-y-4")) {
                UsernameField()
                PasskeyButtons()
                div(.id("loginStatus"), .class("mt-4")) {}
            }
        }
    }
}

struct UsernameField: HTML {
    var content: some HTML {
        div {
            label(.for("username"), .class("block text-sm font-medium text-gray-700")) {
                "Username (optional)"
            }
            input(
                .id("username"),
                .name("username"),
                .type(.text),
                .class("mt-1 appearance-none relative block w-full px-3 py-2 border border-gray-300 placeholder-gray-500 text-gray-900 rounded-md focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 focus:z-10 sm:text-sm"),
                .placeholder("Enter your username (or leave blank)")
            )
            p(.class("mt-1 text-xs text-gray-500")) {
                "Leave blank to see all available passkeys for this device"
            }
        }
    }
}

struct PasskeyButtons: HTML {
    var content: some HTML {
        div(.class("space-y-3")) {
            button(
                .id("loginBtn"),
                .class("group relative w-full flex justify-center py-2 px-4 border border-transparent text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"),
                .custom(name: "onclick", value: "authenticateWithPasskey(document.getElementById('username').value.trim() || null)")
            ) {
                "🔑 Sign in with Passkey"
            }

            button(
                .id("loginWithoutUsernameBtn"),
                .class("group relative w-full flex justify-center py-2 px-4 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"),
                .custom(name: "onclick", value: "authenticateWithPasskey(null)")
            ) {
                "🔐 Use any available Passkey"
            }
        }
    }
}

struct LoginFallbackSection: HTML {
    var content: some HTML {
        div(.class("bg-yellow-50 p-4 rounded-lg passkey-fallback"), .style("display: none;")) {
            div(.class("flex")) {
                div(.class("flex-shrink-0")) {
                    "⚠️"
                }
                div(.class("ml-3")) {
                    h3(.class("text-sm font-medium text-yellow-800")) {
                        "Passkeys not supported"
                    }
                    div(.class("mt-2 text-sm text-yellow-700")) {
                        p {
                            "Your browser doesn't support Passkeys. Please use a supported browser to access your account."
                        }
                    }
                }
            }
        }
    }
}

struct LoginPageScript: HTML {
    var content: some HTML {
        script(.type("text/javascript")) {
            HTMLRaw("""
            // Check if user is already logged in on page load
            document.addEventListener('DOMContentLoaded', async () => {
                const session = await window.webAuthnClient.getSession();
                if (session && session.user) {
                    window.location.href = '/';
                }
            });

            // Handle passkey authentication via HTMX
            async function authenticateWithPasskey(username) {
                try {
                    const result = await window.webAuthnClient.authenticate(username);
                    if (result && result.success) {
                        // Trigger an HTMX request to complete login
                        htmx.ajax('POST', '/auth/login/complete', {
                            values: { success: true },
                            target: '#loginStatus',
                            swap: 'innerHTML'
                        }).then(() => {
                            setTimeout(() => window.location.href = '/', 1000);
                        });
                    }
                } catch (error) {
                    document.getElementById('loginStatus').innerHTML =
                        `<div class="text-red-500 text-sm mt-2">Authentication failed: ${error.message}</div>`;
                }
            }
            """)
        }
    }
}
