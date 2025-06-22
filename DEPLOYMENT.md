# Strato Deployment Guide

## WebAuthn/Passkeys Remote Deployment

When deploying Strato to a remote server, WebAuthn/Passkeys have strict security requirements that must be properly configured.

### The Problem

The "Passkeys not supported" error occurs because:

1. **HTTPS Requirement**: WebAuthn only works over HTTPS (except for localhost)
2. **Origin Mismatch**: The relying party ID must match the domain/IP you're accessing
3. **Browser Security**: Browsers enforce strict origin policies for WebAuthn

### Solutions

#### Option 1: Development with IP Access (Quick Fix)

1. Copy the environment file:
```bash
cp .env.production.example .env
```

2. Edit `.env` and set your server's IP:
```bash
WEBAUTHN_RELYING_PARTY_ID=YOUR_SERVER_IP
WEBAUTHN_RELYING_PARTY_ORIGIN=http://YOUR_SERVER_IP:8080
```

3. Restart the application:
```bash
docker compose down
docker compose up app
```

**Note**: This works but is not recommended for production as it exposes credentials over HTTP.

#### Option 2: Production with Domain Name (Recommended)

1. Set up a domain pointing to your server
2. Configure HTTPS (use nginx, Caddy, or similar)
3. Update `.env`:
```bash
WEBAUTHN_RELYING_PARTY_ID=strato.yourdomain.com
WEBAUTHN_RELYING_PARTY_ORIGIN=https://strato.yourdomain.com
```

#### Option 3: Development with Custom Hostname

1. Add an entry to your local `/etc/hosts` (on your client machine):
```bash
192.168.1.100 strato.local
```

2. Update `.env`:
```bash
WEBAUTHN_RELYING_PARTY_ID=strato.local
WEBAUTHN_RELYING_PARTY_ORIGIN=http://strato.local:8080
```

3. Access the application via `http://strato.local:8080`

### Example Nginx Configuration (Option 2)

```nginx
server {
    listen 443 ssl http2;
    server_name strato.yourdomain.com;
    
    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;
    
    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 80;
    server_name strato.yourdomain.com;
    return 301 https://$server_name$request_uri;
}
```

### Testing WebAuthn Configuration

After updating the configuration, test by:

1. Clear browser data for the site
2. Navigate to your configured URL
3. Try to register a new account
4. The Passkey registration should work without errors

### Troubleshooting

- **"Passkeys not supported"**: Origin mismatch or HTTPS requirement
- **"Invalid domain"**: Relying party ID doesn't match the URL domain
- **Registration fails silently**: Check browser console for WebAuthn errors
- **Existing users can't login**: WebAuthn credentials are tied to the origin

### Security Notes

- Always use HTTPS in production
- Never expose WebAuthn over HTTP except for localhost development
- Consider implementing fallback authentication for critical deployments
- Test thoroughly after any domain/origin changes