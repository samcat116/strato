// WebAuthn/Passkey Integration for Strato

class WebAuthnClient {
    constructor(baseURL = '') {
        this.baseURL = baseURL;
    }

    // Helper function to convert ArrayBuffer to base64url
    bufferToBase64url(buffer) {
        const bytes = new Uint8Array(buffer);
        let str = '';
        for (const byte of bytes) {
            str += String.fromCharCode(byte);
        }
        return btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
    }

    // Helper function to convert base64url to ArrayBuffer
    base64urlToBuffer(base64url) {
        const base64 = base64url.replace(/-/g, '+').replace(/_/g, '/');
        const padLength = (4 - (base64.length % 4)) % 4;
        const padded = base64 + '='.repeat(padLength);
        const binary = atob(padded);
        const buffer = new ArrayBuffer(binary.length);
        const bytes = new Uint8Array(buffer);
        for (let i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        return buffer;
    }

    // Convert server response to WebAuthn credential creation options
    prepareCreationOptions(options) {
        return {
            ...options,
            challenge: this.base64urlToBuffer(options.challenge),
            user: {
                ...options.user,
                id: this.base64urlToBuffer(options.user.id)
            },
            excludeCredentials: options.excludeCredentials?.map(cred => ({
                ...cred,
                id: this.base64urlToBuffer(cred.id)
            })) || []
        };
    }

    // Convert server response to WebAuthn credential request options
    prepareRequestOptions(options) {
        return {
            ...options,
            challenge: this.base64urlToBuffer(options.challenge),
            allowCredentials: options.allowCredentials?.map(cred => ({
                ...cred,
                id: this.base64urlToBuffer(cred.id)
            })) || []
        };
    }

    // Convert WebAuthn credential creation response for server
    prepareCreationResponse(credential, challenge) {
        return {
            challenge: challenge,
            response: {
                id: credential.id,
                rawId: this.bufferToBase64url(credential.rawId),
                type: credential.type,
                response: {
                    clientDataJSON: this.bufferToBase64url(credential.response.clientDataJSON),
                    attestationObject: this.bufferToBase64url(credential.response.attestationObject)
                }
            }
        };
    }

    // Convert WebAuthn authentication response for server
    prepareAuthenticationResponse(credential, challenge) {
        return {
            challenge: challenge,
            response: {
                id: credential.id,
                rawId: this.bufferToBase64url(credential.rawId),
                type: credential.type,
                response: {
                    clientDataJSON: this.bufferToBase64url(credential.response.clientDataJSON),
                    authenticatorData: this.bufferToBase64url(credential.response.authenticatorData),
                    signature: this.bufferToBase64url(credential.response.signature),
                    userHandle: credential.response.userHandle ? this.bufferToBase64url(credential.response.userHandle) : null
                }
            }
        };
    }

    // Register a new passkey
    async register(username) {
        try {
            // Step 1: Begin registration
            const beginResponse = await fetch(`${this.baseURL}/auth/register/begin`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ username })
            });

            if (!beginResponse.ok) {
                throw new Error(`Registration begin failed: ${beginResponse.statusText}`);
            }

            const { options } = await beginResponse.json();
            const challenge = options.challenge;

            // Step 2: Create credential
            const credential = await navigator.credentials.create({
                publicKey: this.prepareCreationOptions(options)
            });

            if (!credential) {
                throw new Error('Failed to create credential');
            }

            // Step 3: Finish registration
            const finishResponse = await fetch(`${this.baseURL}/auth/register/finish`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify(this.prepareCreationResponse(credential, challenge))
            });

            if (!finishResponse.ok) {
                throw new Error(`Registration finish failed: ${finishResponse.statusText}`);
            }

            return await finishResponse.json();
        } catch (error) {
            console.error('Registration error:', error);
            throw error;
        }
    }

    // Authenticate with passkey
    async authenticate(username = null) {
        try {
            // Step 1: Begin authentication
            const beginResponse = await fetch(`${this.baseURL}/auth/login/begin`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ username })
            });

            if (!beginResponse.ok) {
                throw new Error(`Authentication begin failed: ${beginResponse.statusText}`);
            }

            const { options } = await beginResponse.json();
            const challenge = options.challenge;

            // Step 2: Get credential
            const credential = await navigator.credentials.get({
                publicKey: this.prepareRequestOptions(options)
            });

            if (!credential) {
                throw new Error('Failed to get credential');
            }

            // Step 3: Finish authentication
            const finishResponse = await fetch(`${this.baseURL}/auth/login/finish`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify(this.prepareAuthenticationResponse(credential, challenge))
            });

            if (!finishResponse.ok) {
                throw new Error(`Authentication finish failed: ${finishResponse.statusText}`);
            }

            return await finishResponse.json();
        } catch (error) {
            console.error('Authentication error:', error);
            throw error;
        }
    }

    // Check current session
    async getSession() {
        try {
            const response = await fetch(`${this.baseURL}/auth/session`);
            if (response.ok) {
                return await response.json();
            }
            return null;
        } catch (error) {
            console.error('Session check error:', error);
            return null;
        }
    }

    // Logout
    async logout() {
        try {
            const response = await fetch(`${this.baseURL}/auth/logout`, {
                method: 'POST'
            });
            return response.ok;
        } catch (error) {
            console.error('Logout error:', error);
            return false;
        }
    }

    // Check if WebAuthn is supported
    static isSupported() {
        // Basic API check
        if (!(navigator.credentials && navigator.credentials.create && navigator.credentials.get)) {
            return false;
        }
        
        // Check for PublicKeyCredential support
        if (!window.PublicKeyCredential) {
            return false;
        }
        
        // Additional check for HTTPS requirement (except localhost)
        const isLocalhost = location.hostname === 'localhost' || location.hostname === '127.0.0.1';
        const isHttps = location.protocol === 'https:';
        
        if (!isLocalhost && !isHttps) {
            console.warn('WebAuthn requires HTTPS for non-localhost origins');
            return false;
        }
        
        return true;
    }
}

