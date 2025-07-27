import Elementary
import ElementaryHTMX
import Vapor

struct DashboardTemplate: HTMLDocument {
    var title = "Strato Dashboard"

    var head: some HTML {
        meta(.charset("utf-8"))
        meta(.name("viewport"), .content("width=device-width, initial-scale=1.0"))
        link(.rel("icon"), .href("/favicon.svg"))
        link(.rel("icon"), .href("/favicon.ico"))
        link(.rel("stylesheet"), .href("/styles/app.generated.css"))
        link(.rel("stylesheet"), .href("https://cdn.jsdelivr.net/npm/xterm@4.19.0/css/xterm.css"))
        script(.src("https://unpkg.com/htmx.org@1.9.10/dist/htmx.min.js")) { "" }
        script(.src("https://cdn.jsdelivr.net/npm/xterm@4.19.0/lib/xterm.js")) { "" }
        script(.src("/js/webauthn.js")) { "" }
    }

    var body: some HTML {
        DashboardHeader()
        DashboardMain()
        AllModals()

        script(.type("text/javascript")) {
            HTMLRaw("""
            // Initialize terminal
            var term = new Terminal({
                theme: {
                    background: '#f9fafb',
                    foreground: '#374151'
                }
            });
            term.open(document.getElementById('terminal'));
            term.write('Strato Console Ready\\r\\n$ ');

            // Session and authentication handling
            document.addEventListener('DOMContentLoaded', async () => {
                try {
                    const session = await window.webAuthnClient.getSession();
                    if (session && session.user) {
                        document.getElementById('userInfo').textContent = `Welcome, ${session.user.displayName}`;
                        // HTMX will automatically load data using the 'load' triggers
                    } else {
                        window.location.href = '/login';
                    }
                } catch (error) {
                    console.error('Failed to load session:', error);
                    window.location.href = '/login';
                }
            });

            // Logout functionality
            async function logout() {
                const success = await window.webAuthnClient.logout();
                if (success) {
                    window.location.href = '/login';
                }
            }

            // Modal management
            function showModal(modalId) {
                document.getElementById(modalId).classList.remove('hidden');
            }

            function hideModal(modalId) {
                document.getElementById(modalId).classList.add('hidden');
                const form = document.querySelector(`#${modalId} form`);
                if (form) form.reset();
            }

            function toggleOrgDropdown() {
                const dropdown = document.getElementById('orgDropdown');
                dropdown.classList.toggle('hidden');
                
                // Close dropdown when clicking outside
                if (!dropdown.classList.contains('hidden')) {
                    document.addEventListener('click', function closeDropdown(e) {
                        if (!e.target.closest('#orgSwitcherBtn') && !e.target.closest('#orgDropdown')) {
                            dropdown.classList.add('hidden');
                            document.removeEventListener('click', closeDropdown);
                        }
                    });
                }
            }

            // Console logging function for HTMX responses
            function logToConsole(message) {
                term.write(`\\r\\n${message}\\r\\n$ `);
            }


            // Modal close on escape
            document.addEventListener('keydown', (e) => {
                if (e.key === 'Escape') {
                    ['createOrgModal', 'apiKeysModal', 'createApiKeyModal', 'createVMModal'].forEach(hideModal);
                }
            });

            // Make functions available globally for HTMX
            window.logout = logout;
            window.showModal = showModal;
            window.hideModal = hideModal;
            window.toggleOrgDropdown = toggleOrgDropdown;
            window.logToConsole = logToConsole;
            """)
        }
    }
}

