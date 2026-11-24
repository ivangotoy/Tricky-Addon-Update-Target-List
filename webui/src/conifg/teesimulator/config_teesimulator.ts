import { file } from '../../file'
import { isDev } from '../../utils/dev'
import { Config, PolicySchema } from '../config'
import type { ConfigData, Policy } from '../config'

interface TeeProfile {
  apps?: unknown
  patchLevel?: unknown
  osVersion?: unknown
  mode?: unknown
  autoIncludeNewApps?: unknown
  [key: string]: unknown
}

interface TeeConfig {
  version: number
  profiles: Record<string, TeeProfile>
  [key: string]: unknown
}

const PATCH_LEVEL_PATTERN = /^(?:no|today|harvested|system_property|(?:\d{4}|YYYY)-(?:\d{2}|MM)(?:-(?:\d{2}|DD))?)$/
const OS_VERSION_PATTERN = /^(?:no|harvested|system_property|\d+(?:\.\d+){0,2})$/
const IDENTITY_FIELDS = ['brand', 'device', 'product', 'manufacturer', 'model', 'serial', 'imei', 'meid', 'imei2'] as const
const PATCH_MAP = [
  ['os_patch', 'system'],
  ['vendor_patch', 'vendor'],
  ['boot_patch', 'boot'],
] as const

const PROFILE_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/
const NEW_PROFILE = 'profile_new'

const PROFILE_MODES = ['patch', 'generation'] as const
type ProfileMode = (typeof PROFILE_MODES)[number]

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function createDefaultConfig(): TeeConfig {
  return {
    version: 1,
    profiles: {
      default: {
        keybox: 'keybox.xml',
        patchLevel: { system: 'today', vendor: 'YYYY-MM-05', boot: 'YYYY-MM-05' },
        osVersion: '',
        mode: 'patch',
        brand: '', device: '', product: '', manufacturer: '', model: '',
        serial: '', imei: '', meid: '', imei2: '',
        apps: [],
      },
    },
  }
}

export class ConfigTeeSimulator extends Config {
  override readonly identity: string = 'TEES'

  protected override readonly CONFIG_PATH = '/data/adb/teesim'
  protected readonly CONFIG_FILE = this.CONFIG_PATH + '/config.json'
  protected override readonly perAppConfig: boolean = true
  protected override readonly moduleVisible: boolean = true

  override readonly policySchema: PolicySchema

  #teeConfig: TeeConfig = createDefaultConfig()
  #activeProfile = 'default'
  #sectionBaseline = new Map<string, string>()
  #appliedDefaultPolicy: string | null = null

  constructor() {
    super()
    this.policySchema = this.#createSchema()
  }

