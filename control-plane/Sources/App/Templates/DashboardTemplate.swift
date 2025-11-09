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
        script(.src("https://unpkg.com/hyperscript.org@0.9.12")) { "" }
        script(.src("https://cdn.jsdelivr.net/npm/xterm@4.19.0/lib/xterm.js")) { "" }
    }

    var body: some HTML {
        Elementary.body(.class("bg-gray-900 text-gray-100 min-h-screen")) {
            DashboardHeader()
            DashboardMain()
            AllModals()

            // Terminal initialization - MUST keep for xterm.js
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

            // Console logging function for HTMX responses
            function logToConsole(message) {
                term.write(`\\r\\n${message}\\r\\n$ `);
            }
            window.logToConsole = logToConsole;

            // Restore sidebar section states from localStorage on page load
            document.addEventListener('DOMContentLoaded', () => {
                const sections = ['vms-section', 'storage-section', 'networking-section', 'nodes-section', 'settings-section'];
                sections.forEach(sectionId => {
                    const state = localStorage.getItem('sidebar-' + sectionId);
                    if (state === 'expanded') {
                        const content = document.getElementById(sectionId + '-content');
                        const chevron = document.getElementById(sectionId + '-chevron');
                        if (content) content.classList.remove('hidden');
                        if (chevron) chevron.classList.add('rotate-90');
                    }
                });
            });
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
                            .custom(name: "_", value: "on click toggle .hidden on #orgDropdown")
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
                                div(.class("border-t border-gray-700 mt-1")) {
                                    button(
                                        .class("w-full text-left px-4 py-2 text-sm text-blue-400 hover:bg-gray-700 transition-colors"),
                                        .custom(name: "_", value: "on click remove .hidden from #createOrgModal")
                                    ) {
                                        "+ Create New Organization"
                                    }
                                }
                            }
                        }
                    }

                    // Logout Button
                    form(
                        .custom(name: "hx-post", value: "/logout"),
                        .custom(name: "hx-swap", value: "none")
                    ) {
                        button(
                            .type(.submit),
                            .class("text-gray-400 hover:text-gray-200")
                        ) { "Logout" }
                    }
                }
            }
        }
    }
}

struct DashboardMain: HTML {
    var content: some HTML {
        main(.class("flex h-[calc(100vh-4rem)]")) {
            DashboardSidebar()
            DashboardContent()
        }
    }
}

struct DashboardSidebar: HTML {
    var content: some HTML {
        aside(.class("w-64 bg-gray-800 border-r border-gray-700 overflow-y-auto")) {
            nav(.class("px-3 py-4 space-y-1")) {
                // Dashboard Link
                a(
                    .href("/dashboard"),
                    .class("flex items-center px-3 py-2 text-sm font-medium rounded-md text-gray-300 hover:bg-gray-700")
                ) {
                    "📊 Dashboard"
                }

                // VMs Section
                SidebarSection(
                    id: "vms-section",
                    title: "🖥️ Virtual Machines",
                    items: [
                        SidebarItem(label: "All VMs", action: "showModal('createVMModal')"),
                        SidebarItem(label: "+ New VM", action: "showModal('createVMModal')")
                    ]
                )

                // Storage Section
                SidebarSection(
                    id: "storage-section",
                    title: "💾 Storage",
                    items: [
                        SidebarItem(label: "Volumes", action: ""),
                        SidebarItem(label: "Snapshots", action: "")
                    ]
                )

                // Networking Section
                SidebarSection(
                    id: "networking-section",
                    title: "🌐 Networking",
                    items: [
                        SidebarItem(label: "Networks", action: ""),
                        SidebarItem(label: "Load Balancers", action: "")
                    ]
                )

                // Nodes Section
                SidebarSection(
                    id: "nodes-section",
                    title: "🖧 Compute Nodes",
                    items: [
                        SidebarItem(label: "Agents", action: "showModal('addAgentModal')"),
                        SidebarItem(label: "+ Add Agent", action: "showModal('addAgentModal')")
                    ]
                )

                // Settings Section
                SidebarSection(
                    id: "settings-section",
                    title: "⚙️ Settings",
                    items: [
                        SidebarItem(label: "Organization", action: ""),
                        SidebarItem(label: "API Keys", action: "showModal('apiKeysModal')")
                    ]
                )
            }
        }
    }
}