struct DashboardHeader: HTML {
    var content: some HTML {
        header(.class("bg-white shadow-sm border-b border-gray-200")) {
            div(.class("flex items-center justify-between h-16 px-6")) {
                div(.class("flex items-center")) {
                    h1(.class("text-2xl font-bold text-indigo-600")) { "Strato" }
                }
                div(.class("flex items-center space-x-4")) {
                    // Organization Switcher
                    div(.class("relative")) {
                        button(
                            .id("orgSwitcherBtn"),
                            .class(
                                "bg-gray-50 hover:bg-gray-100 text-gray-700 px-3 py-2 rounded-md text-sm font-medium border border-gray-300 flex items-center space-x-2"
                            ),
                            .custom(name: "onclick", value: "toggleOrgDropdown()")
                        ) {
                            span(
                                .id("currentOrgName"),
                                .custom(name: "hx-trigger", value: "load"),
                                .custom(name: "hx-get", value: "/htmx/organizations/current"),
                                .custom(name: "hx-swap", value: "innerHTML")
                            ) { "Loading..." }
                            span(.class("text-gray-400")) { "▼" }
                        }
                        div(
                            .id("orgDropdown"),
                            .class("hidden absolute top-full left-0 mt-1 w-64 bg-white border border-gray-200 rounded-md shadow-lg z-10")
                        ) {
                            div(.class("py-1")) {
                                div(.class("px-4 py-2 text-xs font-medium text-gray-500 uppercase")) {
                                    "Switch Organization"
                                }
                                div(
                                    .id("orgList"), 
                                    .class("max-h-48 overflow-y-auto"),
                                    .custom(name: "hx-trigger", value: "load"),
                                    .custom(name: "hx-get", value: "/htmx/organizations/list"),
                                    .custom(name: "hx-swap", value: "innerHTML")
                                ) {
                                    div(.class("px-4 py-2 text-sm text-gray-500")) { "Loading organizations..." }
                                }
                                hr(.class("my-1"))
                                a(
                                    .id("orgSettingsBtn"),
                                    .class("w-full text-left px-4 py-2 text-sm text-gray-700 hover:bg-gray-50 flex items-center space-x-2"),
                                    .href("/htmx/organizations/settings")
                                ) {
                                    "⚙️"
                                    span { "Organization Settings" }
                                }
                                button(
                                    .id("createOrgBtn"),
                                    .class("w-full text-left px-4 py-2 text-sm text-indigo-600 hover:bg-gray-50")
                                ) {
                                    "+ Create Organization"
                                }
                            }
                        }
                    }
                    
                    button(
                        .id("createVMBtn"),
                        .class(
                            "bg-indigo-600 hover:bg-indigo-700 text-white px-4 py-2 rounded-md text-sm font-medium"
                        ),
                        .custom(name: "onclick", value: "showModal('createVMModal')")
                    ) {
                        "+ New VM"
                    }
                    button(
                        .id("settingsBtn"),
                        .class(
                            "bg-gray-100 hover:bg-gray-200 text-gray-700 px-4 py-2 rounded-md text-sm font-medium"
                        ),
                        .custom(name: "onclick", value: "showModal('apiKeysModal')")
                    ) {
                        "API Keys"
                    }
                    span(.id("userInfo"), .class("text-sm text-gray-600")) {}
                    button(
                        .id("logoutBtn"),
                        .class("text-gray-500 hover:text-gray-700 text-sm"),
                        .custom(name: "onclick", value: "logout()")
                    ) {
                        "Logout"
                    }
                }
            }
        }
    }
}

struct DashboardMain: HTML {
    var content: some HTML {
        main {
            div(.class("flex h-screen pt-16")) {
                DashboardSidebarSection()
                DashboardContentSection()
            }
        }
    }
}

struct AllModals: HTML {
    var content: some HTML {
        CreateOrgModal()
        APIKeysModal()
        CreateAPIKeyModal()
        CreateVMModal()
    }
}

struct CreateOrgModal: HTML {
    var content: some HTML {
        div(
            .id("createOrgModal"),
            .class("fixed inset-0 bg-gray-600 bg-opacity-50 hidden flex items-center justify-center z-50")
        ) {
            div(.class("bg-white rounded-lg shadow-xl max-w-md w-full mx-4")) {
                div(.class("px-6 py-4 border-b border-gray-200")) {
                    h3(.class("text-lg font-medium text-gray-900")) {
                        "Create Organization"
                    }
                }
                div(.class("px-6 py-4")) {
                    form(.id("createOrgForm")) {
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                                "Organization Name"
                            }
                            input(
                                .type(.text),
                                .id("orgName"),
                                .class("w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"),
                                .required
                            )
                        }
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                                "Description"
                            }
                            textarea(
                                .id("orgDescription"),
                                .class("w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500 h-20"),
                                .required
                            ) {}
                        }
                    }
                }
                div(.class("px-6 py-4 border-t border-gray-200 flex justify-end space-x-3")) {
                    button(
                        .id("cancelOrgBtn"),
                        .type(.button),
                        .class("px-4 py-2 text-sm font-medium text-gray-700 bg-gray-100 hover:bg-gray-200 rounded-md")
                    ) {
                        "Cancel"
                    }
                    button(
                        .id("submitOrgBtn"),
                        .type(.button),
                        .class("px-4 py-2 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-md")
                    ) {
                        "Create"
                    }
                }
            }
        }
    }
}

struct APIKeysModal: HTML {
    var content: some HTML {
        div(
            .id("apiKeysModal"),
            .class("fixed inset-0 bg-gray-600 bg-opacity-50 hidden flex items-center justify-center z-50")
        ) {
            div(.class("bg-white rounded-lg shadow-xl max-w-4xl w-full mx-4 max-h-screen overflow-y-auto")) {
                div(.class("px-6 py-4 border-b border-gray-200 flex justify-between items-center")) {
                    h3(.class("text-lg font-medium text-gray-900")) {
                        "API Keys"
                    }
                    button(
                        .id("closeApiKeysBtn"),
                        .class("text-gray-400 hover:text-gray-600")
                    ) {
                        "✕"
                    }
                }
                div(.class("px-6 py-4")) {
                    div(.class("mb-4")) {
                        button(
                            .id("createApiKeyBtn"),
                            .class("bg-indigo-600 hover:bg-indigo-700 text-white px-4 py-2 rounded-md text-sm font-medium")
                        ) {
                            "+ Create API Key"
                        }
                    }
                    div(.id("apiKeysList"), .class("space-y-4")) {
                        div(.class("text-center text-gray-500 py-8")) {
                            "Loading API keys..."
                        }
                    }
                }
            }
        }
    }
}

