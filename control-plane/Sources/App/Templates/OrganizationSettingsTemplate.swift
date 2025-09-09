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
                showOrganizationInfo(); // Show organization info by default
                
                // Add event delegation for data-action clicks
                document.addEventListener('click', function(e) {
                    const action = e.target.dataset.action;
                    if (action) {
                        switch(action) {
                            case 'showOrganizationInfo':
                                showOrganizationInfo();
                                break;
                            case 'showOIDCSettings':
                                showOIDCSettings();
                                break;
                            case 'showAddProviderForm':
                                showAddProviderForm();
                                break;
                            case 'hideAddProviderForm':
                                hideAddProviderForm();
                                break;
                            case 'saveOIDCProvider':
                                saveOIDCProvider();
                                break;
                            case 'showEditProviderForm':
                                showEditProviderForm();
                                break;
                            case 'hideEditProviderForm':
                                hideEditProviderForm();
                                break;
                            case 'updateOIDCProvider':
                                updateOIDCProvider();
                                break;
                        }
                    }
                });
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

            function showOrganizationInfo() {
                // Update sidebar
                document.querySelectorAll('nav div').forEach(div => {
                    div.className = div.className.replace('bg-gray-100 text-gray-900', 'text-gray-600 hover:bg-gray-50 hover:text-gray-900');
                });
                document.querySelector('nav div:first-child').className = 'bg-gray-100 text-gray-900 group flex items-center px-3 py-2 text-sm font-medium rounded-md';
                
                // Show/hide content sections
                document.getElementById('organization-info').style.display = 'block';
                document.getElementById('oidc-settings').style.display = 'none';
            }

            function showOIDCSettings() {
                // Update sidebar
                document.querySelectorAll('nav div').forEach(div => {
                    div.className = div.className.replace('bg-gray-100 text-gray-900', 'text-gray-600 hover:bg-gray-50 hover:text-gray-900');
                });
                document.querySelector('nav div:nth-child(2)').className = 'bg-gray-100 text-gray-900 group flex items-center px-3 py-2 text-sm font-medium rounded-md cursor-pointer';
                
                // Show/hide content sections
                document.getElementById('organization-info').style.display = 'none';
                document.getElementById('oidc-settings').style.display = 'block';
                
                // Load OIDC providers
                loadOIDCProviders();
            }

            function loadOIDCProviders() {
                const orgId = '\(organization.id?.uuidString ?? "")';
                
                fetch('/api/organizations/' + orgId + '/oidc-providers')
                    .then(response => response.json())
                    .then(providers => {
                        const providersList = document.getElementById('oidc-providers-list');
                        if (providers.length === 0) {
                            providersList.innerHTML = '<p class="text-gray-500 text-center py-4">No OIDC providers configured</p>';
                        } else {
                            providersList.innerHTML = providers.map(provider => 
                                `<div class="border rounded-lg p-4 mb-4">
                                    <div class="flex justify-between items-center">
                                        <div class="flex-1">
                                            <h4 class="font-medium text-gray-900">${provider.name}</h4>
                                            <p class="text-sm text-gray-500">Client ID: ${provider.clientID}</p>
                                            <p class="text-sm text-gray-500">Provider ID: ${provider.id}</p>
                                            <p class="text-sm text-gray-500">Status: ${provider.enabled ? 'Enabled' : 'Disabled'}</p>
                                            <div class="mt-2 p-2 bg-gray-50 rounded text-xs">
                                                <strong>Redirect URI:</strong><br>
                                                <code class="text-gray-700">${window.location.origin}/auth/oidc/${orgId}/${provider.id}/callback</code>
                                            </div>
                                        </div>
                                        <div class="space-x-2 flex-shrink-0">
                                            <button onclick="editProvider('${provider.id}')" class="text-indigo-600 hover:text-indigo-900" aria-label="Edit ${provider.name} OIDC provider">Edit</button>
                                            <button onclick="deleteProvider('${provider.id}')" class="text-red-600 hover:text-red-900" aria-label="Delete ${provider.name} OIDC provider">Delete</button>
                                        </div>
                                    </div>
                                </div>`
                            ).join('');
                        }
                    })
                    .catch(error => {
                        console.error('Error loading OIDC providers:', error);
                        showError('Failed to load OIDC providers');
                    });
            }

            function showAddProviderForm() {
                document.getElementById('provider-form-section').style.display = 'block';
                document.getElementById('add-provider-button').style.display = 'none';
            }

            function hideAddProviderForm() {
                document.getElementById('provider-form-section').style.display = 'none';
                document.getElementById('add-provider-button').style.display = 'block';
            }

            function editProvider(providerId) {
                // Load provider details first
                const orgId = '\(organization.id?.uuidString ?? "")';
                
                fetch(`/api/organizations/${orgId}/oidc-providers/${providerId}`)
                    .then(response => {
                        if (!response.ok) {
                            throw new Error('Failed to load provider details');
                        }
                        return response.json();
                    })
                    .then(provider => {
                        // Populate edit form with existing values
                        document.getElementById('edit-provider-id').value = provider.id;
                        document.getElementById('edit-name').value = provider.name;
                        document.getElementById('edit-clientID').value = provider.clientID;
                        document.getElementById('edit-clientSecret').value = ''; // Always blank for security
                        document.getElementById('edit-discoveryURL').value = provider.discoveryURL || '';
                        document.getElementById('edit-enabled').checked = provider.enabled;
                        
                        // Show edit form
                        showEditProviderForm();
                    })
                    .catch(error => {
                        console.error('Error loading provider:', error);
                        showError('Failed to load provider details');
                    });
            }

            function deleteProvider(providerId) {
                showDeleteConfirmationModal(() => {
                    performDeleteProvider(providerId);
                });
            }

            function performDeleteProvider(providerId) {
                const orgId = '\(organization.id?.uuidString ?? "")';
                
                fetch(`/api/organizations/${orgId}/oidc-providers/${providerId}`, {
                    method: 'DELETE'
                })
                .then(response => {
                    if (response.ok) {
                        showSuccess('OIDC provider deleted successfully');
                        loadOIDCProviders();
                    } else {
                        throw new Error('Failed to delete provider');
                    }
                })
                .catch(error => {
                    console.error('Error deleting provider:', error);
                    showError('Failed to delete OIDC provider');
                });
            }

            function showDeleteConfirmationModal(onConfirm) {
                // Create modal backdrop
                const backdrop = document.createElement('div');
                backdrop.className = 'fixed inset-0 bg-gray-500 bg-opacity-75 flex items-center justify-center z-50';
                
                // Create modal content
                backdrop.innerHTML = `
                    <div class="bg-white rounded-lg p-6 max-w-sm mx-4">
                        <div class="flex items-center">
                            <div class="mx-auto flex-shrink-0 flex items-center justify-center h-12 w-12 rounded-full bg-red-100">
                                <svg class="h-6 w-6 text-red-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.082 16.5c-.77.833.192 2.5 1.732 2.5z" />
                                </svg>
                            </div>
                        </div>
                        <div class="mt-3 text-center">
                            <h3 class="text-lg leading-6 font-medium text-gray-900">Delete OIDC Provider</h3>
                            <div class="mt-2">
                                <p class="text-sm text-gray-500">Are you sure you want to delete this OIDC provider? This action cannot be undone and may affect users who authenticate through this provider.</p>
                            </div>
                        </div>
                        <div class="mt-5 flex justify-center space-x-3">
                            <button type="button" class="cancel-btn inline-flex justify-center rounded-md border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2">
                                Cancel
                            </button>
                            <button type="button" class="confirm-btn inline-flex justify-center rounded-md border border-transparent bg-red-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-red-700 focus:outline-none focus:ring-2 focus:ring-red-500 focus:ring-offset-2">
                                Delete Provider
                            </button>
                        </div>
                    </div>
                `;
                
                // Add event listeners
                const cancelBtn = backdrop.querySelector('.cancel-btn');
                const confirmBtn = backdrop.querySelector('.confirm-btn');
                
                cancelBtn.addEventListener('click', () => {
                    document.body.removeChild(backdrop);
                });
                
                confirmBtn.addEventListener('click', () => {
                    document.body.removeChild(backdrop);
                    onConfirm();
                });
                
                // Close on backdrop click
                backdrop.addEventListener('click', (e) => {
                    if (e.target === backdrop) {
                        document.body.removeChild(backdrop);
                    }
                });
                
                // Add to page
                document.body.appendChild(backdrop);
            }

            function saveOIDCProvider() {
                const form = document.getElementById('oidc-provider-form');
                const formData = new FormData(form);
                
                const data = {
                    name: formData.get('name'),
                    clientID: formData.get('clientID'),
                    clientSecret: formData.get('clientSecret'),
                    discoveryURL: formData.get('discoveryURL'),
                    enabled: formData.get('enabled') === 'on'
                };

                const orgId = '\(organization.id?.uuidString ?? "")';
                
                fetch(`/api/organizations/${orgId}/oidc-providers`, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify(data)
                })
                .then(response => {
                    if (response.ok) {
                        showSuccess('OIDC provider saved successfully');
                        hideAddProviderForm();
                        loadOIDCProviders();
                        form.reset();
                    } else {
                        return response.text().then(text => {
                            let errorMessage = 'Failed to save OIDC provider';
                            try {
                                const errorData = JSON.parse(text);
                                if (errorData.error && errorData.error.reason) {
                                    errorMessage = errorData.error.reason;
                                } else if (errorData.reason) {
                                    errorMessage = errorData.reason;
                                }
                            } catch (parseError) {
                                // If JSON parsing fails, use a generic error message
                                // Optionally, you could log the raw text for debugging:
                                console.warn('Unstructured error response:', text);
                                if (text.includes('Discovery URL')) {
                                    errorMessage = 'Invalid discovery URL provided';
                                } else if (text.includes('endpoint')) {
                                    errorMessage = 'Invalid endpoint URL provided';
                                } else if (text.includes('not in the allowed list')) {
                                    errorMessage = 'Discovery URL host is not allowed for security reasons';
                                }
                            }
                            throw new Error(errorMessage);
                        });
                    }
                })
                .catch(error => {
                    console.error('Error saving provider:', error);
                    showError(error.message || 'Failed to save OIDC provider');
                });
            }

            function showEditProviderForm() {
                // Hide other sections
                document.getElementById('provider-form-section').style.display = 'none';
                document.getElementById('add-provider-button').style.display = 'none';
                
                // Show edit form
                document.getElementById('edit-provider-form-section').style.display = 'block';
            }

            function hideEditProviderForm() {
                document.getElementById('edit-provider-form-section').style.display = 'none';
                document.getElementById('add-provider-button').style.display = 'block';
                
                // Clear form
                document.getElementById('edit-oidc-provider-form').reset();
            }

            function updateOIDCProvider() {
                const form = document.getElementById('edit-oidc-provider-form');
                const formData = new FormData(form);
                const providerId = document.getElementById('edit-provider-id').value;
                
                if (!providerId) {
                    showError('Provider ID is missing');
                    return;
                }

                const data = {
                    name: formData.get('name'),
                    clientID: formData.get('clientID'),
                    discoveryURL: formData.get('discoveryURL'),
                    enabled: formData.get('enabled') === 'on'
                };

                // Only include client secret if it's not empty
                const clientSecret = formData.get('clientSecret');
                if (clientSecret && clientSecret.trim() !== '') {
                    data.clientSecret = clientSecret;
                }

                const orgId = '\(organization.id?.uuidString ?? "")';
                
                fetch(`/api/organizations/${orgId}/oidc-providers/${providerId}`, {
                    method: 'PUT',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify(data)
                })
                .then(response => {
                    if (response.ok) {
                        showSuccess('OIDC provider updated successfully');
                        hideEditProviderForm();
                        loadOIDCProviders();
                    } else {
                        return response.text().then(text => {
                            let errorMessage = 'Failed to update OIDC provider';
                            try {
                                const errorData = JSON.parse(text);
                                if (errorData.error && errorData.error.reason) {
                                    errorMessage = errorData.error.reason;
                                } else if (errorData.reason) {
                                    errorMessage = errorData.reason;
                                }
                            } catch (parseError) {
                                console.warn('Unstructured error response:', text);
                                if (text.includes('Discovery URL')) {
                                    errorMessage = 'Invalid discovery URL provided';
                                } else if (text.includes('endpoint')) {
                                    errorMessage = 'Invalid endpoint URL provided';
                                } else if (text.includes('not in the allowed list')) {
                                    errorMessage = 'Discovery URL host is not allowed for security reasons';
                                }
                            }
                            throw new Error(errorMessage);
                        });
                    }
                })
                .catch(error => {
                    console.error('Error updating provider:', error);
                    showError(error.message || 'Failed to update OIDC provider');
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
                        div(.class("bg-gray-100 text-gray-900 group flex items-center px-3 py-2 text-sm font-medium rounded-md cursor-pointer"), .data("action", value: "showOrganizationInfo")) {
                            "📋 Organization Info"
                        }

                        div(.class("text-gray-600 hover:bg-gray-50 hover:text-gray-900 group flex items-center px-3 py-2 text-sm font-medium rounded-md cursor-pointer"), .data("action", value: "showOIDCSettings")) {
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
                    OrganizationInfoSection(organization: organization)
                    OIDCSettingsSection(organization: organization)
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

struct OIDCSettingsSection: HTML {
    let organization: OrganizationResponse

    var content: some HTML {
        div(.class("bg-white shadow rounded-lg mt-6"), .id("oidc-settings"), .style("display: none;")) {
            div(.class("px-6 py-4 border-b border-gray-200")) {
                h2(.class("text-lg font-medium text-gray-900")) {
                    "OIDC Authentication Providers"
                }
                p(.class("mt-1 text-sm text-gray-600")) {
                    "Configure OpenID Connect providers for single sign-on authentication."
                }
            }

            div(.class("px-6 py-6")) {
                // Providers list
                div(.id("oidc-providers-list")) {
                    // This will be populated by JavaScript
                }

                // Add Provider Button
                div(.class("mt-6"), .id("add-provider-button")) {
                    button(
                        .type(.button),
                        .data("action", value: "showAddProviderForm"),
                        .class("inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500")
                    ) {
                        "➕ Add OIDC Provider"
                    }
                }

                // Provider Form (hidden by default)
                div(.class("mt-6"), .id("provider-form-section"), .style("display: none;")) {
                    form(.id("oidc-provider-form")) {
                        div(.class("grid grid-cols-1 gap-6")) {
                            // Provider Name
                            div {
                                label(.for("name"), .class("block text-sm font-medium text-gray-700")) {
                                    "Provider Name"
                                }
                                input(
                                    .type(.text),
                                    .name("name"),
                                    .id("name"),
                                    .required,
                                    .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                                    .placeholder("e.g., Azure AD, Google Workspace, Okta")
                                )
                                p(.class("mt-2 text-xs text-gray-500")) {
                                    "A friendly name for this OIDC provider."
                                }
                            }

                            // Client ID
                            div {
                                label(.for("clientID"), .class("block text-sm font-medium text-gray-700")) {
                                    "Client ID"
                                }
                                input(
                                    .type(.text),
                                    .name("clientID"),
                                    .id("clientID"),
                                    .required,
                                    .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                                    .placeholder("Client ID from your OIDC provider")
                                )
                            }

                            // Client Secret
                            div {
                                label(.for("clientSecret"), .class("block text-sm font-medium text-gray-700")) {
                                    "Client Secret"
                                }
                                input(
                                    .type(.password),
                                    .name("clientSecret"),
                                    .id("clientSecret"),
                                    .required,
                                    .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                                    .placeholder("Client Secret from your OIDC provider")
                                )
                            }

                            // Discovery URL
                            div {
                                label(.for("discoveryURL"), .class("block text-sm font-medium text-gray-700")) {
                                    "Discovery URL"
                                }
                                input(
                                    .type(.url),
                                    .name("discoveryURL"),
                                    .id("discoveryURL"),
                                    .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                                    .placeholder("https://provider.com/.well-known/openid-configuration")
                                )
                                p(.class("mt-2 text-xs text-gray-500")) {
                                    "The OpenID Connect discovery endpoint (optional if you configure individual endpoints)."
                                }
                            }

                            // Enabled Toggle
                            div {
                                div(.class("flex items-center")) {
                                    input(
                                        .type(.checkbox),
                                        .name("enabled"),
                                        .id("enabled"),
                                        .checked,
                                        .class("h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300 rounded")
                                    )
                                    label(.for("enabled"), .class("ml-2 block text-sm text-gray-900")) {
                                        "Enable this provider"
                                    }
                                }
                            }
                        }

                        // Form Actions
                        div(.class("mt-6 flex justify-end space-x-3")) {
                            button(
                                .type(.button),
                                .data("action", value: "hideAddProviderForm"),
                                .class("inline-flex justify-center rounded-md border border-gray-300 bg-white py-2 px-4 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2")
                            ) {
                                "Cancel"
                            }
                            button(
                                .type(.button),
                                .data("action", value: "saveOIDCProvider"),
                                .class("inline-flex justify-center rounded-md border border-transparent bg-indigo-600 py-2 px-4 text-sm font-medium text-white shadow-sm hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2")
                            ) {
                                "Save Provider"
                            }
                        }
                    }
                }

                // Edit Provider Form (hidden by default)
                div(.class("mt-6"), .id("edit-provider-form-section"), .style("display: none;")) {
                    div(.class("border-l-4 border-indigo-400 bg-indigo-50 p-4 mb-4")) {
                        div(.class("flex")) {
                            div(.class("ml-3")) {
                                h3(.class("text-sm font-medium text-indigo-800")) {
                                    "Edit OIDC Provider"
                                }
                                p(.class("mt-2 text-sm text-indigo-700")) {
                                    "Update the configuration for your OIDC provider."
                                }
                            }
                        }
                    }

                    form(.id("edit-oidc-provider-form")) {
                        input(.type(.hidden), .id("edit-provider-id"))
                        
                        div(.class("grid grid-cols-1 gap-6")) {
                            // Provider Name
                            div {
                                label(.for("edit-name"), .class("block text-sm font-medium text-gray-700")) {
                                    "Provider Name"
                                }
                                input(
                                    .type(.text),
                                    .name("name"),
                                    .id("edit-name"),
                                    .required,
                                    .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                                    .placeholder("e.g., Azure AD, Google Workspace, Okta")
                                )
                            }

                            // Client ID
                            div {
                                label(.for("edit-clientID"), .class("block text-sm font-medium text-gray-700")) {
                                    "Client ID"
                                }
                                input(
                                    .type(.text),
                                    .name("clientID"),
                                    .id("edit-clientID"),
                                    .required,
                                    .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                                    .placeholder("Client ID from your OIDC provider")
                                )
                            }

                            // Client Secret
                            div {
                                label(.for("edit-clientSecret"), .class("block text-sm font-medium text-gray-700")) {
                                    "Client Secret"
                                }
                                input(
                                    .type(.password),
                                    .name("clientSecret"),
                                    .id("edit-clientSecret"),
                                    .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                                    .placeholder("Leave blank to keep existing secret")
                                )
                                p(.class("mt-2 text-xs text-gray-500")) {
                                    "Leave blank to keep the current client secret unchanged."
                                }
                            }

                            // Discovery URL
                            div {
                                label(.for("edit-discoveryURL"), .class("block text-sm font-medium text-gray-700")) {
                                    "Discovery URL"
                                }
                                input(
                                    .type(.url),
                                    .name("discoveryURL"),
                                    .id("edit-discoveryURL"),
                                    .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                                    .placeholder("https://provider.com/.well-known/openid-configuration")
                                )
                            }

                            // Enabled Toggle
                            div {
                                div(.class("flex items-center")) {
                                    input(
                                        .type(.checkbox),
                                        .name("enabled"),
                                        .id("edit-enabled"),
                                        .class("h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300 rounded")
                                    )
                                    label(.for("edit-enabled"), .class("ml-2 block text-sm text-gray-900")) {
                                        "Enable this provider"
                                    }
                                }
                            }
                        }

                        // Form Actions
                        div(.class("mt-6 flex justify-end space-x-3")) {
                            button(
                                .type(.button),
                                .data("action", value: "hideEditProviderForm"),
                                .class("inline-flex justify-center rounded-md border border-gray-300 bg-white py-2 px-4 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2")
                            ) {
                                "Cancel"
                            }
                            button(
                                .type(.button),
                                .data("action", value: "updateOIDCProvider"),
                                .class("inline-flex justify-center rounded-md border border-transparent bg-indigo-600 py-2 px-4 text-sm font-medium text-white shadow-sm hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2")
                            ) {
                                "Update Provider"
                            }
                        }
                    }
                }
            }
        }
    }
}
