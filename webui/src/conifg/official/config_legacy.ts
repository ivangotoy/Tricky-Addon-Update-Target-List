import type { MdOutlinedTextField } from '@material/web/all'
import { file } from '../../file'
import { isDev } from '../../utils/dev'
import { Config, PolicySchema } from '../config'
import type { ConfigData, Policy } from '../config'

function parseTarget(raw: string): string[] {
  const targets: string[] = []
  for (const line of raw.split('\n')) {
    const trimmed = line.trim()
    if (trimmed === '' || trimmed.startsWith('#')) continue
    targets.push(trimmed)
  }
  return targets
}

// security_patch.txt values the TrickyStore readers accept: YYYYMM, YYYYMMDD or YYYY-MM-DD (YYYY/MM/DD placeholders,
// any case), prop, no, device_default; validators that only allowed digits refused saving files using the others
const PATCH_VALUE = /^(?:prop|no|device_default|(?:\d{4}|yyyy)-?(?:\d{2}|mm)(?:-?(?:\d{2}|dd))?)$/i
const PATCH_VALUE_HINT = 'YYYYMM[DD] | YYYY-MM-DD | prop | no | device_default'

function stripDay(value: string): string {
  return /^\d{8}$/.test(value) ? value.slice(0, 6) : value
}

function parseSecurityPatch(raw: string): Policy | null {
  const policy: Policy = {}
  for (const line of raw.split('\n')) {
    const trimmed = line.trim()
    if (trimmed === '' || trimmed.startsWith('#')) continue

    const eqIdx = trimmed.indexOf('=')
    if (eqIdx === 0) continue

    const key = eqIdx > 0 ? trimmed.slice(0, eqIdx).trim() : 'all'
    const value = eqIdx > 0 ? trimmed.slice(eqIdx + 1).trim() : trimmed

    switch (key) {
      case 'system':
        policy.os_patch = value
        break
      case 'boot':
        policy.boot_patch = value
        break
      case 'vendor':
        policy.vendor_patch = value
        break
      case 'all': {
        policy.os_patch = stripDay(value)
        policy.boot_patch = value
        policy.vendor_patch = value
        break
      }
    }
  }
  return Object.keys(policy).length > 0 ? policy : null
}

// per-package blocks ([package.name] headers) start at the first header line; they are not edited here and are kept verbatim
function splitPackageBlocks(raw: string): [string, string] {
  const lines = raw.split('\n')
  const idx = lines.findIndex(line => /^\[[^\]]+\]$/.test(line.trim()))
  return idx === -1 ? [raw, ''] : [lines.slice(0, idx).join('\n'), lines.slice(idx).join('\n').trim()]
}

function serializeTarget(target: string[]): string {
  return target.join('\n')
}

function isNoOpPolicy(policy: Policy | undefined | null): boolean {
  if (!policy) return true
  return [policy.os_patch, policy.vendor_patch, policy.boot_patch]
    .every(v => v === undefined || v === 'no')
}

function serializeSecurityPatch(policy: Policy): string {
  const lines: string[] = []
  if (policy.os_patch !== undefined) lines.push(`system=${policy.os_patch}`)
  if (policy.boot_patch !== undefined) lines.push(`boot=${policy.boot_patch}`)
  if (policy.vendor_patch !== undefined) lines.push(`vendor=${policy.vendor_patch}`)
  return lines.join('\n')
}

const LEGACY_POLICY_SCHEMA: PolicySchema = new PolicySchema({
  app_mode: {
    type: 'select',
    label: 'mode_dialog_title',
    options: ['mode_auto', 'mode_certificate_generating', 'mode_leaf_hack'],
    defaultValue: 'mode_auto',
    globalPolicy: false,
  },
  os_patch: {
    defaultValue: 'no',
    options: ['prop', 'no'],
    maxlength: 14,
    placeholder: 'YYYYMM',
    perAppPolicy: false,
    validate: (v) => !v || PATCH_VALUE.test(v) || PATCH_VALUE_HINT,
  },
  vendor_patch: {
    defaultValue: 'no',
    options: ['prop', 'no'],
    maxlength: 14,
    placeholder: 'YYYYMMDD',
    perAppPolicy: false,
    validate: (v) => !v || PATCH_VALUE.test(v) || PATCH_VALUE_HINT,
  },
  boot_patch: {
    defaultValue: 'no',
    options: ['prop', 'no'],
    maxlength: 14,
    placeholder: 'YYYYMMDD',
    perAppPolicy: false,
    validate: (v) => !v || PATCH_VALUE.test(v) || PATCH_VALUE_HINT,
  },
  _today: {
    type: 'button',
    label: 'functional_button_today',
    perAppPolicy: false,
    onClick: (editor) => {
      const now8 = new Date().toISOString().slice(0, 10).replace(/-/g, '')
      const setDate = (key: string) => {
        const el = editor.getField(key) as MdOutlinedTextField | undefined
        if (!el) return
        const maxlength = parseInt(el.getAttribute('maxlength') ?? '', 10)
        if (maxlength === 6) {
          el.value = now8.slice(0, 6)
        } else if (maxlength >= 8) {
          el.value = now8
        }
      }
      setDate('os_patch')
      setDate('vendor_patch')
      setDate('boot_patch')
    },
  },
})