struct CreateAPIKeyModal: HTML {
    var content: some HTML {
        div(
            .id("createApiKeyModal"),
            .class("fixed inset-0 bg-gray-600 bg-opacity-50 hidden flex items-center justify-center z-50")
        ) {
            div(.class("bg-white rounded-lg shadow-xl max-w-md w-full mx-4")) {
                div(.class("px-6 py-4 border-b border-gray-200")) {
                    h3(.class("text-lg font-medium text-gray-900")) {
                        "Create API Key"
                    }
                }
                div(.class("px-6 py-4")) {
                    form(.id("createApiKeyForm")) {
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                                "Key Name"
                            }
                            input(
                                .type(.text),
                                .id("apiKeyName"),
                                .class("w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"),
                                .required
                            )
                        }
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                                "Scopes"
                            }
                            div(.class("space-y-2")) {
                                label(.class("flex items-center")) {
                                    input(.type(.checkbox), .value("read"), .class("mr-2"), .checked)
                                    span(.class("text-sm")) { "Read" }
                                }
                                label(.class("flex items-center")) {
                                    input(.type(.checkbox), .value("write"), .class("mr-2"), .checked)
                                    span(.class("text-sm")) { "Write" }
                                }
                                label(.class("flex items-center")) {
                                    input(.type(.checkbox), .value("admin"), .class("mr-2"))
                                    span(.class("text-sm")) { "Admin" }
                                }
                            }
                        }
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                                "Expires In (days)"
                            }
                            select(
                                .id("apiKeyExpiry"),
                                .class("w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500")
                            ) {
                                option(.value(""), .selected) { "Never" }
                                option(.value("7")) { "7 days" }
                                option(.value("30")) { "30 days" }
                                option(.value("90")) { "90 days" }
                                option(.value("365")) { "1 year" }
                            }
                        }
                    }
                }
                div(.class("px-6 py-4 border-t border-gray-200 flex justify-end space-x-3")) {
                    button(
                        .id("cancelApiKeyBtn"),
                        .type(.button),
                        .class("px-4 py-2 text-sm font-medium text-gray-700 bg-gray-100 hover:bg-gray-200 rounded-md")
                    ) {
                        "Cancel"
                    }
                    button(
                        .id("submitApiKeyBtn"),
                        .type(.button),
                        .class("px-4 py-2 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-md")
                    ) {
                        "Create"
                    }
                }
            }
        }
    }
}

struct CreateVMModal: HTML {
    var content: some HTML {
        div(
            .id("createVMModal"),
            .class("fixed inset-0 bg-gray-600 bg-opacity-50 hidden flex items-center justify-center z-50")
        ) {
            div(.class("bg-white rounded-lg shadow-xl max-w-lg w-full mx-4")) {
                CreateVMModalHeader()
                CreateVMModalContent()
                CreateVMModalFooter()
            }
        }
    }
}

struct CreateVMModalHeader: HTML {
    var content: some HTML {
        div(.class("px-6 py-4 border-b border-gray-200")) {
            h3(.class("text-lg font-medium text-gray-900")) {
                "Create Virtual Machine"
            }
        }
    }
}

struct CreateVMModalContent: HTML {
    var content: some HTML {
        div(.class("px-6 py-4")) {
            form(
                .id("createVMForm"),
                .custom(name: "hx-post", value: "/htmx/vms/create"),
                .custom(name: "hx-target", value: "#vmTableBody"),
                .custom(name: "hx-swap", value: "innerHTML"),
                .custom(name: "hx-on::after-request", value: "if(event.detail.successful) hideModal('createVMModal')")
            ) {
                div(.class("grid grid-cols-1 gap-4")) {
                    CreateVMFormNameDescription()
                    CreateVMFormResourcesTemplate()
                }
            }
        }
    }
}

struct CreateVMFormNameDescription: HTML {
    var content: some HTML {
        div {
            label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                "VM Name"
            }
            input(
                .type(.text),
                .id("vmName"),
                .class("w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"),
                .required
            )
        }
        div {
            label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                "Description"
            }
            textarea(
                .id("vmDescription"),
                .class("w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500 h-20"),
                .required
            ) {}
        }
    }
}

