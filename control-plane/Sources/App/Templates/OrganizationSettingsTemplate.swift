import Elementary
import ElementaryHTMX

struct OrganizationSettingsTemplate: HTMLDocument {
    let organization: OrganizationResponse
    let user: User

    var title: String { "Organization Settings - \(organization.name) - Strato" }

    var head: some HTML {
        meta(.charset("utf-8"))
        meta(.name("viewport"), .content("width=device-width, initial-scale=1"))

        link(.rel("stylesheet"), .href("/styles/app.generated.css"))
        link(.rel("icon"), .href("/favicon.ico"))

        script(.src("https://unpkg.com/htmx.org@1.9.10")) {}
        script(.src("https://unpkg.com/hyperscript.org@0.9.12")) {}
    }

    var body: some HTML {
        div(.class("min-h-screen bg-gray-50")) {
            OrganizationSettingsHeader(organization: organization, user: user)
            OrganizationSettingsMain(organization: organization)
            NotificationArea()
        }
    }
}

struct OrganizationSettingsHeader: HTML {
    let organization: OrganizationResponse
    let user: User

    var content: some HTML {
        header(.class("bg-white shadow-sm border-b border-gray-200")) {
            div(.class("max-w-7xl mx-auto px-4 sm:px-6 lg:px-8")) {
                div(.class("flex items-center justify-between h-16")) {
                    div(.class("flex items-center space-x-4")) {
                        a(.href("/dashboard"), .class("text-gray-500 hover:text-gray-700")) {
                            "← Back to Dashboard"
                        }
                        h1(.class("text-xl font-semibold text-gray-900")) {
                            span(.id("org-name-header")) { organization.name }
                            " Settings"
                        }
                    }

                    div(.class("flex items-center space-x-4")) {
                        span(.class("text-sm text-gray-600")) {
                            "Logged in as \(user.displayName)"
                        }
                    }
                }
            }
        }
    }
}

struct OrganizationSettingsMain: HTML {
    let organization: OrganizationResponse

    var content: some HTML {
        main(.class("max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8")) {
            div(.class("lg:grid lg:grid-cols-12 lg:gap-8")) {
                // Sidebar
                aside(.class("lg:col-span-3")) {
                    nav(.class("space-y-1")) {
                        div(
                            .class("bg-gray-100 text-gray-900 group flex items-center px-3 py-2 text-sm font-medium rounded-md cursor-pointer"),
                            .custom(name: "hx-get", value: "/htmx/organizations/\(organization.id?.uuidString ?? "")/settings/info-tab"),
                            .custom(name: "hx-target", value: "#settings-content"),
                            .custom(name: "hx-swap", value: "innerHTML")
                        ) {
                            "📋 Organization Info"
                        }

                        div(
                            .class("text-gray-600 hover:bg-gray-50 hover:text-gray-900 group flex items-center px-3 py-2 text-sm font-medium rounded-md cursor-pointer"),
                            .custom(name: "hx-get", value: "/htmx/organizations/\(organization.id?.uuidString ?? "")/settings/oidc-tab"),
                            .custom(name: "hx-target", value: "#settings-content"),
                            .custom(name: "hx-swap", value: "innerHTML")
                        ) {
                            "🔐 OIDC Authentication"
                        }

                        // Placeholder for future settings sections
                        div(.class("text-gray-400 px-3 py-2 text-sm")) {
                            "More settings coming soon..."
                        }
                    }
                }

                // Main content
                div(.class("lg:col-span-9")) {
                    div(
                        .id("settings-content"),
                        .custom(name: "hx-get", value: "/htmx/organizations/\(organization.id?.uuidString ?? "")/settings/info-tab"),
                        .custom(name: "hx-trigger", value: "load"),
                        .custom(name: "hx-swap", value: "innerHTML")
                    ) {
                        p(.class("text-gray-500")) { "Loading..." }
                    }
                }
            }
        }
    }
}

struct NotificationArea: HTML {
    var content: some HTML {
        div(.id("notification-area"), .class("fixed top-0 right-0 p-4 z-50")) {
            // Toast notifications will be inserted here via HTMX
        }
    }
}
