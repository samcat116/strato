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

            // Load user session and VMs
            document.addEventListener('DOMContentLoaded', async () => {
                try {
                    const session = await window.webAuthnClient.getSession();
                    if (session && session.user) {
                        document.getElementById('userInfo').textContent = `Welcome, ${session.user.displayName}`;
                    } else {
                        window.location.href = '/login';
                        return;
                    }
                    await loadOrganizations();
                    await loadProjects();
                    await loadVMs();
                } catch (error) {
                    console.error('Failed to load session:', error);
                    window.location.href = '/login';
                }
            });

            document.getElementById('logoutBtn').addEventListener('click', async () => {
                const success = await window.webAuthnClient.logout();
                if (success) {
                    window.location.href = '/login';
                }
            });

            // Organization management event listeners
            document.getElementById('orgSwitcherBtn').addEventListener('click', toggleOrgDropdown);
            document.getElementById('createOrgBtn').addEventListener('click', showCreateOrgModal);
            document.getElementById('cancelOrgBtn').addEventListener('click', hideCreateOrgModal);
            document.getElementById('submitOrgBtn').addEventListener('click', createOrganization);
            document.getElementById('cancelProjectBtn').addEventListener('click', hideCreateProjectModal);
            document.getElementById('submitProjectBtn').addEventListener('click', createProject);

            // Project management event listeners
            document.getElementById('projectSwitcherBtn').addEventListener('click', toggleProjectDropdown);
            document.getElementById('createProjectBtn').addEventListener('click', showCreateProjectModal);
            
            // API key management event listeners
            document.getElementById('settingsBtn').addEventListener('click', showApiKeysModal);
            document.getElementById('closeApiKeysBtn').addEventListener('click', hideApiKeysModal);
            document.getElementById('createApiKeyBtn').addEventListener('click', showCreateApiKeyModal);
            document.getElementById('cancelApiKeyBtn').addEventListener('click', hideCreateApiKeyModal);
            document.getElementById('submitApiKeyBtn').addEventListener('click', createApiKey);

            // VM creation event listeners
            document.getElementById('createVMBtn').addEventListener('click', showCreateVMModal);
            document.getElementById('cancelVMBtn').addEventListener('click', hideCreateVMModal);
            document.getElementById('submitVMBtn').addEventListener('click', submitCreateVMForm);

            async function loadVMs() {
                try {
                    const response = await fetch('/vms');
                    if (response.ok) {
                        const vms = await response.json();
                        displayVMs(vms);
                    } else {
                        document.getElementById('vmTableBody').innerHTML = '<tr><td colspan="4" class="px-3 py-4 text-sm text-red-500 text-center">Failed to load VMs</td></tr>';
                    }
                } catch (error) {
                    document.getElementById('vmTableBody').innerHTML = '<tr><td colspan="4" class="px-3 py-4 text-sm text-red-500 text-center">Error loading VMs</td></tr>';
                }
            }

            function displayVMs(vms) {
                const vmTableBody = document.getElementById('vmTableBody');
                if (vms.length === 0) {
                    vmTableBody.innerHTML = '<tr><td colspan="4" class="px-3 py-4 text-sm text-gray-500 text-center">No VMs found. Create your first VM!</td></tr>';
                    return;
                }
                vmTableBody.innerHTML = vms.map(vm => {
                    // Find project name for this VM
                    const project = currentProjects.find(p => p.id === vm.projectId);
                    const projectName = project ? project.name : 'Unknown Project';
                    const environment = vm.environment || 'N/A';
                    
                    return `
                        <tr class="hover:bg-gray-50 cursor-pointer" onclick="selectVM('${vm.id}', ${JSON.stringify(vm).replace(/"/g, '&quot;')})">
                            <td class="px-3 py-3">
                                <div class="text-sm font-medium text-gray-900">${vm.name}</div>
                                <div class="text-xs text-gray-500">${vm.description}</div>
                            </td>
                            <td class="px-3 py-3">
                                <div class="text-sm text-gray-900">${projectName}</div>
                                <div class="text-xs text-gray-500">${environment}</div>
                            </td>
                            <td class="px-3 py-3">
                                <span class="inline-flex px-2 py-1 text-xs rounded-full bg-green-100 text-green-800">Running</span>
                            </td>
                            <td class="px-3 py-3">
                                <div class="flex space-x-1">
                                    <button class="text-green-600 hover:text-green-700 text-xs" onclick="event.stopPropagation(); controlVM('${vm.id}', 'start')">▶</button>
                                    <button class="text-yellow-600 hover:text-yellow-700 text-xs" onclick="event.stopPropagation(); controlVM('${vm.id}', 'stop')">⏸</button>
                                    <button class="text-red-600 hover:text-red-700 text-xs" onclick="event.stopPropagation(); deleteVM('${vm.id}')">🗑</button>
                                </div>
                            </td>
                        </tr>
                    `;
                }).join('');
            }

            function selectVM(vmId, vm) {
                const vmDetails = document.getElementById('vmDetails');
                
                // Find project information
                const project = currentProjects.find(p => p.id === vm.projectId);
                const projectName = project ? project.name : 'Unknown Project';
                const environment = vm.environment || 'N/A';
                
                vmDetails.innerHTML = `
                    <div class="space-y-4">
                        <div>
                            <h4 class="text-lg font-semibold text-gray-900">${vm.name}</h4>
                            <p class="text-sm text-gray-600">${vm.description}</p>
                            <div class="mt-2 flex items-center space-x-4">
                                <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-blue-100 text-blue-800">
                                    ${projectName}
                                </span>
                                <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-800">
                                    ${environment}
                                </span>
                            </div>
                        </div>
                        <div class="grid grid-cols-2 gap-4">
                            <div>
                                <label class="block text-sm font-medium text-gray-700">CPU Cores</label>
                                <p class="text-sm text-gray-900">${vm.cpu}</p>
                            </div>
                            <div>
                                <label class="block text-sm font-medium text-gray-700">Memory</label>
                                <p class="text-sm text-gray-900">${(vm.memory / (1024 * 1024 * 1024)).toFixed(1)} GB</p>
                            </div>
                            <div>
                                <label class="block text-sm font-medium text-gray-700">Disk</label>
                                <p class="text-sm text-gray-900">${Math.round(vm.disk / (1024 * 1024 * 1024))} GB</p>
                            </div>
                            <div>
                                <label class="block text-sm font-medium text-gray-700">Image</label>
                                <p class="text-sm text-gray-900">${vm.image}</p>
                            </div>
                        </div>
                        <div class="flex space-x-3 pt-4">
                            <button onclick="controlVM('${vm.id}', 'start')" class="bg-green-600 hover:bg-green-700 text-white px-4 py-2 rounded-md text-sm">Start</button>
                            <button onclick="controlVM('${vm.id}', 'stop')" class="bg-yellow-600 hover:bg-yellow-700 text-white px-4 py-2 rounded-md text-sm">Stop</button>
                            <button onclick="controlVM('${vm.id}', 'restart')" class="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md text-sm">Restart</button>
                            <button onclick="deleteVM('${vm.id}')" class="bg-red-600 hover:bg-red-700 text-white px-4 py-2 rounded-md text-sm">Delete</button>
                        </div>
                    </div>
                `;
            }

            async function controlVM(vmId, action) {
                try {
                    const response = await fetch(`/vms/${vmId}/${action}`, { method: 'POST' });
                    if (response.ok) {
                        term.write(`\\r\\nVM ${vmId} ${action} command sent\\r\\n$ `);
                    } else {
                        term.write(`\\r\\nFailed to ${action} VM ${vmId}\\r\\n$ `);
                    }
                } catch (error) {
                    term.write(`\\r\\nError: ${error.message}\\r\\n$ `);
                }
            }

            async function deleteVM(vmId) {
                if (confirm('Are you sure you want to delete this VM?')) {
                    try {
                        const response = await fetch(`/vms/${vmId}`, { method: 'DELETE' });
                        if (response.ok) {
                            await loadVMs();
                            term.write(`\\r\\nVM ${vmId} deleted\\r\\n$ `);
                        } else {
                            term.write(`\\r\\nFailed to delete VM ${vmId}\\r\\n$ `);
                        }
                    } catch (error) {
                        term.write(`\\r\\nError: ${error.message}\\r\\n$ `);
                    }
                }
            }


            async function createVM(vmData) {
                try {
                    // Convert memory and disk from GB to bytes
                    const vmDataWithBytes = {
                        ...vmData,
                        memory: vmData.memory * 1024 * 1024 * 1024,
                        disk: vmData.disk * 1024 * 1024 * 1024
                    };
                    
                    const response = await fetch('/vms', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify(vmDataWithBytes)
                    });

                    if (response.ok) {
                        await loadVMs();
                        term.write(`\\r\\nVM "${vmData.name}" created\\r\\n$ `);
                    } else {
                        term.write(`\\r\\nFailed to create VM\\r\\n$ `);
                    }
                } catch (error) {
                    term.write(`\\r\\nError: ${error.message}\\r\\n$ `);
                }
            }

            // Organization Management Functions
            let currentOrganizations = [];

            async function loadOrganizations() {
                try {
                    const response = await fetch('/organizations');
                    if (response.ok) {
                        const organizations = await response.json();
                        currentOrganizations = organizations;
                        displayOrganizations(organizations);
                    } else {
                        document.getElementById('currentOrgName').textContent = 'No Organizations';
                    }
                } catch (error) {
                    console.error('Failed to load organizations:', error);
                    document.getElementById('currentOrgName').textContent = 'Error Loading';
                }
            }

            function displayOrganizations(organizations) {
                const orgList = document.getElementById('orgList');
                const currentOrgName = document.getElementById('currentOrgName');
                
                if (organizations.length === 0) {
                    currentOrgName.textContent = 'No Organizations';
                    orgList.innerHTML = '<div class="px-4 py-2 text-sm text-gray-500">No organizations found</div>';
                    return;
                }

                // Find current organization (this will need to be enhanced with actual user current org)
                const currentOrg = organizations[0]; // For now, use first org
                currentOrgName.textContent = currentOrg.name;

                orgList.innerHTML = organizations.map(org => `
                    <button class="w-full text-left px-4 py-2 text-sm hover:bg-gray-50 flex justify-between items-center" onclick="switchOrganization('${org.id}', '${org.name}')">
                        <div>
                            <div class="font-medium">${org.name}</div>
                            <div class="text-xs text-gray-500">${org.description}</div>
                        </div>
                        <span class="text-xs text-gray-400">${org.userRole}</span>
                    </button>
                `).join('');
            }

            function toggleOrgDropdown() {
                const dropdown = document.getElementById('orgDropdown');
                dropdown.classList.toggle('hidden');
                
                // Close dropdown when clicking outside
                document.addEventListener('click', function closeDropdown(e) {
                    if (!e.target.closest('#orgSwitcherBtn') && !e.target.closest('#orgDropdown')) {
                        dropdown.classList.add('hidden');
                        document.removeEventListener('click', closeDropdown);
                    }
                });
            }

            async function switchOrganization(orgId, orgName) {
                try {
                    const response = await fetch(`/organizations/${orgId}/switch`, { method: 'POST' });
                    if (response.ok) {
                        document.getElementById('currentOrgName').textContent = orgName;
                        document.getElementById('orgDropdown').classList.add('hidden');
                        // Update current org in the list
                        currentOrganizations.forEach(org => org.isCurrent = org.id === orgId);
                        // Reset current project
                        currentProjectId = null;
                        // Reload projects for new organization
                        await loadProjects();
                        await loadVMs(); // Reload VMs for new organization
                        term.write(`\\r\\nSwitched to organization: ${orgName}\\r\\n$ `);
                    } else {
                        term.write(`\\r\\nFailed to switch organization\\r\\n$ `);
                    }
                } catch (error) {
                    term.write(`\\r\\nError switching organization: ${error.message}\\r\\n$ `);
                }
            }

            function showCreateOrgModal() {
                document.getElementById('createOrgModal').classList.remove('hidden');
                document.getElementById('orgDropdown').classList.add('hidden');
                document.getElementById('orgName').focus();
            }

            function hideCreateOrgModal() {
                document.getElementById('createOrgModal').classList.add('hidden');
                document.getElementById('createOrgForm').reset();
            }

            async function createOrganization() {
                const name = document.getElementById('orgName').value.trim();
                const description = document.getElementById('orgDescription').value.trim();
                
                if (!name || !description) {
                    alert('Please fill in all fields');
                    return;
                }

                try {
                    const response = await fetch('/organizations', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ name, description })
                    });

                    if (response.ok) {
                        const newOrg = await response.json();
                        hideCreateOrgModal();
                        await loadOrganizations();
                        term.write(`\\r\\nOrganization "${newOrg.name}" created\\r\\n$ `);
                    } else {
                        const error = await response.text();
                        alert(`Failed to create organization: ${error}`);
                    }
                } catch (error) {
                    alert(`Error creating organization: ${error.message}`);
                }
            }

            // Project Management Functions
            var currentProjects = [];
            var currentProjectId = null;

            async function loadProjects() {
                try {
                    // Get current organization ID from session
                    const session = await window.webAuthnClient.getSession();
                    let currentOrgId = session?.user?.currentOrganizationId;
                    
                    // Fallback to first org if no current org in session
                    if (!currentOrgId && currentOrganizations.length > 0) {
                        currentOrgId = currentOrganizations[0].id;
                    }
                    
                    if (!currentOrgId) {
                        document.getElementById('currentProjectName').textContent = 'No Organization';
                        return;
                    }
                    
                    const response = await fetch(`/organizations/${currentOrgId}/projects`);
                    console.log('Loading projects for org:', currentOrgId, 'Status:', response.status);
                    if (response.ok) {
                        const projects = await response.json();
                        console.log('Loaded projects:', projects);
                        currentProjects.length = 0; // Clear array
                        currentProjects.push(...projects); // Add all projects
                        displayProjects(projects);
                        
                        // Get current project from session or use first available
                        const sessionProjectId = session?.user?.currentProjectId;
                        if (sessionProjectId && projects.find(p => p.id === sessionProjectId)) {
                            currentProjectId = sessionProjectId;
                        } else if (projects.length > 0) {
                            currentProjectId = projects[0].id;
                        } else {
                            currentProjectId = null;
                        }
                        
                        if (currentProjectId && projects.length > 0) {
                            const currentProject = projects.find(p => p.id === currentProjectId);
                            if (currentProject) {
                                document.getElementById('currentProjectName').textContent = currentProject.name;
                            }
                        } else {
                            document.getElementById('currentProjectName').textContent = 'No Projects';
                        }
                    } else {
                        document.getElementById('currentProjectName').textContent = 'No Projects';
                    }
                } catch (error) {
                    console.error('Failed to load projects:', error);
                    document.getElementById('currentProjectName').textContent = 'Error Loading';
                }
            }

            function displayProjects(projects) {
                const projectList = document.getElementById('projectList');
                const currentProjectName = document.getElementById('currentProjectName');
                
                console.log('Displaying projects:', projects.length);
                
                if (projects.length === 0) {
                    currentProjectName.textContent = 'No Projects';
                    projectList.innerHTML = '<div class="px-4 py-2 text-sm text-gray-500">No projects found</div>';
                    return;
                }

                // Update current project display
                const currentProject = projects.find(p => p.id === currentProjectId) || projects[0];
                currentProjectName.textContent = currentProject.name;
                currentProjectId = currentProject.id;

                projectList.innerHTML = projects.map(project => `
                    <button class="w-full text-left px-4 py-2 text-sm hover:bg-gray-50 flex justify-between items-center" onclick="switchProject('${project.id}', '${project.name}')">
                        <div>
                            <div class="font-medium">${project.name}</div>
                            <div class="text-xs text-gray-500">${project.description}</div>
                        </div>
                        <div class="text-xs text-gray-400">
                            <span>${project.vmCount} VMs</span>
                            ${project.environments ? `<span class="ml-2">${project.environments.join(', ')}</span>` : ''}
                        </div>
                    </button>
                `).join('');
            }

            function toggleProjectDropdown() {
                const dropdown = document.getElementById('projectDropdown');
                dropdown.classList.toggle('hidden');
                
                // Close dropdown when clicking outside
                document.addEventListener('click', function closeDropdown(e) {
                    if (!e.target.closest('#projectSwitcherBtn') && !e.target.closest('#projectDropdown')) {
                        dropdown.classList.add('hidden');
                        document.removeEventListener('click', closeDropdown);
                    }
                });
            }

            async function switchProject(projectId, projectName) {
                try {
                    const response = await fetch(`/projects/${projectId}/switch`, { method: 'POST' });
                    if (response.ok) {
                        currentProjectId = projectId;
                        document.getElementById('currentProjectName').textContent = projectName;
                        document.getElementById('projectDropdown').classList.add('hidden');
                        await loadVMs(); // Reload VMs for new project
                        term.write(`\r\nSwitched to project: ${projectName}\r\n$ `);
                    } else {
                        term.write(`\r\nFailed to switch project\r\n$ `);
                    }
                } catch (error) {
                    term.write(`\r\nError switching project: ${error.message}\r\n$ `);
                }
            }

            function showCreateProjectModal() {
                document.getElementById('createProjectModal').classList.remove('hidden');
                document.getElementById('projectDropdown').classList.add('hidden');
                document.getElementById('projectName').focus();
            }

            function hideCreateProjectModal() {
                document.getElementById('createProjectModal').classList.add('hidden');
                document.getElementById('createProjectForm').reset();
            }

            async function createProject() {
                const name = document.getElementById('projectName').value.trim();
                const description = document.getElementById('projectDescription').value.trim();
                const environments = Array.from(document.querySelectorAll('input[name="projectEnvironments"]:checked')).map(cb => cb.value);
                const defaultEnvironment = document.getElementById('projectDefaultEnvironment').value;
                
                if (!name || !description) {
                    alert('Please fill in all fields');
                    return;
                }

                if (environments.length === 0) {
                    alert('Please select at least one environment');
                    return;
                }

                try {
                    // Get current organization ID from session
                    const session = await window.webAuthnClient.getSession();
                    let currentOrgId = session?.user?.currentOrganizationId;
                    
                    // Fallback to first org if no current org in session
                    if (!currentOrgId && currentOrganizations.length > 0) {
                        currentOrgId = currentOrganizations[0].id;
                    }
                    
                    if (!currentOrgId) {
                        alert('No organization selected');
                        return;
                    }
                    
                    console.log('Creating project in organization:', currentOrgId);
                    console.log('Project data:', { name, description, environments, defaultEnvironment });

                    const response = await fetch(`/organizations/${currentOrgId}/projects`, {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ name, description, environments, defaultEnvironment })
                    });

                    console.log('Response status:', response.status);
                    
                    if (response.ok) {
                        const newProject = await response.json();
                        console.log('Created project:', newProject);
                        hideCreateProjectModal();
                        await loadProjects();
                        term.write(`\r\nProject "${newProject.name}" created\r\n$ `);
                    } else {
                        const errorText = await response.text();
                        console.error('Project creation failed:', response.status, errorText);
                        alert(`Failed to create project: ${errorText}`);
                    }
                } catch (error) {
                    alert(`Error creating project: ${error.message}`);
                }
            }

            // Close modal on escape key
            document.addEventListener('keydown', (e) => {
                if (e.key === 'Escape') {
                    hideCreateOrgModal();
                    hideCreateProjectModal();
                    hideApiKeysModal();
                    hideCreateApiKeyModal();
                    hideCreateVMModal();
                }
            });

            // VM Creation Modal Functions
            function showCreateVMModal() {
                document.getElementById('createVMModal').classList.remove('hidden');
                document.getElementById('vmName').focus();
            }

            function hideCreateVMModal() {
                document.getElementById('createVMModal').classList.add('hidden');
                document.getElementById('createVMForm').reset();
            }

            async function submitCreateVMForm() {
                const name = document.getElementById('vmName').value.trim();
                const description = document.getElementById('vmDescription').value.trim();
                const cpu = parseInt(document.getElementById('vmCpu').value);
                const memory = parseInt(document.getElementById('vmMemory').value);
                const disk = parseInt(document.getElementById('vmDisk').value);
                const templateName = document.getElementById('vmTemplate').value;
                
                if (!name || !description) {
                    alert('Please fill in all required fields');
                    return;
                }

                if (cpu < 1 || memory < 1 || disk < 1) {
                    alert('CPU, Memory, and Disk must be at least 1');
                    return;
                }

                if (!currentProjectId) {
                    alert('Please select a project before creating a VM');
                    return;
                }

                try {
                    // Include current project context
                    const vmData = { name, description, cpu, memory, disk, templateName };
                    if (currentProjectId) {
                        vmData.projectId = currentProjectId;
                        // Add environment if project is selected
                        const selectedProject = currentProjects.find(p => p.id === currentProjectId);
                        if (selectedProject && selectedProject.defaultEnvironment) {
                            vmData.environment = selectedProject.defaultEnvironment;
                        }
                    }
                    await createVM(vmData);
                    hideCreateVMModal();
                } catch (error) {
                    alert(`Error creating VM: ${error.message}`);
                }
            }

            // API Key Management Functions
            async function loadApiKeys() {
                try {
                    const response = await fetch('/api-keys');
                    if (response.ok) {
                        const apiKeys = await response.json();
                        displayApiKeys(apiKeys);
                    } else {
                        document.getElementById('apiKeysList').innerHTML = '<div class="text-center text-red-500 py-8">Failed to load API keys</div>';
                    }
                } catch (error) {
                    document.getElementById('apiKeysList').innerHTML = '<div class="text-center text-red-500 py-8">Error loading API keys</div>';
                }
            }

            function displayApiKeys(apiKeys) {
                const apiKeysList = document.getElementById('apiKeysList');
                
                if (apiKeys.length === 0) {
                    apiKeysList.innerHTML = '<div class="text-center text-gray-500 py-8">No API keys found. Create your first API key!</div>';
                    return;
                }

                apiKeysList.innerHTML = apiKeys.map(key => `
                    <div class="border border-gray-200 rounded-lg p-4">
                        <div class="flex justify-between items-start">
                            <div class="flex-1">
                                <h4 class="font-medium text-gray-900">${key.name}</h4>
                                <p class="text-sm text-gray-500 font-mono">${key.keyPrefix}</p>
                                <div class="mt-2 flex flex-wrap gap-1">
                                    ${key.scopes.map(scope => `<span class="inline-flex px-2 py-1 text-xs rounded-full bg-blue-100 text-blue-800">${scope}</span>`).join('')}
                                </div>
                                <div class="mt-1 text-xs text-gray-500">
                                    Created: ${new Date(key.createdAt).toLocaleDateString()}
                                    ${key.lastUsedAt ? '• Last used: ' + new Date(key.lastUsedAt).toLocaleDateString() : '• Never used'}
                                    ${key.expiresAt ? '• Expires: ' + new Date(key.expiresAt).toLocaleDateString() : '• Never expires'}
                                </div>
                            </div>
                            <div class="flex space-x-2">
                                <button onclick="toggleApiKey('${key.id}', ${!key.isActive})" 
                                        class="text-sm px-3 py-1 rounded ${key.isActive ? 'bg-red-100 text-red-700 hover:bg-red-200' : 'bg-green-100 text-green-700 hover:bg-green-200'}">
                                    ${key.isActive ? 'Disable' : 'Enable'}
                                </button>
                                <button onclick="deleteApiKey('${key.id}')" 
                                        class="text-sm px-3 py-1 rounded bg-red-100 text-red-700 hover:bg-red-200">
                                    Delete
                                </button>
                            </div>
                        </div>
                    </div>
                `).join('');
            }

            function showApiKeysModal() {
                document.getElementById('apiKeysModal').classList.remove('hidden');
                loadApiKeys();
            }

            function hideApiKeysModal() {
                document.getElementById('apiKeysModal').classList.add('hidden');
            }

            function showCreateApiKeyModal() {
                document.getElementById('createApiKeyModal').classList.remove('hidden');
                document.getElementById('apiKeyName').focus();
            }

            function hideCreateApiKeyModal() {
                document.getElementById('createApiKeyModal').classList.add('hidden');
                document.getElementById('createApiKeyForm').reset();
            }

            async function createApiKey() {
                const name = document.getElementById('apiKeyName').value.trim();
                const scopes = Array.from(document.querySelectorAll('input[type="checkbox"]:checked')).map(cb => cb.value);
                const expiresInDays = document.getElementById('apiKeyExpiry').value;
                
                if (!name) {
                    alert('Please enter a name for the API key');
                    return;
                }

                if (scopes.length === 0) {
                    alert('Please select at least one scope');
                    return;
                }

                try {
                    const requestBody = { name, scopes };
                    if (expiresInDays) {
                        requestBody.expiresInDays = parseInt(expiresInDays);
                    }

                    const response = await fetch('/api-keys', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify(requestBody)
                    });

                    if (response.ok) {
                        const newKey = await response.json();
                        hideCreateApiKeyModal();
                        
                        // Show the new API key in a copy-able format
                        const keyDisplay = prompt('Your new API key (copy this now - you won\\'t see it again):', newKey.key);
                        
                        await loadApiKeys();
                        term.write(`\\r\\nAPI key "${newKey.name}" created\\r\\n$ `);
                    } else {
                        const error = await response.text();
                        alert(`Failed to create API key: ${error}`);
                    }
                } catch (error) {
                    alert(`Error creating API key: ${error.message}`);
                }
            }

            async function toggleApiKey(keyId, isActive) {
                try {
                    const response = await fetch(`/api-keys/${keyId}`, {
                        method: 'PATCH',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ isActive })
                    });

                    if (response.ok) {
                        await loadApiKeys();
                        term.write(`\\r\\nAPI key ${isActive ? 'enabled' : 'disabled'}\\r\\n$ `);
                    } else {
                        alert('Failed to update API key');
                    }
                } catch (error) {
                    alert(`Error updating API key: ${error.message}`);
                }
            }

            async function deleteApiKey(keyId) {
                if (confirm('Are you sure you want to delete this API key? This action cannot be undone.')) {
                    try {
                        const response = await fetch(`/api-keys/${keyId}`, { method: 'DELETE' });
                        if (response.ok) {
                            await loadApiKeys();
                            term.write(`\\r\\nAPI key deleted\\r\\n$ `);
                        } else {
                            alert('Failed to delete API key');
                        }
                    } catch (error) {
                        alert(`Error deleting API key: ${error.message}`);
                    }
                }
            }
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
                            )
                        ) {
                            span(.id("currentOrgName")) { "Loading..." }
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
                                div(.id("orgList"), .class("max-h-48 overflow-y-auto")) {
                                    // Organizations will be loaded here
                                }
                                hr(.class("my-1"))
                                button(
                                    .id("createOrgBtn"),
                                    .class("w-full text-left px-4 py-2 text-sm text-indigo-600 hover:bg-gray-50")
                                ) {
                                    "+ Create Organization"
                                }
                            }
                        }
                    }
                    
                    // Project Switcher
                    div(.class("relative")) {
                        button(
                            .id("projectSwitcherBtn"),
                            .class(
                                "bg-gray-50 hover:bg-gray-100 text-gray-700 px-3 py-2 rounded-md text-sm font-medium border border-gray-300 flex items-center space-x-2"
                            )
                            .aria("expanded", "false"),
                            .aria("controls", "projectDropdown"),
                            .on("keydown", "if (event.key === 'Enter' || event.key === ' ') { toggleDropdown('projectSwitcherBtn', 'projectDropdown'); }")
                        ) {
                            span(.id("currentProjectName")) { "Loading..." }
                            span(.class("text-gray-400")) { "▼" }
                        }
                        div(
                            .id("projectDropdown"),
                            .class("hidden absolute top-full left-0 mt-1 w-64 bg-white border border-gray-200 rounded-md shadow-lg z-10")
                            .aria("hidden", "true")
                        ) {
                            div(.class("py-1")) {
                                div(.class("px-4 py-2 text-xs font-medium text-gray-500 uppercase")) {
                                    "Switch Project"
                                }
                                div(.id("projectList"), .class("max-h-48 overflow-y-auto")) {
                                    // Projects will be loaded here
                                }
                                hr(.class("my-1"))
                                button(
                                    .id("createProjectBtn"),
                                    .class("w-full text-left px-4 py-2 text-sm text-indigo-600 hover:bg-gray-50")
                                ) {
                                    "+ Create Project"
                                }
                            }
                        }
                    }
                    
                    button(
                        .id("createVMBtn"),
                        .class(
                            "bg-indigo-600 hover:bg-indigo-700 text-white px-4 py-2 rounded-md text-sm font-medium"
                        )
                    ) {
                        "+ New VM"
                    }
                    button(
                        .id("settingsBtn"),
                        .class(
                            "bg-gray-100 hover:bg-gray-200 text-gray-700 px-4 py-2 rounded-md text-sm font-medium"
                        )
                    ) {
                        "API Keys"
                    }
                    span(.id("userInfo"), .class("text-sm text-gray-600")) {}
                    button(
                        .id("logoutBtn"),
                        .class("text-gray-500 hover:text-gray-700 text-sm")
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
        CreateProjectModal()
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

struct CreateProjectModal: HTML {
    var content: some HTML {
        div(
            .id("createProjectModal"),
            .class("fixed inset-0 bg-gray-600 bg-opacity-50 hidden flex items-center justify-center z-50")
        ) {
            div(.class("bg-white rounded-lg shadow-xl max-w-md w-full mx-4")) {
                div(.class("px-6 py-4 border-b border-gray-200")) {
                    h3(.class("text-lg font-medium text-gray-900")) {
                        "Create Project"
                    }
                }
                div(.class("px-6 py-4")) {
                    form(.id("createProjectForm")) {
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                                "Project Name"
                            }
                            input(
                                .type(.text),
                                .id("projectName"),
                                .class("w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"),
                                .required
                            )
                        }
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                                "Description"
                            }
                            textarea(
                                .id("projectDescription"),
                                .class("w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500 h-20"),
                                .required
                            ) {}
                        }
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                                "Environments"
                            }
                            div(.class("space-y-2")) {
                                label(.class("flex items-center")) {
                                    input(.type(.checkbox), .name("projectEnvironments"), .value("development"), .class("mr-2"), .checked)
                                    span(.class("text-sm")) { "Development" }
                                }
                                label(.class("flex items-center")) {
                                    input(.type(.checkbox), .name("projectEnvironments"), .value("staging"), .class("mr-2"))
                                    span(.class("text-sm")) { "Staging" }
                                }
                                label(.class("flex items-center")) {
                                    input(.type(.checkbox), .name("projectEnvironments"), .value("production"), .class("mr-2"))
                                    span(.class("text-sm")) { "Production" }
                                }
                            }
                        }
                        div(.class("mb-4")) {
                            label(.class("block text-sm font-medium text-gray-700 mb-2")) {
                                "Default Environment"
                            }
                            select(
                                .id("projectDefaultEnvironment"),
                                .class("w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500")
                            ) {
                                option(.value("development"), .selected) { "Development" }
                                option(.value("staging")) { "Staging" }
                                option(.value("production")) { "Production" }
                            }
                        }
                    }
                }
                div(.class("px-6 py-4 border-t border-gray-200 flex justify-end space-x-3")) {
                    button(
                        .id("cancelProjectBtn"),
                        .type(.button),
                        .class("px-4 py-2 text-sm font-medium text-gray-700 bg-gray-100 hover:bg-gray-200 rounded-md")
                    ) {
                        "Cancel"
                    }
                    button(
                        .id("submitProjectBtn"),
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
            form(.id("createVMForm")) {
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
                .class("px-4 py-2 text-sm font-medium text-gray-700 bg-gray-100 hover:bg-gray-200 rounded-md")
            ) {
                "Cancel"
            }
            button(
                .id("submitVMBtn"),
                .type(.button),
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
                    "Project"
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
        tbody(.id("vmTableBody"), .class("divide-y divide-gray-200")) {
            tr {
                td(.class("px-3 py-4 text-sm text-gray-500 text-center")) {
                    "Loading VMs..."
                }
                td(.class("px-3 py-4 text-sm text-gray-500 text-center")) {
                    ""
                }
                td(.class("px-3 py-4 text-sm text-gray-500 text-center")) {
                    ""
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
