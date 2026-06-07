import type { Context, Next } from 'hono';
import type { AppEnv, OpenClawEnv } from '../types';
import { redactSensitiveParams } from '../utils/logging';
import { AccessJWTVerificationError, verifyAccessJWT } from './jwt';

/**
 * Options for creating an access middleware
 */
export interface AccessMiddlewareOptions {
  /** Response type: 'json' for API routes, 'html' for UI routes */
  type: 'json' | 'html';
  /** Whether to redirect to login when JWT is missing (only for 'html' type) */
  redirectOnMissing?: boolean;
}

/**
 * Check if running in development mode (skips CF Access auth + device pairing)
 */
export function isDevMode(env: OpenClawEnv): boolean {
  return env.DEV_MODE === 'true';
}

/**
 * Check if running in E2E test mode (skips CF Access auth but keeps device pairing)
 */
export function isE2ETestMode(env: OpenClawEnv): boolean {
  return env.E2E_TEST_MODE === 'true';
}

/**
 * Extract JWT from request headers or cookies
 */
export function extractJWT(c: Context<AppEnv>): string | null {
  const jwtHeader = c.req.header('CF-Access-JWT-Assertion');
  const jwtCookie = c.req.raw.headers
    .get('Cookie')
    ?.split(';')
    .find((cookie) => cookie.trim().startsWith('CF_Authorization='))
    ?.split('=')[1];

  return jwtHeader || jwtCookie || null;
}

type JWTSource = 'header' | 'cookie' | 'none';

function getJWTSource(c: Context<AppEnv>): JWTSource {
  if (c.req.header('CF-Access-JWT-Assertion')) return 'header';

  const hasAccessCookie = c.req.raw.headers
    .get('Cookie')
    ?.split(';')
    .some((cookie) => cookie.trim().startsWith('CF_Authorization='));

  return hasAccessCookie ? 'cookie' : 'none';
}

function getSafeRequestContext(c: Context<AppEnv>): {
  method: string;
  path: string;
  query: string;
  cfRay: string | null;
} {
  const method = c.req.method ?? 'UNKNOWN';
  const cfRay = c.req.header('CF-Ray') ?? null;
  const rawUrl = c.req.url;

  if (!rawUrl) {
    return { method, path: 'unknown', query: '', cfRay };
  }

  try {
    const url = new URL(rawUrl);
    return {
      method,
      path: url.pathname,
      query: redactSensitiveParams(url),
      cfRay,
    };
  } catch {
    return { method, path: 'unknown', query: '', cfRay };
  }
}

function logAccessAuthFailure(
  c: Context<AppEnv>,
  options: {
    status: 401 | 302;
    reason: string;
    responseType: AccessMiddlewareOptions['type'];
    error?: unknown;
  },
): void {
  const request = getSafeRequestContext(c);
  const jwtSource = getJWTSource(c);
  const error = options.error;
  const event = {
    event: 'cloudflare_access_auth_failure',
    severity: 'ERROR',
    status: options.status,
    reason: options.reason,
    responseType: options.responseType,
    method: request.method,
    path: request.path,
    query: request.query,
    cfRay: request.cfRay,
    jwtSource,
    hasJwt: jwtSource !== 'none',
    teamDomainConfigured: !!c.env.CF_ACCESS_TEAM_DOMAIN,
    audConfigured: !!c.env.CF_ACCESS_AUD,
    errorName: error instanceof Error ? error.name : null,
    errorCode: error instanceof AccessJWTVerificationError ? error.code : null,
    errorMessage: error instanceof Error ? error.message : null,
  };

  console.error('[AUTH_FAILURE]', JSON.stringify(event));
}

/**
 * Create a Cloudflare Access authentication middleware
 *
 * @param options - Middleware options
 * @returns Hono middleware function
 */
export function createAccessMiddleware(options: AccessMiddlewareOptions) {
  const { type, redirectOnMissing = false } = options;

  return async (c: Context<AppEnv>, next: Next) => {
    // Skip auth in dev mode or E2E test mode
    if (isDevMode(c.env) || isE2ETestMode(c.env)) {
      c.set('accessUser', { email: 'dev@localhost', name: 'Dev User' });
      return next();
    }

    const teamDomain = c.env.CF_ACCESS_TEAM_DOMAIN;
    const expectedAud = c.env.CF_ACCESS_AUD;

    // Check if CF Access is configured
    if (!teamDomain || !expectedAud) {
      if (type === 'json') {
        return c.json(
          {
            error: 'Cloudflare Access not configured',
            hint: 'Set CF_ACCESS_TEAM_DOMAIN and CF_ACCESS_AUD environment variables',
          },
          500,
        );
      } else {
        return c.html(
          `
          <html>
            <body>
              <h1>Admin UI Not Configured</h1>
              <p>Set CF_ACCESS_TEAM_DOMAIN and CF_ACCESS_AUD environment variables.</p>
            </body>
          </html>
        `,
          500,
        );
      }
    }

    // Get JWT
    const jwt = extractJWT(c);

    if (!jwt) {
      logAccessAuthFailure(c, {
        status: type === 'html' && redirectOnMissing ? 302 : 401,
        reason: 'missing_cloudflare_access_jwt',
        responseType: type,
      });

      if (type === 'html' && redirectOnMissing) {
        return c.redirect(`https://${teamDomain}`, 302);
      }

      if (type === 'json') {
        return c.json(
          {
            error: 'Unauthorized',
            hint: 'Missing Cloudflare Access JWT. Ensure this route is protected by Cloudflare Access.',
          },
          401,
        );
      } else {
        return c.html(
          `
          <html>
            <body>
              <h1>Unauthorized</h1>
              <p>Missing Cloudflare Access token.</p>
              <a href="https://${teamDomain}">Login</a>
            </body>
          </html>
        `,
          401,
        );
      }
    }

    // Verify JWT
    try {
      const payload = await verifyAccessJWT(jwt, teamDomain, expectedAud);
      c.set('accessUser', { email: payload.email, name: payload.name });
      await next();
    } catch (err) {
      logAccessAuthFailure(c, {
        status: 401,
        reason: err instanceof AccessJWTVerificationError ? err.code : 'jwt_verification_failed',
        responseType: type,
        error: err,
      });

      if (type === 'json') {
        return c.json(
          {
            error: 'Unauthorized',
            details: err instanceof Error ? err.message : 'JWT verification failed',
          },
          401,
        );
      } else {
        return c.html(
          `
          <html>
            <body>
              <h1>Unauthorized</h1>
              <p>Your Cloudflare Access session is invalid or expired.</p>
              <a href="https://${teamDomain}">Login again</a>
            </body>
          </html>
        `,
          401,
        );
      }
    }
  };
}
