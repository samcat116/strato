import Elementary
import ElementaryHTMX
import Vapor

struct RegisterTemplate: HTMLDocument {
    var title = "Register - Strato"

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
                        "Create your account"
                    }
                    p(.class("mt-2 text-center text-sm text-gray-600")) {
                        "Register with Passkeys for secure, passwordless authentication"
                    }
                }

                div(.class("mt-8 space-y-6")) {
                    RegisterFormSection()
                    PasskeyRegistrationSection()
                    RegisterFallbackSection()

                    div(.class("text-center")) {
                        a(.href("/login"), .class("text-indigo-600 hover:text-indigo-500")) {
                            "Already have an account? Sign in"
                        }
                    }
                }
            }
        }

        script(.type("text/javascript")) {
            HTMLRaw("""
            let createdUsername = null;

            document.getElementById('registerForm').addEventListener('submit', async (e) => {
                e.preventDefault();

                const formData = new FormData(e.target);
                const userData = {
                    username: formData.get('username'),
                    email: formData.get('email'),
                    displayName: formData.get('displayName')
                };

                try {
                    const response = await fetch('/users/register', {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/json'
                        },
                        body: JSON.stringify(userData)
                    });

                    if (response.ok) {
                        const user = await response.json();
                        createdUsername = userData.username;

                        // Enable passkey registration
                        document.getElementById('registerPasskeyBtn').disabled = false;
                        document.getElementById('registerForm').style.display = 'none';

                        WebAuthnUtils.showSuccess('passkeyStatus', 'Account created! Now register your passkey below.');
                    } else {
                        const error = await response.json();
                        alert(`Registration failed: ${error.reason || 'Unknown error'}`);
                    }
                } catch (error) {
                    alert(`Registration failed: ${error.message}`);
                }
            });

            document.getElementById('registerPasskeyBtn').addEventListener('click', async () => {
                if (!createdUsername) return;

                const result = await WebAuthnUtils.handleRegistration(createdUsername, 'passkeyStatus');

                if (result && result.success && result.user) {
                    // User is now logged in automatically
                    WebAuthnUtils.showSuccess('passkeyStatus', 'Registration successful! Redirecting to dashboard...');
                    setTimeout(() => {
                        window.location.href = '/';
                    }, 1500);
                } else if (result && result.success) {
                    // Fallback in case user data is missing
                    setTimeout(() => {
                        window.location.href = '/';
                    }, 1500);
                }
            });
            """)
        }
    }
}

struct RegisterFormSection: HTML {
    var content: some HTML {
        div(.class("bg-white p-6 rounded-lg shadow")) {
            form(.id("registerForm"), .class("space-y-4")) {
                div {
                    label(.for("username"), .class("block text-sm font-medium text-gray-700")) {
                        "Username"
                    }
                    input(
                        .id("username"),
                        .name("username"),
                        .type(.text),
                        .required,
                        .class(
                            "mt-1 appearance-none relative block w-full px-3 py-2 border border-gray-300 placeholder-gray-500 text-gray-900 rounded-md focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 focus:z-10 sm:text-sm"
                        ),
                        .placeholder("Enter your username")
                    )
                }

                div {
                    label(.for("email"), .class("block text-sm font-medium text-gray-700")) {
                        "Email"
                    }
                    input(
                        .id("email"),
                        .name("email"),
                        .type(.email),
                        .required,
                        .class(
                            "mt-1 appearance-none relative block w-full px-3 py-2 border border-gray-300 placeholder-gray-500 text-gray-900 rounded-md focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 focus:z-10 sm:text-sm"
                        ),
                        .placeholder("Enter your email")
                    )
                }

                div {
                    label(.for("displayName"), .class("block text-sm font-medium text-gray-700")) {
                        "Display Name"
                    }
                    input(
                        .id("displayName"),
                        .name("displayName"),
                        .type(.text),
                        .required,
                        .class(
                            "mt-1 appearance-none relative block w-full px-3 py-2 border border-gray-300 placeholder-gray-500 text-gray-900 rounded-md focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 focus:z-10 sm:text-sm"
                        ),
                        .placeholder("Enter your display name")
                    )
                }

                div {
                    button(
                        .type(.submit),
                        .class(
                            "group relative w-full flex justify-center py-2 px-4 border border-transparent text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
                        )
                    ) {
                        "Create Account"
                    }
                }
            }
        }
    }
}

struct PasskeyRegistrationSection: HTML {
    var content: some HTML {
        div(.class("bg-white p-6 rounded-lg shadow passkey-only")) {
            h3(.class("text-lg font-medium text-gray-900 mb-4")) {
                "Step 2: Register your Passkey"
            }
            p(.class("text-sm text-gray-600 mb-4")) {
                "After creating your account, you'll register a passkey for secure authentication."
            }
            button(
                .id("registerPasskeyBtn"),
                .disabled,
                .class(
                    "w-full flex justify-center py-2 px-4 border border-transparent text-sm font-medium rounded-md text-white bg-green-600 hover:bg-green-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-green-500 disabled:bg-gray-400 disabled:cursor-not-allowed"
                )
            ) {
                "Register Passkey"
            }
            div(.id("passkeyStatus"), .class("mt-4")) {}
        }
    }
}

struct RegisterFallbackSection: HTML {
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
                            "Your browser doesn't support Passkeys. Please use a supported browser for the best security experience."
                        }
                    }
                }
            }
        }
    }
}