struct DashboardContent: HTML {
    var content: some HTML {
        div(.class("flex-1 overflow-y-auto p-6")) {
            div(.class("max-w-7xl mx-auto")) {
                // Header
                div(.class("mb-6")) {
                    h2(.class("text-2xl font-semibold text-gray-100")) { "Dashboard" }
                    p(.class("text-gray-400")) { "Manage your virtual infrastructure" }
                }

                // VM List
                div(.class("bg-gray-800 rounded-lg shadow-xl border border-gray-700 overflow-hidden")) {
                    div(.class("px-6 py-4 border-b border-gray-700 flex items-center justify-between")) {
                        h3(.class("text-lg font-semibold text-gray-100")) { "Virtual Machines" }
                        button(
                            .class("bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md text-sm font-medium transition-colors"),
                            .custom(name: "_", value: "on click remove .hidden from #createVMModal")
                        ) {
                            "+ Create VM"
                        }
                    }
                    div(.class("overflow-x-auto")) {
                        table(.class("w-full")) {
                            thead(.class("bg-gray-900")) {
                                tr {
                                    th(.class("px-3 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider")) { "Name" }
                                    th(.class("px-3 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider")) { "Status" }
                                    th(.class("px-3 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider")) { "Actions" }
                                }
                            }
                            tbody(
                                .id("vmTableBody"),
                                .class("bg-gray-800 divide-y divide-gray-700"),
                                .custom(name: "hx-get", value: "/htmx/vms/list"),
                                .custom(name: "hx-trigger", value: "load, every 5s"),
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
                }

                // VM Details Panel
                div(
                    .id("vmDetails"),
                    .class("mt-6 bg-gray-800 rounded-lg shadow-xl border border-gray-700 p-6")
                ) {
                    p(.class("text-gray-400 text-center")) { "Select a VM to view details" }
                }

                // Terminal
                div(.class("mt-6 bg-gray-900 rounded-lg shadow-xl border border-gray-700 overflow-hidden")) {
                    div(.class("px-4 py-3 bg-gray-800 border-b border-gray-700")) {
                        h3(.class("text-sm font-semibold text-gray-300")) { "Console" }
                    }
                    div(.id("terminal"), .class("p-4 h-64 overflow-y-auto")) {}
                }
            }
        }
    }
}

struct AllModals: HTML {
    var content: some HTML {
        // Create VM Modal
        Modal(
            id: "createVMModal",
            title: "Create Virtual Machine",
            modalContent: CreateVMForm()
        )

        // Create Organization Modal
        Modal(
            id: "createOrgModal",
            title: "Create Organization",
            modalContent: CreateOrganizationForm()
        )

        // API Keys Modal
        Modal(
            id: "apiKeysModal",
            title: "API Keys",
            modalContent: APIKeysContent()
        )

        // Create API Key Modal
        Modal(
            id: "createApiKeyModal",
            title: "Create API Key",
            modalContent: CreateAPIKeyForm()
        )

        // Add Agent Modal
        Modal(
            id: "addAgentModal",
            title: "Add Compute Agent",
            modalContent: AddAgentForm()
        )
    }
}

struct CreateVMForm: HTML {
    var content: some HTML {
        form(
            .id("createVMForm"),
            .custom(name: "hx-post", value: "/htmx/vms/create"),
            .custom(name: "hx-target", value: "#vmTableBody"),
            .custom(name: "hx-swap", value: "innerHTML"),
            .custom(name: "_", value: "on htmx:afterRequest add .hidden to #createVMModal")
        ) {
            div(.class("space-y-4")) {
                // Form fields
                FormField(id: "vmName", label: "VM Name", type: "text", placeholder: "my-vm", required: true)
                FormField(id: "vmDescription", label: "Description", type: "text", placeholder: "Production web server")
                FormField(id: "vmTemplate", label: "OS Template", type: "text", placeholder: "ubuntu-22.04", required: true)
                FormField(id: "vmCpu", label: "CPU Cores", type: "number", placeholder: "2", required: true)
                FormField(id: "vmMemory", label: "Memory (GB)", type: "number", placeholder: "4", required: true)
                FormField(id: "vmDisk", label: "Disk (GB)", type: "number", placeholder: "50", required: true)

                div(.class("flex justify-end space-x-3")) {
                    button(
                        .type(.button),
                        .class("px-4 py-2 border border-gray-600 rounded-md text-sm font-medium text-gray-300 hover:bg-gray-700"),
                        .custom(name: "_", value: "on click add .hidden to #createVMModal")
                    ) { "Cancel" }
                    button(
                        .type(.submit),
                        .class("px-4 py-2 bg-blue-600 hover:bg-blue-700 rounded-md text-sm font-medium text-white")
                    ) { "Create VM" }
                }
            }
        }
    }
}

struct CreateOrganizationForm: HTML {
    var content: some HTML {
        div { p(.class("text-gray-400")) { "Organization creation form placeholder" } }
    }
}

struct APIKeysContent: HTML {
    var content: some HTML {
        div { p(.class("text-gray-400")) { "API Keys management placeholder" } }
    }
}

struct CreateAPIKeyForm: HTML {
    var content: some HTML {
        div { p(.class("text-gray-400")) { "Create API Key form placeholder" } }
    }
}

struct AddAgentForm: HTML {
    var content: some HTML {
        div { p(.class("text-gray-400")) { "Add Agent form placeholder" } }
    }
}

