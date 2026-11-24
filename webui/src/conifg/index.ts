import { Cli } from '../cli'
import { file } from '../file'
import { OMK_MOD_ID, TEES_MOD_ID } from '../constant'
import type { Config } from './config'
import { ConfigIni } from './official/config_ini'
import { ConfigLegacy } from './official/config_legacy'
import { ConfigOhMyKeyMint } from './ohmykeymint/config_ohmykeymint'
import { ConfigTeeSimulator } from './teesimulator/config_teesimulator'

export const cli = new Cli()

// config.ini when it exists, or on a fresh install without target.txt; an existing target.txt without config.ini stays on it
async function usesConfigIni(): Promise<boolean> {
  if (await file.exist('/data/adb/tricky_store/config.ini').catch(() => false)) return true
  return !(await file.exist('/data/adb/tricky_store/target.txt').catch(() => false))
}

async function createConfig(tsInfo: Record<string, string>): Promise<Config> {
  const modId = tsInfo.id
  const versionCode = parseInt(tsInfo.versionCode, 10)
  switch (true) {
    case modId === OMK_MOD_ID:
      return new ConfigOhMyKeyMint()      // Oh My Keymint
    case modId === TEES_MOD_ID:
      return new ConfigTeeSimulator()     // Tee Simulator
    // a build with versionCode >= 246 that still uses target.txt has no config.ini: keep writing what it reads
    case ConfigIni.support(versionCode) && await usesConfigIni():
      return new ConfigIni()              // config.ini
    default:
      return new ConfigLegacy()           // target.txt + security_patch.txt
  }
}

export const config: Config = await (async () => {
  try {
    return await createConfig(await cli.getTrickyStoreInfo())
  } catch {
    return new ConfigLegacy()
  }
})()
