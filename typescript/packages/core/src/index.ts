/**
 * Package identity for the litellm-auto-router-suite core package.
 *
 * @remarks VERSION and PACKAGE_NAME are duplicated from package.json because a
 * bundler cannot read package.json at runtime; tests/index.test.ts fails the
 * build if the two ever drift.
 */
export const PACKAGE_NAME: string = '@fulton-engineering-services/litellm-auto-router-suite-core'
/**
 * Shipped version string.
 *
 * @remarks Must equal the `version` field of the package manifest; the drift
 * check lives in tests/index.test.ts.
 */
export const VERSION: string = '0.1.0'
