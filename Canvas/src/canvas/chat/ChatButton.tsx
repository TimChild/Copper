/**
 * The chat toggle beside Share. A count of unread messages on it; the count
 * turns accent (and says "@") when one of them mentions you.
 */
import { useSyncExternalStore } from 'react'
import { MessageCircle } from 'lucide-react'
import { IconButton, cn } from '../components/ui'
import type { ChatHub } from './hub'

export function ChatButton({ hub }: { hub: ChatHub }) {
  useSyncExternalStore(hub.subscribe, hub.getVersion)
  if (!hub.available) return null
  const { unread, config } = hub
  const count = unread.count
  const mentioned = unread.mentions > 0
  const shown = count > 99 ? '99+' : String(count)
  const label = config.open
    ? 'Hide chat'
    : count > 0
      ? `Chat, ${count} unread${mentioned ? `, ${unread.mentions === 1 ? 'a mention' : `${unread.mentions} mentions`} of you` : ''}`
      : 'Chat'
  return (
    <IconButton
      size="sm"
      label={label}
      keys="C"
      tipBelow
      tipEnd
      active={config.open}
      data-testid="chat-toggle"
      onClick={() => hub.toggle()}
      className="relative"
    >
      <MessageCircle className="h-4 w-4" />
      {count > 0 && !config.open && (
        <span
          aria-hidden="true"
          className={cn(
            'pop-in pointer-events-none absolute -right-1 -top-1 flex h-[16px] min-w-[16px] items-center justify-center rounded-full px-[4px] text-[10px] font-semibold leading-none tabular-nums ring-2 ring-surface',
            mentioned ? 'bg-accent text-accent-ink' : 'bg-ink-2 text-surface'
          )}
        >
          {mentioned ? `@${unread.mentions > 1 ? unread.mentions : ''}` : shown}
        </span>
      )}
    </IconButton>
  )
}