// Global instance
window.webAuthnClient = new WebAuthnClient();

// Utility functions for UI integration
window.WebAuthnUtils = {
    // Show loading state
    showLoading(elementId, message = 'Processing...') {
        const element = document.getElementById(elementId);
        if (element) {
            element.innerHTML = `<div class="loading">${message}</div>`;
            element.disabled = true;
        }
    },

    // Show error message
    showError(elementId, message) {
        const element = document.getElementById(elementId);
        if (element) {
            element.innerHTML = `<div class="error text-red-500">${message}</div>`;
        }
    },

    // Show success message
    showSuccess(elementId, message) {
        const element = document.getElementById(elementId);
        if (element) {
            element.innerHTML = `<div class="success text-green-500">${message}</div>`;
        }
    },

    // Reset element
    resetElement(elementId, originalContent = '') {
        const element = document.getElementById(elementId);
        if (element) {
            element.innerHTML = originalContent;
            element.disabled = false;
        }
    },

    // Handle passkey registration
    async handleRegistration(username, statusElementId = null) {
        if (!WebAuthnClient.isSupported()) {
            if (statusElementId) {
                WebAuthnUtils.showError(statusElementId, 'WebAuthn is not supported in this browser');
            }
            return false;
        }

        try {
            if (statusElementId) {
                WebAuthnUtils.showLoading(statusElementId, 'Creating passkey...');
            }

            const result = await window.webAuthnClient.register(username);
            
            if (statusElementId) {
                WebAuthnUtils.showSuccess(statusElementId, 'Passkey created successfully!');
            }
            
            return result;
        } catch (error) {
            if (statusElementId) {
                WebAuthnUtils.showError(statusElementId, `Registration failed: ${error.message}`);
            }
            return false;
        }
    },

    // Handle passkey authentication
    async handleAuthentication(username = null, statusElementId = null) {
        if (!WebAuthnClient.isSupported()) {
            if (statusElementId) {
                WebAuthnUtils.showError(statusElementId, 'WebAuthn is not supported in this browser');
            }
            return false;
        }

        try {
            if (statusElementId) {
                WebAuthnUtils.showLoading(statusElementId, 'Authenticating...');
            }

            const result = await window.webAuthnClient.authenticate(username);
            
            if (statusElementId) {
                WebAuthnUtils.showSuccess(statusElementId, 'Authentication successful!');
            }
            
            return result;
        } catch (error) {
            if (statusElementId) {
                WebAuthnUtils.showError(statusElementId, `Authentication failed: ${error.message}`);
            }
            return false;
        }
    }
};

// Initialize on page load
document.addEventListener('DOMContentLoaded', async () => {
    // Check if WebAuthn is supported and show/hide relevant UI elements
    let isSupported = WebAuthnClient.isSupported();
    
    // Additional runtime check for conditional UI availability
    if (isSupported && window.PublicKeyCredential) {
        try {
            // Check if conditional UI is available (for better UX)
            isSupported = await PublicKeyCredential.isConditionalMediationAvailable?.() ?? true;
        } catch (error) {
            console.warn('Conditional UI check failed:', error);
            // Still consider supported if the basic API works
        }
    }
    
    if (!isSupported) {
        const passkeyElements = document.querySelectorAll('.passkey-only');
        passkeyElements.forEach(el => {
            el.style.display = 'none';
        });
        
        const fallbackElements = document.querySelectorAll('.passkey-fallback');
        fallbackElements.forEach(el => {
            el.style.display = 'block';
        });
        
        // Log helpful debug information
        console.log('WebAuthn Support Debug:', {
            hasCredentials: !!(navigator.credentials),
            hasCreate: !!(navigator.credentials?.create),
            hasGet: !!(navigator.credentials?.get),
            hasPublicKeyCredential: !!(window.PublicKeyCredential),
            origin: location.origin,
            protocol: location.protocol,
            hostname: location.hostname
        });
    }
});}