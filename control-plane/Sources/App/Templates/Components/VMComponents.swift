import Elementary
import ElementaryHTMX
import StratoShared

// MARK: - VM List

struct VMListPartial: HTML {
    let vms: [VM]

    private func statusBadgeClass(for status: VMStatus) -> String {
        switch status {
        case .running:
            return "bg-green-900 text-green-300 border border-green-700"
        case .shutdown:
            return "bg-gray-900 text-gray-300 border border-gray-700"
        case .paused:
            return "bg-yellow-900 text-yellow-300 border border-yellow-700"
        case .created:
            return "bg-blue-900 text-blue-300 border border-blue-700"
        }
    }

    var content: some HTML {
        if vms.isEmpty {
            tr {
                td(.class("px-3 py-4 text-sm text-gray-400 text-center"), .custom(name: "colspan", value: "3")) {
                    "No VMs found. Create your first VM!"
                }
            }
        } else {
            ForEach(vms.filter { $0.id != nil }) { vm in
                let vmId = vm.id!.uuidString
                tr(
                    .class("hover:bg-gray-700 cursor-pointer transition-colors"),
                    .custom(name: "hx-get", value: "/htmx/vms/\(vmId)/details"),
                    .custom(name: "hx-target", value: "#vmDetails"),
                    .custom(name: "hx-swap", value: "innerHTML")
                ) {
                    td(.class("px-3 py-3")) {
                        div(.class("text-sm font-medium text-gray-200")) { vm.name }
                        div(.class("text-xs text-gray-400")) { vm.description }
                    }
                    td(.class("px-3 py-3")) {
                        span(.class("inline-flex px-2 py-1 text-xs rounded-full \(statusBadgeClass(for: vm.status))")) {
                            vm.status.rawValue
                        }
                    }
                    td(.class("px-3 py-3")) {
                        div(.class("flex space-x-1")) {
                            button(
                                .class("text-green-400 hover:text-green-300 text-xs transition-colors"),
                                .custom(name: "hx-post", value: "/htmx/vms/\(vmId)/start"),
                                .custom(name: "hx-target", value: "#terminal"),
                                .custom(name: "hx-on::after-request", value: "logToConsole('VM start command sent')")
                            ) { "▶" }
                            button(
                                .class("text-yellow-400 hover:text-yellow-300 text-xs transition-colors"),
                                .custom(name: "hx-post", value: "/htmx/vms/\(vmId)/stop"),
                                .custom(name: "hx-target", value: "#terminal"),
                                .custom(name: "hx-on::after-request", value: "logToConsole('VM stop command sent')")
                            ) { "⏸" }
                            button(
                                .class("text-red-400 hover:text-red-300 text-xs transition-colors"),
                                .custom(name: "hx-delete", value: "/htmx/vms/\(vmId)"),
                                .custom(name: "hx-target", value: "#vmTableBody"),
                                .custom(name: "hx-swap", value: "innerHTML"),
                                .custom(name: "hx-confirm", value: "Are you sure you want to delete this VM?"),
                                .custom(name: "hx-on::after-request", value: "logToConsole('VM deleted')")
                            ) { "🗑" }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - VM Details

struct VMDetailsPartial: HTML {
    let vm: VM

    var content: some HTML {
        let vmId = vm.id?.uuidString ?? "unknown"
        div(.class("space-y-4")) {
            div {
                h4(.class("text-lg font-semibold text-gray-100")) { vm.name }
                p(.class("text-sm text-gray-300")) { vm.description }
            }
            div(.class("grid grid-cols-2 gap-4")) {
                div {
                    label(.class("block text-sm font-medium text-gray-400")) { "CPU Cores" }
                    p(.class("text-sm text-gray-100")) { String(vm.cpu) }
                }
                div {
                    label(.class("block text-sm font-medium text-gray-400")) { "Memory" }
                    p(.class("text-sm text-gray-100")) { "\(String(format: "%.1f", Double(vm.memory) / (1024 * 1024 * 1024))) GB" }
                }
                div {
                    label(.class("block text-sm font-medium text-gray-400")) { "Disk" }
                    p(.class("text-sm text-gray-100")) { "\(vm.disk / (1024 * 1024 * 1024)) GB" }
                }
                div {
                    label(.class("block text-sm font-medium text-gray-400")) { "Image" }
                    p(.class("text-sm text-gray-100")) { vm.image }
                }
            }
            div(.class("flex space-x-3 pt-4")) {
                button(
                    .class("bg-green-600 hover:bg-green-700 text-white px-4 py-2 rounded-md text-sm transition-colors"),
                    .custom(name: "hx-post", value: "/htmx/vms/\(vmId)/start")
                ) { "Start" }
                button(
                    .class("bg-yellow-600 hover:bg-yellow-700 text-white px-4 py-2 rounded-md text-sm transition-colors"),
                    .custom(name: "hx-post", value: "/htmx/vms/\(vmId)/stop")
                ) { "Stop" }
                button(
                    .class("bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md text-sm transition-colors"),
                    .custom(name: "hx-post", value: "/htmx/vms/\(vmId)/restart")
                ) { "Restart" }
                button(
                    .class("bg-red-600 hover:bg-red-700 text-white px-4 py-2 rounded-md text-sm transition-colors"),
                    .custom(name: "hx-delete", value: "/htmx/vms/\(vmId)"),
                    .custom(name: "hx-target", value: "#vmTableBody"),
                    .custom(name: "hx-swap", value: "innerHTML"),
                    .custom(name: "hx-confirm", value: "Are you sure you want to delete this VM?")
                ) { "Delete" }
            }
        }
    }
}

// MARK: - VM Action Response

struct VMActionResponsePartial: HTML {
    let message: String

    var content: some HTML {
        div { message }
    }
}
