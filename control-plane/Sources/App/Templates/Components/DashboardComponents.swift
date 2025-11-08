import Elementary
import ElementaryHTMX

// MARK: - Modal

struct Modal: HTML {
    let id: String
    let title: String
    let content: HTML

    var content: some HTML {
        div(
            .id(id),
            .class("hidden fixed inset-0 bg-black bg-opacity-50 z-50 flex items-center justify-center"),
            .custom(name: "_", value: "on keydown[key=='Escape'] add .hidden")
        ) {
            div(.class("bg-gray-800 rounded-lg shadow-2xl border border-gray-700 max-w-2xl w-full mx-4 max-h-[90vh] overflow-y-auto")) {
                div(.class("px-6 py-4 border-b border-gray-700 flex items-center justify-between")) {
                    h3(.class("text-lg font-semibold text-gray-100")) { title }
                    button(
                        .class("text-gray-400 hover:text-gray-200"),
                        .custom(name: "_", value: "on click add .hidden to #\(id)")
                    ) { "✕" }
                }
                div(.class("px-6 py-4")) {
                    self.content
                }
            }
        }
    }
}

// MARK: - Form Field

struct FormField: HTML {
    let id: String
    let label: String
    let type: String
    let placeholder: String
    let required: Bool

    init(id: String, label: String, type: String, placeholder: String, required: Bool = false) {
        self.id = id
        self.label = label
        self.type = type
        self.placeholder = placeholder
        self.required = required
    }

    var content: some HTML {
        div {
            label(.for(id), .class("block text-sm font-medium text-gray-300 mb-1")) { label }
            input(
                .type(InputType(rawValue: type) ?? .text),
                .id(id),
                .name(id),
                .class("w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-gray-100 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500"),
                .placeholder(placeholder),
                .required(required)
            )
        }
    }
}

// MARK: - Sidebar Section

struct SidebarSection: HTML {
    let id: String
    let title: String
    let items: [SidebarItem]

    var content: some HTML {
        div {
            button(
                .class("w-full flex items-center justify-between px-3 py-2 text-sm font-medium rounded-md text-gray-300 hover:bg-gray-700"),
                .custom(name: "_", value: """
                on click
                  toggle .hidden on #\(id)-content
                  toggle .rotate-90 on #\(id)-chevron
                  if #\(id)-content.classList.contains('hidden')
                    then js localStorage.setItem('sidebar-\(id)', 'collapsed') end
                    else js localStorage.setItem('sidebar-\(id)', 'expanded') end
                """)
            ) {
                span { title }
                span(
                    .id("\(id)-chevron"),
                    .class("text-gray-500 transition-transform")
                ) { "›" }
            }
            div(
                .id("\(id)-content"),
                .class("ml-3 space-y-1")
            ) {
                ForEach(items) { item in
                    if !item.action.isEmpty {
                        button(
                            .class("w-full text-left px-3 py-1 text-sm text-gray-400 hover:text-gray-200 hover:bg-gray-700 rounded"),
                            .custom(name: "_", value: "on click remove .hidden from #\(item.action.replacingOccurrences(of: "showModal('", with: "").replacingOccurrences(of: "')", with: ""))")
                        ) {
                            item.label
                        }
                    } else {
                        div(.class("px-3 py-1 text-sm text-gray-500")) {
                            item.label
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Sidebar Item

struct SidebarItem: HTML {
    let label: String
    let action: String

    var content: some HTML {
        div {}
    }
}

// MARK: - Create VM Form

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

// MARK: - Placeholder Forms

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
