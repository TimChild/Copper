/** Base64 for Yjs updates crossing the bridge. Chunked so big docs never blow the stack. */
export function toBase64(bytes: Uint8Array): string {
  let s = ''
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}

export function fromBase64(text: string): Uint8Array {
  let clean = text.replace(/\s/g, '').replace(/-/g, '+').replace(/_/g, '/')
  while (clean.length % 4) clean += '='
  const bin = atob(clean)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}
