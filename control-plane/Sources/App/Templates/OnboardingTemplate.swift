import Elementary
import ElementaryHTMX
import Vapor

struct OnboardingTemplate: HTMLDocument {
    var title = "Welcome to Strato - Setup Your Organization"

    var head: some HTML {
        meta(.charset("utf-8"))
        meta(.name("viewport"), .content("width=device-width, initial-scale=1.0"))
        link(.rel("icon"), .href("/favicon.svg"))
        link(.rel("icon"), .href("/favicon.ico"))
        link(.rel("stylesheet"), .href("/styles/app.generated.css"))

        script(.src("https://unpkg.com/htmx.org@1.9.10")) {}
    }

    var body: some HTML {
        div(.class("bg-gradient-to-br from-indigo-50 to-white min-h-screen flex items-center justify-center py-12 px-4 sm:px-6 lg:px-8")) {
            div(.class("max-w-2xl w-full space-y-8")) {
                // Welcome Header
                div(.class("text-center")) {
                    div(.class("flex justify-center mb-6")) {
                        div(.class("bg-indigo-100 rounded-full p-4")) {
                            // Strato logo or icon placeholder
                            div(.class("w-16 h-16 bg-indigo-600 rounded-full flex items-center justify-center")) {
                                span(.class("text-white text-2xl font-bold")) { "S" }
                            }
                        }
                    }
                    h1(.class("text-4xl font-extrabold text-gray-900 mb-2")) {
                        "Welcome to Strato!"
                    }
                    p(.class("text-xl text-gray-600 mb-8")) {
                        "Let's set up your private cloud platform"
                    }
                    div(.class("bg-blue-50 border border-blue-200 rounded-lg p-4 mb-8")) {
                        p(.class("text-blue-800 text-sm")) {
                            "🎉 You're the first user! As the system administrator, you'll have full control over this Strato instance."
                        }
                    }
                }

                // Organization Setup Form
                div(.class("bg-white shadow-xl rounded-lg p-8")) {
                    h2(.class("text-2xl font-bold text-gray-900 mb-6")) {
                        "Create Your Organization"
                    }
                    p(.class("text-gray-600 mb-6")) {
                        "Organizations help you manage users, resources, and permissions. Start by creating your primary organization."
                    }

                    OrganizationSetupForm()
                }

                // Features Preview
                div(.class("bg-white shadow-lg rounded-lg p-6")) {
                    h3(.class("text-lg font-semibold text-gray-900 mb-4")) {
                        "What you can do with Strato:"
                    }
                    div(.class("grid grid-cols-1 md:grid-cols-3 gap-4")) {
                        FeatureItem(
                            icon: "🖥️",
                            title: "Manage VMs",
                            description: "Create and manage virtual machines"
                        )
                        FeatureItem(
                            icon: "👥",
                            title: "User Management",
                            description: "Invite users and manage permissions"
                        )
                        FeatureItem(
                            icon: "🏢",
                            title: "Organizations",
                            description: "Organize resources by teams or projects"
                        )
                    }
                }
            }
        }
    }
}

struct OrganizationSetupForm: HTML {
    var content: some HTML {
        form(
            .id("setupForm"),
            .class("space-y-6"),
            .custom(name: "hx-post", value: "/htmx/onboarding/setup"),
            .custom(name: "hx-target", value: "#setupForm"),
            .custom(name: "hx-swap", value: "innerHTML"),
            .custom(name: "hx-indicator", value: "#submit-indicator")
        ) {
            div {
                label(.for("name"), .class("block text-sm font-medium text-gray-700 mb-2")) {
                    "Organization Name"
                }
                input(
                    .id("name"),
                    .name("name"),
                    .type(.text),
                    .required,
                    .class("w-full px-3 py-2 border border-gray-300 rounded-md shadow-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"),
                    .placeholder("e.g., Acme Corp, Engineering Team")
                )
                p(.class("mt-1 text-sm text-gray-500")) {
                    "This will be the primary organization for your Strato instance."
                }
            }

            div {
                label(.for("description"), .class("block text-sm font-medium text-gray-700 mb-2")) {
                    "Description"
                }
                textarea(
                    .id("description"),
                    .name("description"),
                    .class("w-full px-3 py-2 border border-gray-300 rounded-md shadow-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 h-20"),
                    .placeholder("Describe your organization's purpose or use case...")
                ) { "" }
                p(.class("mt-1 text-sm text-gray-500")) {
                    "Optional: Help others understand what this organization is for."
                }
            }

            div {
                button(
                    .id("submitBtn"),
                    .type(.submit),
                    .class("w-full flex justify-center py-3 px-4 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500 disabled:bg-gray-400 disabled:cursor-not-allowed")
                ) {
                    span(.class("htmx-indicator"), .id("submit-indicator")) {
                        "Setting up..."
                    }
                    span(.class("default-text")) {
                        "Create Organization & Continue"
                    }
                }
            }
        }
    }
}

struct FeatureItem: HTML {
    let icon: String
    let title: String
    let description: String

    var content: some HTML {
        div(.class("text-center")) {
            div(.class("text-2xl mb-2")) { icon }
            h4(.class("font-medium text-gray-900 mb-1")) { title }
            p(.class("text-sm text-gray-600")) { description }
        }
    }
}
