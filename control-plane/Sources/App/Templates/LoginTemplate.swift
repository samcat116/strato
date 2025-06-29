import Elementary
import ElementaryHTMX
import Vapor

struct LoginTemplate: HTMLDocument {
    var title = "Login - Strato"

    var head: some HTML {
        meta(.charset("utf-8"))
        meta(.name("viewport"), .content("width=device-width, initial-scale=1.0"))
        link(.rel("icon"), .href("/favicon.svg"))
        link(.rel("icon"), .href("/favicon.ico"))
        link(.rel("stylesheet"), .href("/styles/app.generated.css"))
        script(.src("/js/webauthn.js")) { "" }
    }

    var body: some HTML {
        div(.class("bg-gray-100 min-h-screen flex items-center justify-center")) {
            div(.class("max-w-md w-full space-y-8")) {
                div {
                    h2(.class("mt-6 text-center text-3xl font-extrabold text-gray-900")) {
                        "Sign in to Strato"
                    }
                    p(.class("mt-2 text-center text-sm text-gray-600")) {
                        "Use your Passkey for secure, passwordless authentication"
                    }
                }

                div(.class("mt-8 space-y-6")) {
                    LoginFormSection()
                    LoginFallbackSection()

                    div(.class("text-center")) {
                        a(.href("/register"), .class("text-indigo-600 hover:text-indigo-500")) {
                            "Don't have an account? Sign up"
                        }
                    }
                }
            }
        }

        script(.type("text/javascript")) {
            HTMLRaw("""
            document.getElementById('loginBtn').addEventListener('click', async () => {
                const username = document.getElementById('username').value.trim();
                const result = await WebAuthnUtils.handleAuthentication(username || null, 'loginStatus');

                if (result && result.success) {
                    WebAuthnUtils.showSuccess('loginStatus', 'Login successful! Redirecting...');
                    setTimeout(() => {
                        window.location.href = '/';
                    }, 1500);
                }
            });

            document.getElementById('loginWithoutUsernameBtn').addEventListener('click', async () => {
                const result = await WebAuthnUtils.handleAuthentication(null, 'loginStatus');

                if (result && result.success) {
                    WebAuthnUtils.showSuccess('loginStatus', 'Login successful! Redirecting...');
                    setTimeout(() => {
                        window.location.href = '/';
                    }, 1500);
                }
            });

            // Check if user is already logged in
            document.addEventListener('DOMContentLoaded', async () => {
                const session = await window.webAuthnClient.getSession();
                if (session && session.user) {
                    window.location.href = '/';
                }
            });
            """)
        }
    }
}

struct LoginFormSection: HTML {
    var content: some HTML {
        div(.class("bg-white p-6 rounded-lg shadow passkey-only")) {
            div(.class("space-y-4")) {
                div {
                    label(.for("username"), .class("block text-sm font-medium text-gray-700")) {
                        "Username (optional)"
                    }
                    input(
                        .id("username"),
                        .name("username"),
                        .type(.text),
                        .class(
                            "mt-1 appearance-none relative block w-full px-3 py-2 border border-gray-300 placeholder-gray-500 text-gray-900 rounded-md focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 focus:z-10 sm:text-sm"
                        ),
                        .placeholder("Enter your username (or leave blank)")
                    )
                    p(.class("mt-1 text-xs text-gray-500")) {
                        "Leave blank to see all available passkeys for this device"
                    }
                }

                div(.class("space-y-3")) {
                    button(
                        .id("loginBtn"),
                        .class(
                            "group relative w-full flex justify-center py-2 px-4 border border-transparent text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
                        )
                    ) {
                        "🔑 Sign in with Passkey"
                    }

                    button(
                        .id("loginWithoutUsernameBtn"),
                        .class(
                            "group relative w-full flex justify-center py-2 px-4 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
                        )
                    ) {
                        "🔐 Use any available Passkey"
                    }
                }

                div(.id("loginStatus"), .class("mt-4")) {}
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