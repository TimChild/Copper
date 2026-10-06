/** Page → host messages about chat (docs/canvas.md, "Chat"). */
export type ChatPageMessage =
  /** The panel was shown or hidden: remember it for this canvas and person. */
  | { type: 'chat'; open: boolean }
  /** Read up to message `id` (at `at` ms); `mentionIds` are message ids whose mention of me was just read. */
  | { type: 'chatRead'; id: string | null; at: number | null; mentionIds: string[] }
  /** The @ picker opened: a fresh member list, please (answered with `setChat({members})`). */
  | { type: 'chatMembers' }
  /** A message mentioned these people: notify them (copper-cloud 0.6.0+). */
  | { type: 'mention'; messageId: string; userIds: string[]; excerpt: string }
