/**
 * The one chat hub, following the controller's session: a new `init` hands
 * it the new document, a status change lets it settle the read mark.
 */
import { controller } from '../../controller'
import { ChatHub } from './hub'

export const chat = new ChatHub(fn => controller.subscribe(fn))

let attached: unknown = undefined
controller.subscribe(() => {
  if (controller.session !== attached) {
    attached = controller.session
    chat.attach(controller.session)
  }
})

export type { ChatPageMessage } from './bridge'
