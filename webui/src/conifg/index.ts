import { Cli } from '../cli'
import { OMK_MOD_ID, TEES_MOD_ID } from '../constant'
import type { Config } from './config'
import { ConfigIni } from './official/config_ini'
import { ConfigLegacy } from './official/config_legacy'
import { ConfigOhMyKeyMint } from './ohmykeymint/config_ohmykeymint'
import { ConfigTeeSimulator } from './teesimulator/config_teesimulator'

export const cli = new Cli()

// TrickyStore forks that keep target.txt + security_patch.txt whatever their versionCode: upstream's own fork test
// (first config.ini support) on module.prop; matched against its values, so a stale config.ini never switches them to ini
const TS_FORK_PATTERN = /James|beakthoven|JingMatrix/

async function createConfig(tsInfo: Record<string, string>): Promise<Config> {
  const modId = tsInfo.id
  const versionCode = parseInt(tsInfo.versionCode, 10)
  switch (true) {
    case modId === OMK_MOD_ID:
      return new ConfigOhMyKeyMint()      // Oh My Keymint
    case modId === TEES_MOD_ID:
      return new ConfigTeeSimulator()     // Tee Simulator
    case ConfigIni.support(versionCode) && !TS_FORK_PATTERN.test(Object.values(tsInfo).join('\n')):
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
