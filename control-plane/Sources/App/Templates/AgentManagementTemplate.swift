import Elementary
import ElementaryHTMX

struct AgentManagementTemplate {
    func render() -> String {
        return html {
            head {
                meta(.name("viewport"), .content("width=device-width, initial-scale=1.0"))
                meta(.charset(.utf8))
                title("Agent Management - Strato")
                link(.rel(.stylesheet), .href("/styles/app.generated.css"))
                script(.src("https://unpkg.com/htmx.org@1.9.8"))
                script(.src("/js/webauthn.js"))
            }
            body(.class("bg-gray-900 text-white min-h-screen")) {
                div(.class("container mx-auto px-4 py-8")) {
                    // Header
                    div(.class("flex justify-between items-center mb-8")) {
                        div {
                            h1(.class("text-3xl font-bold")) { "Agent Management" }
                            p(.class("text-gray-400 mt-2")) { "Manage hypervisor agents and registration tokens" }
                        }
                        a(.href("/"), .class("bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded")) {
                            "← Back to Dashboard"
                        }
                    }
                    
                    // Create Registration Token Section
                    div(.class("bg-gray-800 rounded-lg p-6 mb-8")) {
                        h2(.class("text-xl font-semibold mb-4")) { "Generate Registration Token" }
                        p(.class("text-gray-400 mb-4")) { 
                            "Create a registration token to allow new agents to connect to the control plane." 
                        }
                        
                        form(.class("flex flex-col sm:flex-row gap-4"),
                             .hx_post("/htmx/agents/registration-tokens"),
                             .hx_target("#registration-result"),
                             .hx_trigger("submit")) {
                            div(.class("flex-1")) {
                                label(.class("block text-sm font-medium mb-2"), .for("agent-name")) {
                                    "Agent Name"
                                }
                                input(.type(.text),
                                      .id("agent-name"),
                                      .name("agentName"),
                                      .class("w-full bg-gray-700 border border-gray-600 rounded px-3 py-2 text-white placeholder-gray-400"),
                                      .placeholder("e.g., hypervisor-01"),
                                      .required(true))
                            }
                            div(.class("w-32")) {
                                label(.class("block text-sm font-medium mb-2"), .for("expiration-hours")) {
                                    "Expires (hours)"
                                }
                                input(.type(.number),
                                      .id("expiration-hours"),
                                      .name("expirationHours"),
                                      .class("w-full bg-gray-700 border border-gray-600 rounded px-3 py-2 text-white"),
                                      .value("1"),
                                      .min("1"),
                                      .max("168"))
                            }
                            button(.type(.submit),
                                   .class("bg-green-600 hover:bg-green-700 text-white px-6 py-2 rounded font-medium h-10 mt-6 sm:mt-0")) {
                                "Generate Token"
                            }
                        }
                        
                        div(.id("registration-result"), .class("mt-4")) {
                            // Results will be inserted here via HTMX
                        }
                    }
                    
                    // Agent List
                    div(.class("bg-gray-800 rounded-lg p-6 mb-8")) {
                        div(.class("flex justify-between items-center mb-4")) {
                            h2(.class("text-xl font-semibold")) { "Registered Agents" }
                            button(.class("bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded"),
                                   .hx_get("/htmx/agents"),
                                   .hx_target("#agents-table"),
                                   .hx_trigger("click")) {
                                "Refresh"
                            }
                        }
                        
                        div(.id("agents-table"),
                            .hx_get("/htmx/agents"),
                            .hx_trigger("load") // Load on page load
                            ) {
                            // Agent table will be loaded here
                            div(.class("text-center py-8 text-gray-400")) {
                                "Loading agents..."
                            }
                        }
                    }
                    
                    // Registration Tokens List
                    div(.class("bg-gray-800 rounded-lg p-6")) {
                        div(.class("flex justify-between items-center mb-4")) {
                            h2(.class("text-xl font-semibold")) { "Registration Tokens" }
                            button(.class("bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded"),
                                   .hx_get("/htmx/agents/registration-tokens"),
                                   .hx_target("#tokens-table"),
                                   .hx_trigger("click")) {
                                "Refresh"
                            }
                        }
                        
                        div(.id("tokens-table"),
                            .hx_get("/htmx/agents/registration-tokens"),
                            .hx_trigger("load") // Load on page load
                            ) {
                            // Tokens table will be loaded here
                            div(.class("text-center py-8 text-gray-400")) {
                                "Loading tokens..."
                            }
                        }
                    }
                }
            }
        }.render()
    }
}