struct CreateVMFormResourcesTemplate: HTML {
    var content: some HTML {
        div(.class("grid grid-cols-2 gap-4")) {
            div {
                label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                    "CPU Cores"
                }
                input(
                    .type(.number),
                    .id("vmCpu"),
                    .class("w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"),
                    .value("1"),
                    .required
                )
            }
            div {
                label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                    "Memory (GB)"
                }
                input(
                    .type(.number),
                    .id("vmMemory"),
                    .class("w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"),
                    .value("2"),
                    .required
                )
            }
        }
        div(.class("grid grid-cols-2 gap-4")) {
            div {
                label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                    "Disk (GB)"
                }
                input(
                    .type(.number),
                    .id("vmDisk"),
                    .class("w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"),
                    .value("10"),
                    .required
                )
            }
            div {
                label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                    "Template"
                }
                select(
                    .id("vmTemplate"),
                    .class("w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"),
                    .required
                ) {
                    option(.value("ubuntu-22.04"), .selected) { "Ubuntu 22.04" }
                    option(.value("alpine-3.18")) { "Alpine 3.18" }
                }
            }
        }
    }
}

struct CreateVMModalFooter: HTML {
    var content: some HTML {
        div(.class("px-6 py-4 border-t border-gray-200 flex justify-end space-x-3")) {
            button(
                .id("cancelVMBtn"),
                .type(.button),
                .class("px-4 py-2 text-sm font-medium text-gray-700 bg-gray-100 hover:bg-gray-200 rounded-md"),
                .custom(name: "onclick", value: "hideModal('createVMModal')")
            ) {
                "Cancel"
            }
            button(
                .id("submitVMBtn"),
                .type(.submit),
                .class("px-4 py-2 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-md")
            ) {
                "Create VM"
            }
        }
    }
}

// struct DashboardMainLayoutSection: HTML {
//     var content: some HTML {
//         Elementary.div(.class("flex h-screen pt-16")) {
//             DashboardSidebarSection()
//             DashboardContentSection()
//         }
//     }
// }

struct DashboardSidebarSection: HTML {
    var content: some HTML {
        aside(.class("w-80 bg-white border-r border-gray-200 overflow-y-auto")) {
            div(.class("p-4")) {
                h2(.class("text-lg font-semibold text-gray-900 mb-4")) {
                    "Virtual Machines"
                }
                VMTableSection()
            }
        }
    }
}

struct VMTableSection: HTML {
    var content: some HTML {
        div(.class("overflow-hidden")) {
            table(.class("min-w-full")) {
                VMTableHeader()
                VMTableBody()
            }
        }
    }
}

struct VMTableHeader: HTML {
    var content: some HTML {
        thead(.class("bg-gray-50")) {
            tr {
                th(.class("px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase")) {
                    "Name"
                }
                th(.class("px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase")) {
                    "Status"
                }
                th(.class("px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase")) {
                    "Actions"
                }
            }
        }
    }
}

struct VMTableBody: HTML {
    var content: some HTML {
        tbody(
            .id("vmTableBody"), 
            .class("divide-y divide-gray-200"),
            .custom(name: "hx-trigger", value: "load"),
            .custom(name: "hx-get", value: "/htmx/vms/list"),
            .custom(name: "hx-swap", value: "innerHTML")
        ) {
            tr {
                td(.class("px-3 py-4 text-sm text-gray-500 text-center"), .custom(name: "colspan", value: "3")) {
                    "Loading VMs..."
                }
            }
        }
    }
}

struct DashboardContentSection: HTML {
    var content: some HTML {
        main(.class("flex-1 flex flex-col overflow-hidden")) {
            div(.class("bg-white border-b border-gray-200 px-6 py-4")) {
                h1(.class("text-lg font-semibold text-gray-900")) { "Dashboard" }
                p(.class("text-sm text-gray-600")) {
                    "Manage your virtual machines and infrastructure"
                }
            }

            div(.class("flex-1 p-6 overflow-y-auto")) {
                div(.class("grid grid-cols-1 lg:grid-cols-2 gap-6 h-full")) {
                    div(
                        .class("bg-white rounded-lg shadow-sm border border-gray-200 p-6")
                    ) {
                        h3(.class("text-lg font-medium text-gray-900 mb-4")) {
                            "VM Details"
                        }
                        div(.id("vmDetails"), .class("text-gray-500")) {
                            "Select a virtual machine to view details"
                        }
                    }

                    div(
                        .class("bg-white rounded-lg shadow-sm border border-gray-200 p-6")
                    ) {
                        h3(.class("text-lg font-medium text-gray-900 mb-4")) { "Console" }
                        div(
                            .id("terminal"), .class("border border-gray-300 rounded h-96")
                        ) {}
                    }
                }
            }
        }
    }
}