export class ConfigLegacy extends Config {
  override readonly identity: string = 'TS-L'

  protected readonly CONFIG_FILE = this.CONFIG_PATH + '/target.txt'
  protected readonly SECURITY_PATCH_FILE = this.CONFIG_PATH + '/security_patch.txt'

  protected override readonly perAppConfig: boolean = true

  override readonly policySchema: PolicySchema = LEGACY_POLICY_SCHEMA
  // security_patch.txt from its first [package.name] header on, written back unchanged
  #packageBlocks = ''

  override async read(): Promise<void> {
    this.clearReadFailure()
    this.#packageBlocks = ''
    const data: ConfigData = {}

    if (isDev()) {
      data.default_policy = { os_patch: 'no', vendor_patch: 'no', boot_patch: 'no' }
      data.target = [
        'io.github.vvb2060.keyattestation',
        'io.github.vvb2060.mahoshojo?',
        'com.google.android.gms!',
      ]
    } else {
      try {
        const targetRaw = await file.read(this.CONFIG_FILE)
        data.target = parseTarget(targetRaw)
      } catch {
        await this.readFailed(this.CONFIG_FILE)
        data.target = []
      }

      try {
        const spRaw = await file.read(this.SECURITY_PATCH_FILE)
        const [globalPart, packageBlocks] = splitPackageBlocks(spRaw)
        this.#packageBlocks = packageBlocks
        const policy = parseSecurityPatch(globalPart)
        if (policy) data.default_policy = policy
      } catch {
        await this.readFailed(this.SECURITY_PATCH_FILE)
        // security_patch.txt missing — leave default_policy unset
      }

      if (!data.default_policy) {
        data.default_policy = { os_patch: 'no', vendor_patch: 'no', boot_patch: 'no' }
      }
    }

    for (const entry of data.target ?? []) {
      const appMode = entry.endsWith('!') ? 'mode_certificate_generating'
        : entry.endsWith('?') ? 'mode_leaf_hack'
        : undefined
      if (appMode) data[entry.replace(/[!?]$/, '')] = { app_mode: appMode }
    }

    this.set(data)
  }

  override async write(): Promise<void> {
    this.assertWritable()
    const data = this.get()

    for (const [pkg, value] of Object.entries(data)) {
      if (pkg === 'target' || pkg === 'default_policy' || Array.isArray(value)) continue
      const appMode = (value as Policy).app_mode
      if (typeof appMode !== 'string') continue
      const newValue = appMode === 'mode_certificate_generating' ? `${pkg}!`
        : appMode === 'mode_leaf_hack' ? `${pkg}?`
        : pkg
      this.replaceMatch('target', entry => entry.replace(/[!?]$/, '') === pkg, newValue)
    }

    const writeTasks: Promise<void>[] = []

    if (data.target) {
      writeTasks.push(file.write(this.CONFIG_FILE, serializeTarget(data.target)))
    }

    const globalPart = data.default_policy && !isNoOpPolicy(data.default_policy) ? serializeSecurityPatch(data.default_policy) : ''
    if (globalPart || this.#packageBlocks) {
      writeTasks.push(file.write(this.SECURITY_PATCH_FILE, [globalPart, this.#packageBlocks].filter(Boolean).join('\n\n')))
    } else {
      writeTasks.push(file.delete(this.SECURITY_PATCH_FILE))
    }

    await Promise.all(writeTasks)
  }
}