struct AgentListTemplate {
    let agents: [AgentResponse]
    
    func render() -> String {
        if agents.isEmpty {
            return div(.class("text-center py-8 text-gray-400")) {
                div(.class("text-4xl mb-2")) { "🤖" }
                div { "No agents registered yet" }
                div(.class("text-sm mt-2")) { 
                    "Generate a registration token above to register your first agent" 
                }
            }.render()
        }
        
        return div(.class("overflow-x-auto")) {
            table(.class("w-full")) {
                thead {
                    tr(.class("border-b border-gray-700")) {
                        th(.class("text-left py-3 px-4 font-medium text-gray-300")) { "Name" }
                        th(.class("text-left py-3 px-4 font-medium text-gray-300")) { "Hostname" }
                        th(.class("text-left py-3 px-4 font-medium text-gray-300")) { "Status" }
                        th(.class("text-left py-3 px-4 font-medium text-gray-300")) { "Version" }
                        th(.class("text-left py-3 px-4 font-medium text-gray-300")) { "Resources" }
                        th(.class("text-left py-3 px-4 font-medium text-gray-300")) { "Last Seen" }
                        th(.class("text-right py-3 px-4 font-medium text-gray-300")) { "Actions" }
                    }
                }
                tbody {
                    for agent in agents {
                        tr(.class("border-b border-gray-700 hover:bg-gray-750")) {
                            td(.class("py-3 px-4 font-medium")) { agent.name }
                            td(.class("py-3 px-4 text-gray-300")) { agent.hostname }
                            td(.class("py-3 px-4")) {
                                span(.class(statusBadgeClass(for: agent.status))) {
                                    statusText(for: agent.status, isOnline: agent.isOnline)
                                }
                            }
                            td(.class("py-3 px-4 text-gray-300")) { agent.version }
                            td(.class("py-3 px-4 text-gray-300 text-sm")) {
                                div { "CPU: \(agent.resources.availableCPU)/\(agent.resources.totalCPU)" }
                                div { "RAM: \(formatMemory(agent.resources.availableMemory))/\(formatMemory(agent.resources.totalMemory))" }
                            }
                            td(.class("py-3 px-4 text-gray-300 text-sm")) {
                                if let lastHeartbeat = agent.lastHeartbeat {
                                    timeAgo(lastHeartbeat)
                                } else {
                                    "Never"
                                }
                            }
                            td(.class("py-3 px-4 text-right")) {
                                button(.class("bg-red-600 hover:bg-red-700 text-white px-3 py-1 rounded text-sm"),
                                       .hx_delete("/api/agents/\(agent.id.uuidString)"),
                                       .hx_target("#agents-table"),
                                       .hx_trigger("click"),
                                       .hx_confirm("Are you sure you want to deregister this agent?")) {
                                    "Deregister"
                                }
                            }
                        }
                    }
                }
            }
        }.render()
    }
    
    private func statusBadgeClass(for status: AgentStatus) -> String {
        switch status {
        case .online:
            return "inline-block px-2 py-1 text-xs font-medium bg-green-900 text-green-300 rounded"
        case .offline:
            return "inline-block px-2 py-1 text-xs font-medium bg-red-900 text-red-300 rounded"
        case .connecting:
            return "inline-block px-2 py-1 text-xs font-medium bg-yellow-900 text-yellow-300 rounded"
        case .error:
            return "inline-block px-2 py-1 text-xs font-medium bg-red-900 text-red-300 rounded"
        }
    }
    
