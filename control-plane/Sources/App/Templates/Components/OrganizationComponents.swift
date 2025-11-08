import Elementary
import ElementaryHTMX
import Foundation

// MARK: - Toast Notification

struct ToastNotification: HTML {
    let message: String
    let isError: Bool

    var content: some HTML {
        div(
            .class("fixed top-4 right-4 px-6 py-3 rounded-lg shadow-lg z-50 animate-fade-in"),
            .class(isError ? "bg-red-500 text-white" : "bg-green-500 text-white"),
            .custom(name: "x-data", value: "{ show: true }"),
            .custom(name: "x-init", value: "setTimeout(() => $el.remove(), 3000)")
        ) {
            message
        }
    }
}

// MARK: - Organization Info Tab

struct OrganizationInfoTabContent: HTML {
    let organization: OrganizationResponse

    var content: some HTML {
        div(.class("bg-white shadow rounded-lg")) {
            div(.class("px-6 py-4 border-b border-gray-200")) {
                h2(.class("text-lg font-medium text-gray-900")) {
                    "Organization Information"
                }
                p(.class("mt-1 text-sm text-gray-600")) {
                    "Update your organization's basic information and settings."
                }
            }

            div(.class("px-6 py-6")) {
                form(
                    .id("organization-info-form"),
                    .custom(name: "hx-put", value: "/htmx/organizations/\(organization.id?.uuidString ?? "")/settings/update"),
                    .custom(name: "hx-target", value: "#notification-area"),
                    .custom(name: "hx-swap", value: "beforeend")
                ) {
                    div(.class("grid grid-cols-1 gap-6")) {
                        div {
                            label(.for("name"), .class("block text-sm font-medium text-gray-700")) {
                                "Organization Name"
                            }
                            input(
                                .type(.text),
                                .name("name"),
                                .id("name"),
                                .value(organization.name),
                                .required,
                                .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                                .placeholder("Enter organization name")
                            )
                        }

                        div {
                            label(.for("description"), .class("block text-sm font-medium text-gray-700")) {
                                "Description"
                            }
                            textarea(
                                .name("description"),
                                .id("description"),
                                .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm h-20"),
                                .placeholder("Enter a description for your organization")
                            ) { organization.description }
                        }
                    }

                    div(.class("mt-6 flex justify-end")) {
                        button(
                            .type(.submit),
                            .class("inline-flex justify-center rounded-md border border-transparent bg-indigo-600 py-2 px-4 text-sm font-medium text-white shadow-sm hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2")
                        ) {
                            "Save Changes"
                        }
                    }
                }
            }
        }
    }
}

// MARK: - OIDC Tab

struct OIDCTabContent: HTML {
    let organization: OrganizationResponse

    var content: some HTML {
        div(.class("bg-white shadow rounded-lg")) {
            div(.class("px-6 py-4 border-b border-gray-200")) {
                h2(.class("text-lg font-medium text-gray-900")) {
                    "OIDC Authentication Providers"
                }
                p(.class("mt-1 text-sm text-gray-600")) {
                    "Configure OpenID Connect providers for single sign-on authentication."
                }
            }

            div(.class("px-6 py-6")) {
                div(
                    .id("oidc-providers-list"),
                    .custom(name: "hx-get", value: "/htmx/organizations/\(organization.id?.uuidString ?? "")/settings/oidc-providers/list"),
                    .custom(name: "hx-trigger", value: "load"),
                    .custom(name: "hx-swap", value: "innerHTML")
                ) {
                    p(.class("text-gray-500")) { "Loading OIDC providers..." }
                }

                div(.class("mt-6"), .id("add-provider-button")) {
                    button(
                        .type(.button),
                        .class("inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"),
                        .custom(name: "hx-get", value: "/htmx/organizations/\(organization.id?.uuidString ?? "")/settings/oidc-providers/form/new"),
                        .custom(name: "hx-target", value: "#provider-form-section"),
                        .custom(name: "hx-swap", value: "innerHTML")
                    ) {
                        "➕ Add OIDC Provider"
                    }
                }

                div(.class("mt-6"), .id("provider-form-section"), .style("display: none;")) {}
                div(.class("mt-6"), .id("edit-provider-form-section"), .style("display: none;")) {}
            }
        }
    }
}

// MARK: - OIDC Providers List

struct OIDCProvidersList: HTML {
    let providers: [OIDCProviderResponse]
    let organizationID: UUID

