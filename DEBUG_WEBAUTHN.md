# WebAuthn Debugging Guide

## Quick Fix for Remote Deployment

### Step 1: Update Environment Variables

Create a `.env` file in your project root:

```bash
# Replace YOUR_SERVER_IP with your actual server IP
WEBAUTHN_RELYING_PARTY_ID=YOUR_SERVER_IP
WEBAUTHN_RELYING_PARTY_ORIGIN=http://YOUR_SERVER_IP:8080
WEBAUTHN_RELYING_PARTY_NAME=Strato
```

### Step 2: Restart the Application

```bash
docker compose down
docker compose up app
```

### Step 3: Clear Browser Data

1. Open browser developer tools (F12)
2. Go to Application/Storage tab
3. Clear all site data for your Strato instance
4. Reload the page

## Debugging Steps

### 1. Check Browser Console

Open developer tools and look for:
- "WebAuthn Support Debug" log entry
- Any WebAuthn-related errors
- Network errors during authentication

### 2. Verify Configuration

Check that your environment variables match your access method:

| Access Method | RELYING_PARTY_ID | RELYING_PARTY_ORIGIN |
|---------------|------------------|----------------------|
| `http://localhost:8080` | `localhost` | `http://localhost:8080` |
| `http://192.168.1.100:8080` | `192.168.1.100` | `http://192.168.1.100:8080` |
| `https://strato.example.com` | `strato.example.com` | `https://strato.example.com` |

### 3. Test WebAuthn Support

Run this in the browser console:

```javascript
console.log('WebAuthn Support:', {
    hasCredentials: !!(navigator.credentials),
    hasCreate: !!(navigator.credentials?.create),
    hasGet: !!(navigator.credentials?.get),
    hasPublicKeyCredential: !!(window.PublicKeyCredential),
    origin: location.origin,
    protocol: location.protocol,
    hostname: location.hostname
});
```

### 4. Common Issues

| Error | Cause | Solution |
|-------|-------|----------|
| "Passkeys not supported" | Origin mismatch | Update RELYING_PARTY_ID and ORIGIN |
| "Invalid domain" | Domain doesn't match | Ensure exact domain match |
| HTTPS required | Non-localhost HTTP | Use HTTPS or localhost |
| Registration fails | Mixed origins | Clear browser data |

### 5. Browser Requirements

- **Chrome/Edge**: Full WebAuthn support
- **Firefox**: Full WebAuthn support (may need to enable in settings)
- **Safari**: WebAuthn support available
- **Mobile browsers**: Generally supported on HTTPS

### 6. Network Issues

- Ensure port 8080 is accessible from your client
- Check firewall settings
- Verify DNS resolution if using domain names

## Example Working Configurations

### Local Development
```bash
WEBAUTHN_RELYING_PARTY_ID=localhost
WEBAUTHN_RELYING_PARTY_ORIGIN=http://localhost:8080
```

### Remote IP Access
```bash
WEBAUTHN_RELYING_PARTY_ID=192.168.1.100
WEBAUTHN_RELYING_PARTY_ORIGIN=http://192.168.1.100:8080
```

### Production with HTTPS
```bash
WEBAUTHN_RELYING_PARTY_ID=strato.yourdomain.com
WEBAUTHN_RELYING_PARTY_ORIGIN=https://strato.yourdomain.com
```