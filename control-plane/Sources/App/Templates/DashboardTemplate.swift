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
        Elementary.body(.class("bg-gray-900 text-gray-100 min-h-screen")) {
            DashboardHeader()
            DashboardMain()
            AllModals()

            script(.type("text/javascript")) {
            HTMLRaw("""
            // Initialize terminal
            var term = new Terminal({
                theme: {
                    background: '#111827',
                    foreground: '#f3f4f6',
                    cursor: '#60a5fa',
                    cursorAccent: '#1f2937',
                    selection: '#374151'
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
                    ['createOrgModal', 'apiKeysModal', 'createApiKeyModal', 'createVMModal', 'addAgentModal'].forEach(modalId => hideModal(modalId));
                }
            });

            // Sidebar section toggling functionality
            function toggleSection(sectionId) {
                const content = document.getElementById(sectionId + '-content');
                const chevron = document.getElementById(sectionId + '-chevron');
                
                if (content.classList.contains('hidden')) {
                    content.classList.remove('hidden');
                    chevron.classList.add('rotate-90');
                    localStorage.setItem('sidebar-' + sectionId, 'expanded');
                } else {
                    content.classList.add('hidden');
                    chevron.classList.remove('rotate-90');
                    localStorage.setItem('sidebar-' + sectionId, 'collapsed');
                }
            }

            // Restore sidebar section states from localStorage
            function restoreSidebarStates() {
                const sections = ['vms-section', 'storage-section', 'networking-section', 'nodes-section', 'settings-section'];
                
                sections.forEach(sectionId => {
                    const state = localStorage.getItem('sidebar-' + sectionId);
                    if (state) {
                        const content = document.getElementById(sectionId + '-content');
                        const chevron = document.getElementById(sectionId + '-chevron');
                        
                        if (state === 'expanded') {
                            content.classList.remove('hidden');
                            chevron.classList.add('rotate-90');
                        } else {
                            content.classList.add('hidden');
                            chevron.classList.remove('rotate-90');
                        }
                    }
                });
            }

            // Initialize sidebar states after DOM is loaded
            document.addEventListener('DOMContentLoaded', () => {
                restoreSidebarStates();
            });

            // Make functions available globally for HTMX
            window.logout = logout;
            window.showModal = showModal;
            window.hideModal = hideModal;
            window.toggleOrgDropdown = toggleOrgDropdown;
            window.logToConsole = logToConsole;
            window.toggleSection = toggleSection;
            """)
            }
        }
    }
}

