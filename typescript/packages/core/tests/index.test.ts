import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

import { PACKAGE_NAME, VERSION } from '../src/index.js'

interface Manifest {
  name: string
  version: string
}

const manifestPath: string = fileURLToPath(new URL('../package.json', import.meta.url))
const manifestJson: unknown = JSON.parse(readFileSync(manifestPath, 'utf8'))
const manifest: Manifest = manifestJson as Manifest

describe('package identity', () => {
  it('keeps PACKAGE_NAME in sync with the manifest', () => {
    expect(PACKAGE_NAME).toBe(manifest.name)
  })

  it('keeps VERSION in sync with the manifest', () => {
    expect(VERSION).toBe(manifest.version)
  })

  it('uses a semver-shaped VERSION', () => {
    expect(VERSION).toMatch(/^\d+\.\d+\.\d+$/)
  })
})
