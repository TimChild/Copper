/** Pick the host: the Copper bridge when present, the standalone fake otherwise. */
import type { Host } from './types'
import { createCopperHost, hasCopperBridge } from './copper'
import { createStandaloneHost } from './standalone'

export type * from './types'
export { ACCEPTED_IMAGE_TYPES, MAX_FILE_BYTES, extensionFor } from './types'
export { createCopperHost, hasCopperBridge } from './copper'
export {
  createStandaloneHost,
  DEFAULT_EASEL_ID,
  STANDALONE_VIEWER,
  storageKey,
  easelIdFromSearch,
} from './standalone'

export function detectHost(): Host {
  return hasCopperBridge() ? createCopperHost() : createStandaloneHost()
}
