import Elementary
import ElementaryHTMX

// MARK: - API Key List

struct APIKeyListPartial: HTML {
    let apiKeys: [APIKey]

    var content: some HTML {
        if apiKeys.isEmpty {
            div(.class("text-center text-gray-400 py-8")) {
                "No API keys found. Create your first API key!"
            }
        } else {
            div(.class("space-y-4")) {
                ForEach(apiKeys) { key in
                    div(.class("border border-gray-600 bg-gray-700 rounded-lg p-4")) {
                        div(.class("flex justify-between items-start")) {
                            div(.class("flex-1")) {
                                h4(.class("font-medium text-gray-100")) { key.name }
                                p(.class("text-sm text-gray-400 font-mono")) { key.keyPrefix }
                            }
                            div(.class("flex space-x-2")) {
                                button(
                                    .class("text-sm px-3 py-1 rounded bg-red-900 text-red-300 hover:bg-red-800 transition-colors border border-red-700"),
                                    .custom(name: "hx-delete", value: "/htmx/api-keys/\(key.id?.uuidString ?? "")"),
                                    .custom(name: "hx-target", value: "#apiKeysList"),
                                    .custom(name: "hx-swap", value: "innerHTML")
                                ) { "Delete" }
                            }
                        }
                    }
                }
            }
        }
    }
}