    var content: some HTML {
        if providers.isEmpty {
            p(.class("text-gray-500 text-center py-4")) { "No OIDC providers configured" }
        } else {
            ForEach(providers) { provider in
                div(.class("border rounded-lg p-4 mb-4")) {
                    div(.class("flex justify-between items-center")) {
                        div(.class("flex-1")) {
                            h4(.class("font-medium text-gray-900")) { provider.name }
                            p(.class("text-sm text-gray-500")) { "Client ID: \(provider.clientID)" }
                            p(.class("text-sm text-gray-500")) { "Status: \(provider.enabled ? "Enabled" : "Disabled")" }
                        }
                        div(.class("space-x-2 flex-shrink-0")) {
                            button(
                                .class("text-indigo-600 hover:text-indigo-900"),
                                .custom(name: "hx-get", value: "/htmx/organizations/\(organizationID.uuidString)/settings/oidc-providers/\(provider.id?.uuidString ?? "")/form/edit"),
                                .custom(name: "hx-target", value: "#edit-provider-form-section"),
                                .custom(name: "hx-swap", value: "innerHTML")
                            ) { "Edit" }
                            button(
                                .class("text-red-600 hover:text-red-900"),
                                .custom(name: "hx-delete", value: "/htmx/organizations/\(organizationID.uuidString)/settings/oidc-providers/\(provider.id?.uuidString ?? "")"),
                                .custom(name: "hx-confirm", value: "Are you sure you want to delete this OIDC provider?")
                            ) { "Delete" }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - OIDC Provider Form

struct OIDCProviderForm: HTML {
    let organizationID: UUID
    let provider: OIDCProviderResponse?
    let isEdit: Bool

    var content: some HTML {
        form(
            .id(isEdit ? "edit-oidc-provider-form" : "oidc-provider-form"),
            .custom(name: isEdit ? "hx-put" : "hx-post", value: isEdit ? "/htmx/organizations/\(organizationID.uuidString)/settings/oidc-providers/\(provider?.id?.uuidString ?? "")/update" : "/htmx/organizations/\(organizationID.uuidString)/settings/oidc-providers/create")
        ) {
            div(.class("grid grid-cols-1 gap-6")) {
                div {
                    label(.for("name"), .class("block text-sm font-medium text-gray-700")) {
                        "Provider Name"
                    }
                    input(
                        .type(.text),
                        .name("name"),
                        .id("name"),
                        .value(provider?.name ?? ""),
                        .required,
                        .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                        .placeholder("e.g., Azure AD, Google Workspace, Okta")
                    )
                }

                div {
                    label(.for("clientID"), .class("block text-sm font-medium text-gray-700")) {
                        "Client ID"
                    }
                    input(
                        .type(.text),
                        .name("clientID"),
                        .id("clientID"),
                        .value(provider?.clientID ?? ""),
                        .required,
                        .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                        .placeholder("Client ID from your OIDC provider")
                    )
                }

                div {
                    label(.for("clientSecret"), .class("block text-sm font-medium text-gray-700")) {
                        isEdit ? "Client Secret (leave blank to keep current)" : "Client Secret"
                    }
                    if isEdit {
                        input(
                            .type(.password),
                            .name("clientSecret"),
                            .id("clientSecret"),
                            .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                            .placeholder("Leave blank to keep existing secret")
                        )
                    } else {
                        input(
                            .type(.password),
                            .name("clientSecret"),
                            .id("clientSecret"),
                            .required,
                            .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                            .placeholder("Client Secret from your OIDC provider")
                        )
                    }
                }

                div {
                    label(.for("discoveryURL"), .class("block text-sm font-medium text-gray-700")) {
                        "Discovery URL"
                    }
                    input(
                        .type(.url),
                        .name("discoveryURL"),
                        .id("discoveryURL"),
                        .value(provider?.discoveryURL ?? ""),
                        .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                        .placeholder("https://provider.com/.well-known/openid-configuration")
                    )
                }

                div {
                    div(.class("flex items-center")) {
                        if provider?.enabled ?? true {
                            input(
                                .type(.checkbox),
                                .name("enabled"),
                                .id("enabled"),
                                .checked,
                                .class("h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300 rounded")
                            )
                        } else {
                            input(
                                .type(.checkbox),
                                .name("enabled"),
                                .id("enabled"),
                                .class("h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300 rounded")
                            )
                        }
                        label(.for("enabled"), .class("ml-2 block text-sm text-gray-900")) {
                            "Enable this provider"
                        }
                    }
                }
            }

            div(.class("mt-6 flex justify-end space-x-3")) {
                button(
                    .type(.button),
                    .class("inline-flex justify-center rounded-md border border-gray-300 bg-white py-2 px-4 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2"),
                    .custom(name: "onclick", value: "document.getElementById('\(isEdit ? "edit-provider-form-section" : "provider-form-section")').style.display='none'")
                ) {
                    "Cancel"
                }
                button(
                    .type(.submit),
                    .class("inline-flex justify-center rounded-md border border-transparent bg-indigo-600 py-2 px-4 text-sm font-medium text-white shadow-sm hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2")
                ) {
                    isEdit ? "Update Provider" : "Save Provider"
                }
            }
        }
    }
}

// MARK: - Organization List

struct OrganizationListPartial: HTML {
    let organizations: [OrganizationResponse]
    let currentOrgId: UUID?

    var content: some HTML {
        if organizations.isEmpty {
            div(.class("px-4 py-2 text-sm text-gray-400")) { "No organizations found" }
        } else {
            ForEach(organizations) { org in
                let isCurrent = org.id == currentOrgId
                let buttonClass = "w-full text-left px-4 py-2 text-sm hover:bg-gray-700 flex justify-between items-center transition-colors" + (isCurrent ? " bg-gray-700" : "")
                button(
                    .class(buttonClass),
                    .custom(name: "hx-post", value: "/htmx/organizations/\(org.id?.uuidString ?? "")/switch"),
                    .custom(name: "hx-target", value: "#orgList"),
                    .custom(name: "hx-swap", value: "innerHTML")
                ) {
                    div {
                        div(.class("font-medium \(isCurrent ? "text-blue-400" : "text-gray-300")")) {
                            if isCurrent { "✓ \(org.name)" } else { org.name }
                        }
                        div(.class("text-xs text-gray-400")) { org.description }
                    }
                    span(.class("text-xs text-gray-500")) { org.userRole ?? "member" }
                }
            }
        }
    }
}
