/**
 * The smallest single splice turning `prev` into `next`: strip the common
 * prefix and suffix, replace what is left. Applied to a Y.Text as
 * delete(index, remove) + insert(index, insert), so concurrent edits elsewhere
 * in the text merge instead of being clobbered by a whole-string replace.
 */
export function textSplice(prev: string, next: string): { index: number; remove: number; insert: string } {
  let start = 0
  const max = Math.min(prev.length, next.length)
  while (start < max && prev[start] === next[start]) start++
  let end = 0
  while (end < max - start && prev[prev.length - 1 - end] === next[next.length - 1 - end]) end++
  return {
    index: start,
    remove: prev.length - start - end,
    insert: next.slice(start, next.length - end),
  }
}

/** Where a caret at `caret` in `prev` lands once `prev` becomes `next`. */
export function shiftCaret(prev: string, next: string, caret: number): number {
  const { index, remove, insert } = textSplice(prev, next)
  if (caret <= index) return caret
  if (caret >= index + remove) return caret - remove + insert.length
  return index + insert.length
}