  #createSchema(): PolicySchema {
    return new PolicySchema({
      profile: {
        type: 'select',
        label: 'profile_label',
        options: [],
        defaultValue: 'default',
        onLoad: () => [...Object.keys(this.#teeConfig.profiles), NEW_PROFILE],
        onSelect: (value, editor, context, previous) => {
          if (value === NEW_PROFILE) {
            const name = this.#createProfile()
            editor.setPolicy(this.#profileWithMeta(name))
            return name
          }
          if (context === 'global') {
            // the form still holds the values of the profile shown before the switch (form.profile is already `value`)
            const form = editor.getPolicy()
            const shown = previous !== undefined && this.#hasProfile(previous) ? previous : this.#activeProfile
            // an invalid form (null) must not strip the profile
            if (form) this.#applyProfilePolicy(shown, form)
            this.#activeProfile = value
          }
          editor.setPolicy(this.#profileWithMeta(value))
          return value
        },
      },
      profile_name: {
        label: 'profile_name_label',
        defaultValue: '',
        caseSensitive: true,
        validate: (v) => !v || (PROFILE_NAME_PATTERN.test(v) && v !== NEW_PROFILE) || 'a-z A-Z 0-9 _ . -',
      },
      mode: {
        type: 'select',
        label: 'mode_dialog_title',
        options: ['patch', 'generation'],
        optionLabels: { patch: 'mode_leaf_hack', generation: 'mode_certificate_generating' },
        defaultValue: 'patch',
      },
      auto_include_new_apps: {
        type: 'boolean',
        label: 'auto_include_new_apps_label',
        defaultValue: false,
      },
      os_patch: {
        label: 'System Patch',
        caseSensitive: true,
        defaultValue: 'today',
        options: ['today', 'harvested', 'system_property', 'no'],
        placeholder: 'YYYY-MM-DD',
        validate: (v) => !v || PATCH_LEVEL_PATTERN.test(v) || 'today | harvested | system_property | no | date',
      },
      vendor_patch: {
        label: 'Vendor Patch',
        caseSensitive: true,
        defaultValue: 'YYYY-MM-05',
        options: ['today', 'harvested', 'system_property', 'no'],
        placeholder: 'YYYY-MM-05',
        validate: (v) => !v || PATCH_LEVEL_PATTERN.test(v) || 'today | harvested | system_property | no | date',
      },
      boot_patch: {
        label: 'Boot Patch',
        caseSensitive: true,
        defaultValue: 'YYYY-MM-05',
        options: ['today', 'harvested', 'system_property', 'no'],
        placeholder: 'YYYY-MM-05',
        validate: (v) => !v || PATCH_LEVEL_PATTERN.test(v) || 'today | harvested | system_property | no | date',
      },
      os_version: {
        label: 'OS Version',
        caseSensitive: true,
        options: ['harvested', 'system_property', 'no'],
        placeholder: '16 or 16.0.0',
        validate: (v) => !v || OS_VERSION_PATTERN.test(v) || 'harvested | system_property | no | version',
      },
      brand: { label: 'Brand', caseSensitive: true, validate: () => true },
      device: { label: 'Device', caseSensitive: true, validate: () => true },
      product: { label: 'Product', caseSensitive: true, validate: () => true },
      manufacturer: { label: 'Manufacturer', caseSensitive: true, validate: () => true },
      model: { label: 'Model', caseSensitive: true, validate: () => true },
      serial: { label: 'Serial', caseSensitive: true, validate: () => true },
      imei: { label: 'IMEI', caseSensitive: true, validate: () => true },
      meid: { label: 'MEID', caseSensitive: true, validate: () => true },
      imei2: { label: 'IMEI 2', caseSensitive: true, validate: () => true },
      delete_profile: {
        type: 'button',
        label: 'profile_delete',
        variant: 'error',
        disabled: () => Object.keys(this.#teeConfig.profiles).length <= 1,
        onClick: (editor, context) => {
          // delete the profile this dialog shows, not the one last picked in another dialog
          const shown = (editor.getField('profile') as (HTMLElement & { value?: string }) | undefined)?.value ?? this.#activeProfile
          if (!this.#deleteProfile(shown)) return
          // the global select then shows the first profile (refreshSelects): show and activate that one too
          if (context === 'global') this.#activeProfile = Object.keys(this.#teeConfig.profiles)[0]
          editor.setPolicy(this.#profileWithMeta(this.#activeProfile))
        },
      },
    })
  }

  override async read(): Promise<void> {
    this.clearReadFailure()
    if (isDev()) {
      this.#teeConfig = createDefaultConfig()
      this.#teeConfig.profiles.default.apps = [
        'io.github.vvb2060.keyattestation',
        'com.google.android.gms',
        'com.android.vending',
      ]
    } else {
      try {
        const parsed: unknown = JSON.parse(await file.read(this.CONFIG_FILE))
        if (!isRecord(parsed) || !isRecord(parsed.profiles)) throw new Error('Invalid Tee Simulator config')
        const profiles = Object.fromEntries(
          Object.entries(parsed.profiles).filter(([, profile]) => isRecord(profile))
        ) as Record<string, TeeProfile>
        this.#teeConfig = {
          ...parsed,
          version: typeof parsed.version === 'number' ? parsed.version : 1,
          profiles,
        }
      } catch {
        await this.readFailed(this.CONFIG_FILE)
        this.#teeConfig = createDefaultConfig()
      }
    }

    const target: string[] = []
    const data: ConfigData = { target }
    for (const profile of Object.values(this.#teeConfig.profiles)) {
      if (!PROFILE_MODES.includes(profile.mode as ProfileMode)) profile.mode = 'patch'
    }
    const seenApps = new Set<string>()
    this.#sectionBaseline.clear()
    for (const [name, profile] of Object.entries(this.#teeConfig.profiles)) {
      if (!Array.isArray(profile.apps)) continue
      for (const app of profile.apps) {
        if (typeof app !== 'string') continue
        const section = this.#profileWithMeta(name)
        data[app] = section
        this.#sectionBaseline.set(app, JSON.stringify(section))
        if (!seenApps.has(app)) {
          seenApps.add(app)
          target.push(app)
        }
      }
    }

    const names = Object.keys(this.#teeConfig.profiles)
    this.#activeProfile = names.includes('default') ? 'default' : (names[0] ?? 'default')
    data.default_policy = this.#profileWithMeta(this.#activeProfile)
    this.#appliedDefaultPolicy = JSON.stringify(data.default_policy)
    this.set(data)
  }

  override async write(): Promise<void> {
    this.assertWritable()
    const data = this.get()

    for (const [section, value] of Object.entries(data)) {
      if (section === 'target' || section === 'default_policy' || Array.isArray(value)) continue
      const policy = value as Policy
      if (typeof policy.profile !== 'string') continue
      const profileName = this.#resolveRename(policy, '')
      if (!this.#hasProfile(profileName)) continue
      this.#assignApp(section, profileName)
      if (this.#sectionBaseline.get(section) !== JSON.stringify(value)) {
        this.#applyProfilePolicy(profileName, policy)
      }
    }

    const policy = data.default_policy
    const serializedPolicy = policy ? JSON.stringify(policy) : null
    if (policy && serializedPolicy !== this.#appliedDefaultPolicy) {
      const name = this.#resolveRename(policy, this.#activeProfile)
      this.#activeProfile = name
      this.#applyProfilePolicy(name, policy)
      this.#appliedDefaultPolicy = JSON.stringify(policy)
    }

    const remainingApps = new Set((data.target ?? []).filter((app): app is string => typeof app === 'string'))
    for (const profile of Object.values(this.#teeConfig.profiles)) {
      const apps = Array.isArray(profile.apps) ? profile.apps : []
      profile.apps = apps.filter((app): app is string => typeof app === 'string' && remainingApps.delete(app))
    }
    // targeted apps in no profile go to default; default is recreated only for them, so a deleted or renamed
    // default profile does not come back on every save
    if (remainingApps.size > 0) {
      const defaultProfile = this.#defaultProfile()
      defaultProfile.apps = [...(Array.isArray(defaultProfile.apps) ? defaultProfile.apps : []), ...remainingApps]
    }

    for (const [section, value] of Object.entries(this.get())) {
      if (section === 'target' || section === 'default_policy' || Array.isArray(value)) continue
      const profileName = (value as Policy).profile
      if (typeof profileName !== 'string' || !this.#hasProfile(profileName)) continue
      const fresh = this.#profileWithMeta(profileName)
      this.set(section, fresh)
      this.#sectionBaseline.set(section, JSON.stringify(fresh))
    }

    await file.write(this.CONFIG_FILE, JSON.stringify(this.#teeConfig, null, 2))
  }

  #profilePolicy(name: string): Policy | null {
    const profile = this.#teeConfig.profiles[name]
    if (!isRecord(profile)) return null
    const policy: Record<string, string> = {}
    const patchLevel = isRecord(profile.patchLevel) ? profile.patchLevel : {}
    for (const [policyKey, configKey] of PATCH_MAP) {
      if (patchLevel[configKey] !== undefined) policy[policyKey] = String(patchLevel[configKey])
    }
    if (profile.osVersion !== undefined) policy.os_version = String(profile.osVersion)
    policy.mode = String(profile.mode)
    for (const key of IDENTITY_FIELDS) {
      if (profile[key] !== undefined) policy[key] = String(profile[key])
    }
    return policy
  }

  #profileWithMeta(name: string): Policy {
    const policy = this.#profilePolicy(name) ?? {}
    policy.profile = name
    policy.profile_name = name
    policy.auto_include_new_apps = this.#teeConfig.profiles[name]?.autoIncludeNewApps === true
    return policy
  }

  #applyProfilePolicy(name: string, policy: Policy | null): void {
    let profile = this.#teeConfig.profiles[name]
    if (!isRecord(profile)) {
      profile = { apps: [] }
      this.#teeConfig.profiles[name] = profile
    }
    // Patch
    const patchLevel: Record<string, string> = {}
    for (const [policyKey, configKey] of PATCH_MAP) {
      if (policy?.[policyKey] !== undefined) patchLevel[configKey] = String(policy[policyKey])
    }
    if (Object.keys(patchLevel).length > 0) {
      profile.patchLevel = patchLevel
    } else {
      delete profile.patchLevel
    }
    if (policy?.os_version !== undefined) {
      profile.osVersion = String(policy.os_version)
    } else {
      delete profile.osVersion
    }
    // Mode
    profile.mode = typeof policy?.mode === 'string' && PROFILE_MODES.includes(policy.mode as ProfileMode)
      ? policy.mode
      : 'patch'
    // Auto include new app
    if (policy?.auto_include_new_apps === true) {
      for (const [key, other] of Object.entries(this.#teeConfig.profiles)) {
        if (key !== name && isRecord(other)) delete other.autoIncludeNewApps
      }
      profile.autoIncludeNewApps = true
    } else {
      delete profile.autoIncludeNewApps
    }
    for (const key of IDENTITY_FIELDS) {
      if (policy?.[key] !== undefined) {
        profile[key] = String(policy[key])
      } else {
        delete profile[key]
      }
    }
  }

  #createProfile(): string {
    const names = Object.keys(this.#teeConfig.profiles)
    const base = names.length > 0 ? this.#teeConfig.profiles[names[0]] : undefined
    const clone: TeeProfile = isRecord(base) ? JSON.parse(JSON.stringify(base)) : { apps: [] }
    clone.apps = []
    let i = 1
    let name = `profile${i}`
    while (this.#hasProfile(name)) name = `profile${++i}`
    this.#teeConfig.profiles[name] = clone
    return name
  }

  #syncSectionRename(from: string, to: string): void {
    for (const [section, value] of Object.entries(this.get())) {
      if (section === 'target' || Array.isArray(value) || !value || typeof value !== 'object') continue
      const policy = value as Policy
      if (policy.profile === from) {
        policy.profile = to
        policy.profile_name = to
      }
    }
  }

  #renameProfile(from: string, to: string): boolean {
    if (from === to) return true
    if (this.#hasProfile(to)) return false
    const rebuilt: Record<string, TeeProfile> = {}
    for (const [key, value] of Object.entries(this.#teeConfig.profiles)) {
      rebuilt[key === from ? to : key] = value
    }
    this.#teeConfig.profiles = rebuilt
    return true
  }

  #resolveRename(policy: Policy, fallback: string): string {
    const current = typeof policy.profile === 'string' && this.#hasProfile(policy.profile)
      ? policy.profile
      : fallback
    const requested = typeof policy.profile_name === 'string' ? policy.profile_name.trim() : ''
    if (this.#hasProfile(current) && requested && requested !== current && !this.#hasProfile(requested)) {
      this.#renameProfile(current, requested)
      this.#syncSectionRename(current, requested)
      return requested
    }
    return current
  }

  #deleteProfile(name: string): boolean {
    if (Object.keys(this.#teeConfig.profiles).length <= 1 || !this.#hasProfile(name)) return false
    delete this.#teeConfig.profiles[name]
    if (!this.#hasProfile(this.#activeProfile)) this.#activeProfile = Object.keys(this.#teeConfig.profiles)[0]
    return true
  }

  // an app without a section shows the profile it will join, so saving that form keeps the profile's values
  // (an empty form would be applied to the profile and delete its patch levels and identity fields)
  override perAppDefault(): Policy {
    const name = this.#hasProfile('default') ? 'default' : (Object.keys(this.#teeConfig.profiles)[0] ?? 'default')
    return this.#profileWithMeta(name)
  }

  // own profiles only: `in` also accepts inherited names such as constructor or toString
  #hasProfile(name: string): boolean {
    return Object.hasOwn(this.#teeConfig.profiles, name)
  }

  #assignApp(pkg: string, profileName: string): void {
    const target = this.#teeConfig.profiles[profileName]
    if (!isRecord(target)) return
    for (const profile of Object.values(this.#teeConfig.profiles)) {
      if (Array.isArray(profile.apps)) profile.apps = profile.apps.filter(app => app !== pkg)
    }
    const apps = Array.isArray(target.apps) ? target.apps : []
    if (!apps.includes(pkg)) target.apps = [...apps, pkg]
  }

  #defaultProfile(): TeeProfile {
    const existing = this.#teeConfig.profiles.default
    if (isRecord(existing)) return existing as TeeProfile
    const profile = createDefaultConfig().profiles.default
    this.#teeConfig.profiles.default = profile
    return profile
  }
}
