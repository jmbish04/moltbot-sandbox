import { jwtVerify, createRemoteJWKSet } from 'jose';
import type { JWTPayload } from '../types';

export type AccessJWTVerificationCode =
  | 'ACCESS_JWT_EXPIRED'
  | 'ACCESS_JWT_AUDIENCE_MISMATCH'
  | 'ACCESS_JWT_ISSUER_MISMATCH'
  | 'ACCESS_JWT_SIGNATURE_INVALID'
  | 'ACCESS_JWT_VERIFICATION_FAILED';

export class AccessJWTVerificationError extends Error {
  readonly code: AccessJWTVerificationCode;
  readonly issuer: string;
  readonly expectedAudience: string;

  constructor(options: {
    code: AccessJWTVerificationCode;
    issuer: string;
    expectedAudience: string;
    cause: unknown;
  }) {
    const causeMessage =
      options.cause instanceof Error ? options.cause.message : String(options.cause);
    super(`Cloudflare Access JWT verification failed: ${causeMessage}`, {
      cause: options.cause,
    });
    this.name = 'AccessJWTVerificationError';
    this.code = options.code;
    this.issuer = options.issuer;
    this.expectedAudience = options.expectedAudience;
  }
}

function classifyAccessJWTError(error: unknown): AccessJWTVerificationCode {
  if (!(error instanceof Error)) return 'ACCESS_JWT_VERIFICATION_FAILED';

  const errorCode = 'code' in error ? String(error.code) : '';
  const message = error.message.toLowerCase();

  if (error.name === 'JWTExpired' || errorCode === 'ERR_JWT_EXPIRED' || message.includes('exp')) {
    return 'ACCESS_JWT_EXPIRED';
  }

  if (message.includes('"aud"') || message.includes('audience')) {
    return 'ACCESS_JWT_AUDIENCE_MISMATCH';
  }

  if (message.includes('"iss"') || message.includes('issuer')) {
    return 'ACCESS_JWT_ISSUER_MISMATCH';
  }

  if (error.name === 'JWSSignatureVerificationFailed' || message.includes('signature')) {
    return 'ACCESS_JWT_SIGNATURE_INVALID';
  }

  return 'ACCESS_JWT_VERIFICATION_FAILED';
}

/**
 * Verify a Cloudflare Access JWT token using the jose library.
 *
 * This follows Cloudflare's recommended approach:
 * https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/#cloudflare-workers-example
 *
 * @param token - The JWT token string
 * @param teamDomain - The Cloudflare Access team domain (e.g., 'myteam.cloudflareaccess.com')
 * @param expectedAud - The expected audience (Application AUD tag)
 * @returns The decoded JWT payload if valid
 * @throws Error if the token is invalid, expired, or doesn't match expected values
 */
export async function verifyAccessJWT(
  token: string,
  teamDomain: string,
  expectedAud: string,
): Promise<JWTPayload> {
  // Ensure teamDomain has https:// prefix for issuer check
  const issuer = teamDomain.startsWith('https://') ? teamDomain : `https://${teamDomain}`;

  // Create JWKS from the team domain
  const JWKS = createRemoteJWKSet(new URL(`${issuer}/cdn-cgi/access/certs`));

  let payload: unknown;
  try {
    // Verify the JWT using jose
    const verified = await jwtVerify(token, JWKS, {
      issuer,
      audience: expectedAud,
    });
    payload = verified.payload;
  } catch (error) {
    throw new AccessJWTVerificationError({
      code: classifyAccessJWTError(error),
      issuer,
      expectedAudience: expectedAud,
      cause: error,
    });
  }

  // Cast to our JWTPayload type
  return payload as unknown as JWTPayload;
}