struct DashboardHeader: HTML {
    var content: some HTML {
        header(.class("bg-gray-900 shadow-sm border-b border-gray-700")) {
            div(.class("flex items-center justify-between h-16 px-6")) {
                div(.class("flex items-center")) {
                    h1(.class("text-2xl font-bold text-blue-400")) { "Strato" }
                }
                div(.class("flex items-center space-x-4")) {
                    // Organization Switcher
                    div(.class("relative")) {
                        button(
                            .id("orgSwitcherBtn"),
                            .class(
                                "bg-gray-800 hover:bg-gray-700 text-gray-200 px-3 py-2 rounded-md text-sm font-medium border border-gray-600 flex items-center space-x-2 transition-colors"
                            ),
                            .custom(name: "onclick", value: "toggleOrgDropdown()")
                        ) {
                            span(
                                .id("currentOrgName"),
                                .custom(name: "hx-trigger", value: "load"),
                                .custom(name: "hx-get", value: "/htmx/organizations/current"),
                                .custom(name: "hx-swap", value: "innerHTML")
                            ) { "Loading..." }
                            span(.class("text-gray-500")) { "▼" }
                        }
                        div(
                            .id("orgDropdown"),
                            .class("hidden absolute top-full left-0 mt-1 w-64 bg-gray-800 border border-gray-600 rounded-md shadow-lg z-10")
                        ) {
                            div(.class("py-1")) {
                                div(.class("px-4 py-2 text-xs font-medium text-gray-400 uppercase")) {
                                    "Switch Organization"
                                }
                                div(
                                    .id("orgList"),
                                    .class("max-h-48 overflow-y-auto"),
                                    .custom(name: "hx-trigger", value: "load"),
                                    .custom(name: "hx-get", value: "/htmx/organizations/list"),
                                    .custom(name: "hx-swap", value: "innerHTML")
                                ) {
                                    div(.class("px-4 py-2 text-sm text-gray-400")) { "Loading organizations..." }
                                }
                                hr(.class("my-1 border-gray-600"))
                                a(
                                    .id("orgSettingsBtn"),
                                    .class("w-full text-left px-4 py-2 text-sm text-gray-300 hover:bg-gray-700 hover:text-white flex items-center space-x-2 transition-colors"),
                                    .href("/htmx/organizations/settings")
                                ) {
                                    "⚙️"
                                    span { "Organization Settings" }
                                }
                                button(
                                    .id("createOrgBtn"),
                                    .class("w-full text-left px-4 py-2 text-sm text-blue-400 hover:bg-gray-700 hover:text-blue-300 transition-colors")
                                ) {
                                    "+ Create Organization"
                                }
                            }
                        }
                    }

                    button(
                        .id("createVMBtn"),
                        .class(
                            "bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md text-sm font-medium transition-colors"
                        ),
                        .custom(name: "onclick", value: "showModal('createVMModal')")
                    ) {
                        "+ New VM"
                    }
                    button(
                        .id("settingsBtn"),
                        .class(
                            "bg-gray-700 hover:bg-gray-600 text-gray-200 px-4 py-2 rounded-md text-sm font-medium transition-colors"
                        ),
                        .custom(name: "onclick", value: "showModal('apiKeysModal')")
                    ) {
                        "API Keys"
                    }
                    span(.id("userInfo"), .class("text-sm text-gray-300")) {}
                    button(
                        .id("logoutBtn"),
                        .class("text-gray-400 hover:text-gray-200 text-sm transition-colors"),
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
        main(.class("bg-gray-900")) {
            div(.class("flex h-screen pt-16 bg-gray-900")) {
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
        AddAgentModal()
    }
}

struct CreateOrgModal: HTML {
    var content: some HTML {
        div(
            .id("createOrgModal"),
            .class("fixed inset-0 bg-black bg-opacity-60 hidden flex items-center justify-center z-50")
        ) {
            div(.class("bg-gray-800 rounded-lg shadow-xl max-w-md w-full mx-4 border border-gray-600")) {
                div(.class("px-6 py-4 border-b border-gray-700")) {
                    h3(.class("text-lg font-medium text-gray-100")) {
                        "Create Organization"
                    }
                }
                div(.class("px-6 py-4")) {
                    form(.id("createOrgForm")) {
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-300 mb-2")) {
                                "Organization Name"
                            }
                            input(
                                .type(.text),
                                .id("orgName"),
                                .class("w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-gray-100 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"),
                                .required
                            )
                        }
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-300 mb-2")) {
                                "Description"
                            }
                            textarea(
                                .id("orgDescription"),
                                .class("w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-gray-100 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500 h-20"),
                                .required
                            ) {}
                        }
                    }
                }
                div(.class("px-6 py-4 border-t border-gray-700 flex justify-end space-x-3")) {
                    button(
                        .id("cancelOrgBtn"),
                        .type(.button),
                        .class("px-4 py-2 text-sm font-medium text-gray-300 bg-gray-700 hover:bg-gray-600 rounded-md transition-colors"),
                        .custom(name: "onclick", value: "hideModal('createOrgModal')")
                    ) {
                        "Cancel"
                    }
                    button(
                        .id("submitOrgBtn"),
                        .type(.button),
                        .class("px-4 py-2 text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 rounded-md transition-colors")
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
            .class("fixed inset-0 bg-black bg-opacity-60 hidden flex items-center justify-center z-50")
        ) {
            div(.class("bg-gray-800 rounded-lg shadow-xl max-w-4xl w-full mx-4 max-h-screen overflow-y-auto border border-gray-600")) {
                div(.class("px-6 py-4 border-b border-gray-700 flex justify-between items-center")) {
                    h3(.class("text-lg font-medium text-gray-100")) {
                        "API Keys"
                    }
                    button(
                        .id("closeApiKeysBtn"),
                        .class("text-gray-400 hover:text-gray-200 transition-colors"),
                        .custom(name: "onclick", value: "hideModal('apiKeysModal')")
                    ) {
                        "✕"
                    }
                }
                div(.class("px-6 py-4")) {
                    div(.class("mb-4")) {
                        button(
                            .id("createApiKeyBtn"),
                            .class("bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md text-sm font-medium transition-colors")
                        ) {
                            "+ Create API Key"
                        }
                    }
                    div(.id("apiKeysList"), .class("space-y-4")) {
                        div(.class("text-center text-gray-400 py-8")) {
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
            .class("fixed inset-0 bg-black bg-opacity-60 hidden flex items-center justify-center z-50")
        ) {
            div(.class("bg-gray-800 rounded-lg shadow-xl max-w-md w-full mx-4 border border-gray-600")) {
                div(.class("px-6 py-4 border-b border-gray-700")) {
                    h3(.class("text-lg font-medium text-gray-100")) {
                        "Create API Key"
                    }
                }
                div(.class("px-6 py-4")) {
                    form(.id("createApiKeyForm")) {
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-300 mb-2")) {
                                "Key Name"
                            }
                            input(
                                .type(.text),
                                .id("apiKeyName"),
                                .class("w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-gray-100 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"),
                                .required
                            )
                        }
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-300 mb-2")) {
                                "Scopes"
                            }
                            div(.class("space-y-2")) {
                                label(.class("flex items-center")) {
                                    input(.type(.checkbox), .value("read"), .class("mr-2 text-blue-600 bg-gray-700 border-gray-600 rounded focus:ring-blue-500"), .checked)
                                    span(.class("text-sm text-gray-300")) { "Read" }
                                }
                                label(.class("flex items-center")) {
                                    input(.type(.checkbox), .value("write"), .class("mr-2 text-blue-600 bg-gray-700 border-gray-600 rounded focus:ring-blue-500"), .checked)
                                    span(.class("text-sm text-gray-300")) { "Write" }
                                }
                                label(.class("flex items-center")) {
                                    input(.type(.checkbox), .value("admin"), .class("mr-2 text-blue-600 bg-gray-700 border-gray-600 rounded focus:ring-blue-500"))
                                    span(.class("text-sm text-gray-300")) { "Admin" }
                                }
                            }
                        }
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-300 mb-2")) {
                                "Expires In (days)"
                            }
                            select(
                                .id("apiKeyExpiry"),
                                .class("w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-gray-100 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500")
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
                div(.class("px-6 py-4 border-t border-gray-700 flex justify-end space-x-3")) {
                    button(
                        .id("cancelApiKeyBtn"),
                        .type(.button),
                        .class("px-4 py-2 text-sm font-medium text-gray-300 bg-gray-700 hover:bg-gray-600 rounded-md transition-colors"),
                        .custom(name: "onclick", value: "hideModal('createApiKeyModal')")
                    ) {
                        "Cancel"
                    }
                    button(
                        .id("submitApiKeyBtn"),
                        .type(.button),
                        .class("px-4 py-2 text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 rounded-md transition-colors")
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
            .class("fixed inset-0 bg-black bg-opacity-60 hidden flex items-center justify-center z-50")
        ) {
            div(.class("bg-gray-800 rounded-lg shadow-xl max-w-lg w-full mx-4 border border-gray-600")) {
                CreateVMModalHeader()
                CreateVMModalContent()
                CreateVMModalFooter()
            }
        }
    }
}

struct CreateVMModalHeader: HTML {
    var content: some HTML {
        div(.class("px-6 py-4 border-b border-gray-700")) {
            h3(.class("text-lg font-medium text-gray-100")) {
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
            label(.class("block text-sm font-medium text-gray-300 mb-2")) {
                "VM Name"
            }
            input(
                .type(.text),
                .id("vmName"),
                .class("w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-gray-100 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"),
                .required
            )
        }
        div {
            label(.class("block text-sm font-medium text-gray-300 mb-2")) {
                "Description"
            }
            textarea(
                .id("vmDescription"),
                .class("w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-gray-100 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500 h-20"),
                .required
            ) {}
        }
    }
}

struct CreateVMFormResourcesTemplate: HTML {
    var content: some HTML {
        div(.class("grid grid-cols-2 gap-4")) {
            div {
                label(.class("block text-sm font-medium text-gray-300 mb-2")) {
                    "CPU Cores"
                }
                input(
                    .type(.number),
                    .id("vmCpu"),
                    .class("w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-gray-100 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"),
                    .value("1"),
                    .required
                )
            }
            div {
                label(.class("block text-sm font-medium text-gray-300 mb-2")) {
                    "Memory (GB)"
                }
                input(
                    .type(.number),
                    .id("vmMemory"),
                    .class("w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-gray-100 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"),
                    .value("2"),
                    .required
                )
            }
        }
        div(.class("grid grid-cols-2 gap-4")) {
            div {
                label(.class("block text-sm font-medium text-gray-300 mb-2")) {
                    "Disk (GB)"
                }
                input(
                    .type(.number),
                    .id("vmDisk"),
                    .class("w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-gray-100 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"),
                    .value("10"),
                    .required
                )
            }
            div {
                label(.class("block text-sm font-medium text-gray-300 mb-2")) {
                    "Template"
                }
                select(
                    .id("vmTemplate"),
                    .class("w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-gray-100 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"),
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
        div(.class("px-6 py-4 border-t border-gray-700 flex justify-end space-x-3")) {
            button(
                .id("cancelVMBtn"),
                .type(.button),
                .class("px-4 py-2 text-sm font-medium text-gray-300 bg-gray-700 hover:bg-gray-600 rounded-md transition-colors"),
                .custom(name: "onclick", value: "hideModal('createVMModal')")
            ) {
                "Cancel"
            }
            button(
                .id("submitVMBtn"),
                .type(.submit),
                .class("px-4 py-2 text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 rounded-md transition-colors")
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

struct CollapsibleSection<Content: HTML>: HTML {
    let id: String
    let title: String
    let icon: String
    let isExpanded: Bool
    @HTMLBuilder let sectionContent: () -> Content
    
    var content: some HTML {
        div(.class("mb-3")) {
            button(
                .class("w-full px-3 py-2 text-left flex items-center justify-between hover:bg-gray-800 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 transition-colors duration-150"),
                .custom(name: "onclick", value: "toggleSection('\(id)')")
            ) {
                div(.class("flex items-center space-x-3")) {
                    span(.class("text-base text-gray-400")) { icon }
                    span(.class("text-sm font-medium text-gray-200")) { title }
                }
                span(
                    .id("\(id)-chevron"),
                    .class("text-gray-500 transform transition-transform duration-150 \(isExpanded ? "rotate-90" : "")")
                ) { "▶" }
            }
            div(
                .id("\(id)-content"),
                .class("mt-1 \(isExpanded ? "" : "hidden")")
            ) {
                sectionContent()
            }
        }
    }
}

struct DashboardSidebarSection: HTML {
    var content: some HTML {
        aside(.class("w-80 bg-gray-900 border-r border-gray-700 overflow-y-auto")) {
            div(.class("p-4 space-y-1")) {
                CollapsibleSection(
                    id: "vms-section",
                    title: "Virtual Machines",
                    icon: "💻",
                    isExpanded: true
                ) {
                    VMTableSection()
                }
                
                CollapsibleSection(
                    id: "storage-section",
                    title: "Storage",
                    icon: "💿",
                    isExpanded: false
                ) {
                    StoragePlaceholder()
                }
                
                CollapsibleSection(
                    id: "networking-section",
                    title: "Networking",
                    icon: "🌐",
                    isExpanded: false
                ) {
                    NetworkingPlaceholder()
                }
                
                CollapsibleSection(
                    id: "nodes-section",
                    title: "Nodes",
                    icon: "🖥️",
                    isExpanded: false
                ) {
                    NodesSection()
                }
                
                CollapsibleSection(
                    id: "settings-section",
                    title: "Settings",
                    icon: "⚙️",
                    isExpanded: false
                ) {
                    SettingsSection()
                }
            }
        }
    }
}

struct VMTableSection: HTML {
    var content: some HTML {
        div(.class("ml-6 overflow-hidden rounded-md border border-gray-700")) {
            table(.class("min-w-full")) {
                VMTableHeader()
                VMTableBody()
            }
        }
    }
}

struct VMTableHeader: HTML {
    var content: some HTML {
        thead(.class("bg-gray-800")) {
            tr {
                th(.class("px-3 py-2 text-left text-xs font-medium text-gray-400 uppercase tracking-wider")) {
                    "Name"
                }
                th(.class("px-3 py-2 text-left text-xs font-medium text-gray-400 uppercase tracking-wider")) {
                    "Status"
                }
                th(.class("px-3 py-2 text-left text-xs font-medium text-gray-400 uppercase tracking-wider")) {
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
            .class("bg-gray-800 divide-y divide-gray-700"),
            .custom(name: "hx-trigger", value: "load"),
            .custom(name: "hx-get", value: "/htmx/vms/list"),
            .custom(name: "hx-swap", value: "innerHTML")
        ) {
            tr {
                td(.class("px-3 py-4 text-sm text-gray-400 text-center"), .custom(name: "colspan", value: "3")) {
                    "Loading VMs..."
                }
            }
        }
    }
}

struct StoragePlaceholder: HTML {
    var content: some HTML {
        div(.class("ml-6 space-y-2")) {
            div(.class("text-xs text-gray-500 text-center py-3")) {
                "Storage management coming soon..."
            }
            div(.class("space-y-1")) {
                div(.class("flex items-center justify-between p-2 bg-gray-800 rounded text-sm hover:bg-gray-700")) {
                    span(.class("text-gray-300")) { "Volumes" }
                    span(.class("text-xs text-gray-500")) { "0" }
                }
                div(.class("flex items-center justify-between p-2 bg-gray-800 rounded text-sm hover:bg-gray-700")) {
                    span(.class("text-gray-300")) { "Snapshots" }
                    span(.class("text-xs text-gray-500")) { "0" }
                }
            }
        }
    }
}

struct NetworkingPlaceholder: HTML {
    var content: some HTML {
        div(.class("ml-6 space-y-2")) {
            div(.class("text-xs text-gray-500 text-center py-3")) {
                "Network management coming soon..."
            }
            div(.class("space-y-1")) {
                div(.class("flex items-center justify-between p-2 bg-gray-800 rounded text-sm hover:bg-gray-700")) {
                    span(.class("text-gray-300")) { "Networks" }
                    span(.class("text-xs text-gray-500")) { "0" }
                }
                div(.class("flex items-center justify-between p-2 bg-gray-800 rounded text-sm hover:bg-gray-700")) {
                    span(.class("text-gray-300")) { "Subnets" }
                    span(.class("text-xs text-gray-500")) { "0" }
                }
            }
        }
    }
}

struct NodesSection: HTML {
    var content: some HTML {
        div(.class("ml-6 space-y-2")) {
            // Quick Stats
            div(.class("space-y-1")) {
                div(
                    .id("agent-stats"),
                    .class("space-y-1"),
                    .custom(name: "hx-get", value: "/htmx/agents/stats"),
                    .custom(name: "hx-trigger", value: "load, every 30s"),
                    .custom(name: "hx-swap", value: "innerHTML")
                ) {
                    div(.class("flex items-center justify-between p-2 bg-gray-800 rounded text-sm")) {
                        span(.class("text-gray-300")) { "Connected Agents" }
                        span(.class("text-xs text-gray-500")) { "Loading..." }
                    }
                }
            }
            
            // Action buttons
            div(.class("space-y-1 mt-3")) {
                a(
                    .class("flex items-center space-x-2 p-2 text-sm text-blue-400 hover:bg-gray-800 hover:text-blue-300 rounded transition-colors"),
                    .href("/agents")
                ) {
                    span(.class("text-blue-500")) { "⚙️" }
                    span { "Manage Agents" }
                }
                
                button(
                    .class("w-full flex items-center space-x-2 p-2 text-sm text-green-400 hover:bg-gray-800 hover:text-green-300 rounded transition-colors text-left"),
                    .custom(name: "onclick", value: "showModal('addAgentModal')")
                ) {
                    span(.class("text-green-500")) { "+" }
                    span { "Add New Agent" }
                }
            }
        }
    }
}

struct SettingsSection: HTML {
    var content: some HTML {
        div(.class("ml-6 space-y-1")) {
            a(
                .class("flex items-center space-x-3 p-2 text-sm text-gray-300 hover:bg-gray-800 hover:text-white rounded transition-colors"),
                .href("/htmx/organizations/settings")
            ) {
                span(.class("text-gray-500")) { "🏢" }
                span { "Organization Settings" }
            }
            button(
                .class("flex items-center space-x-3 p-2 text-sm text-gray-300 hover:bg-gray-800 hover:text-white rounded w-full text-left transition-colors"),
                .custom(name: "onclick", value: "showModal('apiKeysModal')")
            ) {
                span(.class("text-gray-500")) { "🔑" }
                span { "API Keys" }
            }
            a(
                .class("flex items-center space-x-3 p-2 text-sm text-gray-300 hover:bg-gray-800 hover:text-white rounded transition-colors"),
                .href("#")
            ) {
                span(.class("text-gray-500")) { "👤" }
                span { "User Preferences" }
            }
        }
    }
}

struct DashboardContentSection: HTML {
    var content: some HTML {
        main(.class("flex-1 flex flex-col overflow-hidden bg-gray-900")) {
            div(.class("bg-gray-800 border-b border-gray-700 px-6 py-4")) {
                h1(.class("text-lg font-semibold text-gray-100")) { "Dashboard" }
                p(.class("text-sm text-gray-300")) {
                    "Manage your virtual machines and infrastructure"
                }
            }

            div(.class("flex-1 p-6 overflow-y-auto bg-gray-900")) {
                div(.class("grid grid-cols-1 lg:grid-cols-2 gap-6 h-full")) {
                    div(
                        .class("bg-gray-800 rounded-lg shadow-sm border border-gray-700 p-6")
                    ) {
                        h3(.class("text-lg font-medium text-gray-100 mb-4")) {
                            "VM Details"
                        }
                        div(.id("vmDetails"), .class("text-gray-400")) {
                            "Select a virtual machine to view details"
                        }
                    }

                    div(
                        .class("bg-gray-800 rounded-lg shadow-sm border border-gray-700 p-6")
                    ) {
                        h3(.class("text-lg font-medium text-gray-100 mb-4")) { "Console" }
                        div(
                            .id("terminal"), .class("border border-gray-600 rounded h-96 bg-gray-900")
                        ) {}
                    }
                }
            }
        }
    }
}

struct AddAgentModal: HTML {
    var content: some HTML {
        div(
            .id("addAgentModal"),
            .class("fixed inset-0 bg-black bg-opacity-60 hidden flex items-center justify-center z-50")
        ) {
            div(.class("bg-gray-800 rounded-lg shadow-xl max-w-2xl w-full mx-4 border border-gray-600")) {
                div(.class("px-6 py-4 border-b border-gray-700")) {
                    div(.class("flex justify-between items-center")) {
                        h3(.class("text-lg font-medium text-gray-100")) {
                            "Add New Agent"
                        }
                        button(
                            .class("text-gray-400 hover:text-gray-200 transition-colors"),
                            .custom(name: "onclick", value: "hideModal('addAgentModal')")
                        ) {
                            "✕"
                        }
                    }
                }
                div(.class("px-6 py-4")) {
                    div(.class("space-y-4")) {
                        div(.class("bg-gray-700 border border-gray-600 rounded-lg p-4")) {
                            h4(.class("text-md font-medium text-gray-200 mb-2")) {
                                "Quick Setup"
                            }
                            p(.class("text-sm text-gray-400 mb-3")) {
                                "Generate a registration token and get the command to add a new agent to your cluster."
                            }
                            a(
                                .href("/agents"),
                                .class("inline-block bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded text-sm font-medium transition-colors")
                            ) {
                                "Go to Agent Management →"
                            }
                        }
                        
                        div(.class("border-t border-gray-600 pt-4")) {
                            h4(.class("text-md font-medium text-gray-200 mb-3")) {
                                "Prerequisites"
                            }
                            ul(.class("text-sm text-gray-400 space-y-2 list-disc list-inside")) {
                                li { "Linux system with KVM support (/dev/kvm accessible)" }
                                li { "Docker and Docker Compose installed" }
                                li { "Network connectivity to this control plane" }
                                li { "Sufficient resources (CPU, RAM, disk) for VMs" }
                            }
                        }
                    }
                }
                div(.class("px-6 py-4 border-t border-gray-700 flex justify-end")) {
                    button(
                        .class("bg-gray-600 hover:bg-gray-700 text-white px-4 py-2 rounded text-sm font-medium transition-colors"),
                        .custom(name: "onclick", value: "hideModal('addAgentModal')")
                    ) {
                        "Close"
                    }
                }
            }
        }
    }
}
