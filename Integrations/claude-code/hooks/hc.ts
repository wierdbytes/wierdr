/**
 * Talking to herdr-core through `hc connect`: the JSON-RPC API over stdin and
 * stdout. A hooks module has no sockets, but it can run a program with
 * `$.process.run(argv, { stdin })`, and `hc connect` reads one request line,
 * answers one line and exits at the end of its input. The same methods and
 * params pi-herdr sends over the socket: `terminal.label` for the labels,
 * `doc.get` / `doc.set` for the limits document.
 *
 * Pure helpers: building the request line, reading the answer. `register.ts`
 * runs the process.
 */

import type { Doc } from './limits-publisher'

/** One answer from herdr-core: its result, or the error kind it gave (`conflict`, `not_found`…). */
export type RpcReply = { ok: true; result: unknown } | { ok: false; error: string }

/** The request line `hc connect` reads. */
export function requestLine(id: number, method: string, params: Record<string, unknown>): string {
  return `${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`
}

/**
 * herdr-core's answer to request `id` in `hc connect`'s output: the first
 * line that answers it. Notifications or other lines before it are skipped.
 */
export function parseReply(stdout: string, id: number): RpcReply {
  for (const line of stdout.split('\n')) {
    const text = line.trim()
    if (!text.startsWith('{')) continue
    let reply: { id?: unknown; error?: { message?: unknown; data?: { kind?: unknown } }; result?: unknown }
    try {
      reply = JSON.parse(text)
    } catch {
      continue
    }
    if (reply?.id !== id) continue
    if (reply.error !== undefined) return { ok: false, error: String(reply.error?.data?.kind ?? reply.error?.message ?? 'error') }
    if (reply.result !== undefined) return { ok: true, result: reply.result }
    return { ok: false, error: 'bad_reply' }
  }
  return { ok: false, error: 'bad_reply' }
}

/** `doc.get`'s result as a document; undefined when it isn't one. */
export function docOf(reply: RpcReply): Doc | undefined {
  if (!reply.ok) return undefined
  const result = reply.result as { value?: unknown; version?: unknown } | null
  if (typeof result?.version !== 'number') return undefined
  return { value: result.value ?? null, version: result.version }
}

/** `doc.set`'s result: the new version, `"conflict"`, or undefined on any other failure. */
export function setResultOf(reply: RpcReply): number | 'conflict' | undefined {
  if (!reply.ok) return reply.error === 'conflict' ? 'conflict' : undefined
  const next = (reply.result as { version?: unknown } | null)?.version
  return typeof next === 'number' ? next : undefined
}