    private func statusText(for status: AgentStatus, isOnline: Bool) -> String {
        if status == .online && !isOnline {
            return "Stale"
        }
        return status.rawValue.capitalized
    }
    
    private func formatMemory(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1024 / 1024 / 1024
        return String(format: "%.1fGB", gb)
    }
    
    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h ago"
        } else {
            return "\(Int(interval / 86400))d ago"
        }
    }
}

struct RegistrationTokenListTemplate {
    let tokens: [AgentRegistrationTokenResponse]
    
    func render() -> String {
        if tokens.isEmpty {
            return div(.class("text-center py-8 text-gray-400")) {
                div(.class("text-4xl mb-2")) { "🎫" }
                div { "No registration tokens" }
                div(.class("text-sm mt-2")) { 
                    "Generate a token above to allow agents to register" 
                }
            }.render()
        }
        
        return div(.class("overflow-x-auto")) {
            table(.class("w-full")) {
                thead {
                    tr(.class("border-b border-gray-700")) {
                        th(.class("text-left py-3 px-4 font-medium text-gray-300")) { "Agent Name" }
                        th(.class("text-left py-3 px-4 font-medium text-gray-300")) { "Status" }
                        th(.class("text-left py-3 px-4 font-medium text-gray-300")) { "Expires" }
                        th(.class("text-left py-3 px-4 font-medium text-gray-300")) { "Registration Command" }
                        th(.class("text-right py-3 px-4 font-medium text-gray-300")) { "Actions" }
                    }
                }
                tbody {
                    for token in tokens {
                        tr(.class("border-b border-gray-700 hover:bg-gray-750")) {
                            td(.class("py-3 px-4 font-medium")) { token.agentName }
                            td(.class("py-3 px-4")) {
                                span(.class(token.isValid ? "inline-block px-2 py-1 text-xs font-medium bg-green-900 text-green-300 rounded" : "inline-block px-2 py-1 text-xs font-medium bg-red-900 text-red-300 rounded")) {
                                    token.isValid ? "Valid" : "Expired"
                                }
                            }
                            td(.class("py-3 px-4 text-gray-300 text-sm")) {
                                timeUntil(token.expiresAt)
                            }
                            td(.class("py-3 px-4 text-gray-300 text-xs")) {
                                if token.isValid {
                                    code(.class("bg-gray-700 px-2 py-1 rounded text-xs break-all")) {
                                        "strato-agent --registration-url \"\(token.registrationURL)\""
                                    }
                                } else {
                                    span(.class("text-gray-500")) { "Token expired" }
                                }
                            }
                            td(.class("py-3 px-4 text-right")) {
                                if token.isValid {
                                    button(.class("bg-blue-600 hover:bg-blue-700 text-white px-3 py-1 rounded text-sm mr-2"),
                                           .onclick("copyToClipboard('\(token.registrationURL)')")) {
                                        "Copy URL"
                                    }
                                }
                                button(.class("bg-red-600 hover:bg-red-700 text-white px-3 py-1 rounded text-sm"),
                                       .hx_delete("/api/agents/registration-tokens/\(token.id.uuidString)"),
                                       .hx_target("#tokens-table"),
                                       .hx_trigger("click"),
                                       .hx_confirm("Are you sure you want to revoke this token?")) {
                                    "Revoke"
                                }
                            }
                        }
                    }
                }
            }
            
            script {"""
                function copyToClipboard(text) {
                    navigator.clipboard.writeText(text).then(() => {
                        // You could show a toast notification here
                        console.log('Registration URL copied to clipboard');
                    });
                }
            """}
        }.render()
    }
    
    private func timeUntil(_ date: Date) -> String {
        let interval = date.timeIntervalSince(Date())
        
        if interval < 0 {
            return "Expired"
        } else if interval < 3600 {
            return "In \(Int(interval / 60))m"
        } else if interval < 86400 {
            return "In \(Int(interval / 3600))h"
        } else {
            return "In \(Int(interval / 86400))d"
        }
    }
}