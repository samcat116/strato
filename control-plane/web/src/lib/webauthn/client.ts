// WebAuthn/Passkey client for authentication

import { bufferToBase64url, base64urlToBuffer } from "./utils";
import type {
  PublicKeyCredentialCreationOptionsJSON,
  PublicKeyCredentialRequestOptionsJSON,
} from "./types";
import { authApi } from "@/lib/api/auth";
import { usersApi } from "@/lib/api/users";
import { ApiError } from "@/lib/api/client";
import type { CreateUserRequest, User } from "@/types/api";

export class WebAuthnClient {
  /**
   * Check if WebAuthn is supported in this browser
   */
  static isSupported(): boolean {
    if (typeof window === "undefined") return false;

    // Check for PublicKeyCredential support
    if (
      !window.PublicKeyCredential ||
      !navigator.credentials
    ) {
      return false;
    }

    return true;
  }

  /**
   * Convert server response to WebAuthn credential creation options
   */
  private prepareCreationOptions(
    options: PublicKeyCredentialCreationOptionsJSON
  ): PublicKeyCredentialCreationOptions {
    return {
      ...options,
      challenge: base64urlToBuffer(options.challenge),
      user: {
        ...options.user,
        id: base64urlToBuffer(options.user.id),
      },
      excludeCredentials:
        options.excludeCredentials?.map((cred) => ({
          ...cred,
          id: base64urlToBuffer(cred.id),
        })) || [],
    };
  }

  /**
   * Convert server response to WebAuthn credential request options
   */
  private prepareRequestOptions(
    options: PublicKeyCredentialRequestOptionsJSON
  ): PublicKeyCredentialRequestOptions {
    return {
      ...options,
      challenge: base64urlToBuffer(options.challenge),
      allowCredentials:
        options.allowCredentials?.map((cred) => ({
          ...cred,
          id: base64urlToBuffer(cred.id),
        })) || [],
    };
  }

  /**
   * Convert WebAuthn credential creation response for server
   */
  private prepareCreationResponse(
    credential: PublicKeyCredential,
    challenge: string
  ): object {
    const response = credential.response as AuthenticatorAttestationResponse;
    return {
      challenge,
      response: {
        id: credential.id,
        rawId: bufferToBase64url(credential.rawId),
        type: credential.type,
        response: {
          clientDataJSON: bufferToBase64url(response.clientDataJSON),
          attestationObject: bufferToBase64url(response.attestationObject),
        },
      },
    };
  }

  /**
   * Convert WebAuthn authentication response for server
   */
  private prepareAuthenticationResponse(
    credential: PublicKeyCredential,
    challenge: string
  ): object {
    const response = credential.response as AuthenticatorAssertionResponse;
    return {
      challenge,
      response: {
        id: credential.id,
        rawId: bufferToBase64url(credential.rawId),
        type: credential.type,
        response: {
          clientDataJSON: bufferToBase64url(response.clientDataJSON),
          authenticatorData: bufferToBase64url(response.authenticatorData),
          signature: bufferToBase64url(response.signature),
          userHandle: response.userHandle
            ? bufferToBase64url(response.userHandle)
            : null,
        },
      },
    };
  }

  /**
   * Register a new passkey
   */
  async register(
    data: CreateUserRequest
  ): Promise<{ success: boolean; user: User }> {
    // Step 1: Create the user record so the passkey ceremony has something to
    // attach the credential to. A 409 means the account already exists (e.g. an
    // earlier passkey attempt was cancelled after the record was created), so we
    // fall through and let them complete the ceremony rather than dead-ending.
    try {
      await usersApi.register(data);
    } catch (error) {
      if (!(error instanceof ApiError && error.status === 409)) {
        throw error;
      }
    }

    // Step 2: Begin registration
    const { options } = await authApi.registerBegin(data.username);
    const challenge = options.challenge;

    // Step 3: Create credential with browser API
    const credential = (await navigator.credentials.create({
      publicKey: this.prepareCreationOptions(options),
    })) as PublicKeyCredential | null;

    if (!credential) {
      throw new Error("Failed to create credential");
    }

    // Step 4: Finish registration
    const result = await authApi.registerFinish(
      this.prepareCreationResponse(credential, challenge) as {
        challenge: string;
        response: unknown;
      }
    );

    return result;
  }

  /**
   * Authenticate with passkey
   */
  async authenticate(
    username?: string | null
  ): Promise<{ success: boolean; user: User }> {
    // Step 1: Begin authentication
    const { options } = await authApi.loginBegin(username);
    const challenge = options.challenge;

    // Step 2: Get credential with browser API
    const credential = (await navigator.credentials.get({
      publicKey: this.prepareRequestOptions(options),
    })) as PublicKeyCredential | null;

    if (!credential) {
      throw new Error("Failed to get credential");
    }

    // Step 3: Finish authentication
    const result = await authApi.loginFinish(
      this.prepareAuthenticationResponse(credential, challenge) as {
        challenge: string;
        response: unknown;
      }
    );

    return result;
  }
}

// Export singleton instance
export const webAuthnClient = new WebAuthnClient();
