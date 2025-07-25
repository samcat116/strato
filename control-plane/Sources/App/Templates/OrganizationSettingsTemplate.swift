import Elementary

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
        }
        
        HTMLRaw("""
        <script type="text/javascript">
            // Organization settings JavaScript
            document.addEventListener('DOMContentLoaded', function() {
                document.getElementById('saveButton').addEventListener('click', updateOrganizationInfo);
            });
            
            function showSuccess(message) {
                const notification = document.createElement('div');
                notification.className = 'fixed top-4 right-4 bg-green-500 text-white px-6 py-3 rounded-lg shadow-lg z-50';
                notification.textContent = message;
                document.body.appendChild(notification);
                setTimeout(() => notification.remove(), 3000);
            }
            
            function showError(message) {
                const notification = document.createElement('div');
                notification.className = 'fixed top-4 right-4 bg-red-500 text-white px-6 py-3 rounded-lg shadow-lg z-50';
                notification.textContent = message;
                document.body.appendChild(notification);
                setTimeout(() => notification.remove(), 5000);
            }
            
            function updateOrganizationInfo() {
                const form = document.getElementById('organization-info-form');
                const formData = new FormData(form);
                
                const data = {
                    name: formData.get('name'),
                    description: formData.get('description')
                };
                
                console.log('Sending data:', data);
                const orgId = '\(organization.id?.uuidString ?? "")';
                console.log('URL:', '/organizations/' + orgId);
                
                fetch('/organizations/' + orgId, {
                    method: 'PUT',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify(data)
                })
                .then(response => {
                    console.log('Response status:', response.status);
                    if (response.ok) {
                        return response.json();
                    }
                    return response.text().then(text => {
                        console.log('Error response:', text);
                        throw new Error(`Failed to update organization: ${response.status} - ${text}`);
                    });
                })
                .then(data => {
                    showSuccess('Organization updated successfully');
                    // Update the page title and header if name changed
                    const currentName = '\(organization.name)';
                    if (data.name !== currentName) {
                        document.title = 'Organization Settings - ' + data.name + ' - Strato';
                        document.getElementById('org-name-header').textContent = data.name;
                    }
                })
                .catch(error => {
                    console.error('Fetch error:', error);
                    showError(error.message);
                });
            }
        </script>
        """)
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
                        div(.class("bg-gray-100 text-gray-900 group flex items-center px-3 py-2 text-sm font-medium rounded-md")) {
                            "📋 Organization Info"
                        }
                        
                        // Placeholder for future settings sections
                        div(.class("text-gray-400 px-3 py-2 text-sm")) {
                            "More settings coming soon..."
                        }
                    }
                }
                
                // Main content
                div(.class("lg:col-span-9")) {
                    OrganizationInfoSection(organization: organization)
                }
            }
        }
    }
}

struct OrganizationInfoSection: HTML {
    let organization: OrganizationResponse
    
    var content: some HTML {
        div(.class("bg-white shadow rounded-lg"), .id("organization-info")) {
            div(.class("px-6 py-4 border-b border-gray-200")) {
                h2(.class("text-lg font-medium text-gray-900")) {
                    "Organization Information"
                }
                p(.class("mt-1 text-sm text-gray-600")) {
                    "Update your organization's basic information and settings."
                }
            }
            
            div(.class("px-6 py-6")) {
                form(.id("organization-info-form")) {
                    div(.class("grid grid-cols-1 gap-6")) {
                        // Organization Name
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
                            p(.class("mt-2 text-xs text-gray-500")) {
                                "This name will be visible to all members of your organization."
                            }
                        }
                        
                        // Organization Description
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
                            p(.class("mt-2 text-xs text-gray-500")) {
                                "Provide a brief description of your organization's purpose or goals."
                            }
                        }
                    }
                    
                    div(.class("mt-6 flex justify-end")) {
                        button(
                            .type(.button),
                            .id("saveButton"),
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