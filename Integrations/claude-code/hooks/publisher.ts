/**
 * Keeps the terminal's `agent.*` labels in step with Claude Code, with as few
 * round trips as possible: changes inside the debounce window collapse into
 * one request, unchanged values are never sent, and only one request is in
 * flight at a time. A failed write keeps the old picture, so the next publish
 * retries the difference.
 *
 * A new publisher doesn't know what the terminal carries (a reload of the mod,
 * an earlier Claude that crashed), so its first write sends every owned key,
 * removing whatever was left behind instead of trusting an empty picture.
 *
 * The same rules as @wierdbytes/pi-wierdr's `herdr/publisher.ts`, with the timer
 * handed in (`$.clock.after`).
 */

import { clearLabels, diffLabels, type Labels } from './meta'
import type { After, Cancelable } from './timer'

export type SendLabels = (labels: Record<string, string>) => Promise<boolean>

export class LabelPublisher {
  /** What the terminal is believed to carry; undefined until the first write lands. */
  private applied: Labels | undefined
  /** What it should carry once the queue drains. */
  private desired: Labels = {}
  private timer: Cancelable | undefined
  private draining: Promise<void> | undefined
  /** A flush came in while a write was out: go around once more. */
  private again = false
  private stopped = false

  constructor(
    private readonly send: SendLabels,
    private readonly after: After,
    private readonly debounceMs = 150,
  ) {}

  /** Whether a label was ever written (the terminal may carry ours). */
  get hasWritten(): boolean {
    return this.applied !== undefined
  }

  /** Schedule the terminal to carry exactly `labels`. */
  publish(labels: Labels): void {
    if (this.stopped) return
    this.desired = labels
    if (this.timer) return
    try {
      this.timer = this.after(this.debounceMs, () => {
        this.timer = undefined
        void this.flush()
      })
    } catch {
      // No timer (the mod is unloading): write now.
      void this.flush()
    }
  }

  /** Send the pending difference now. Resolves once the terminal has it (or the write failed). */
  flush(): Promise<void> {
    this.stopTimer()
    if (this.draining) {
      this.again = true
      return this.draining
    }
    this.draining = this.drain().finally(() => {
      this.draining = undefined
    })
    return this.draining
  }

  private stopTimer(): void {
    if (!this.timer) return
    try {
      this.timer.cancel()
    } catch {
      // A timer that already fired.
    }
    this.timer = undefined
  }

  private async drain(): Promise<void> {
    do {
      this.again = false
      if (this.stopped) return
      const target = this.desired
      const change = this.applied ? diffLabels(this.applied, target) : { ...clearLabels(), ...target }
      if (Object.keys(change).length === 0) continue
      const ok = await this.send(change).catch(() => false)
      if (!ok) return
      this.applied = target
    } while (this.again)
  }

  /** Stop publishing and remove every owned label (Claude is quitting). */
  async clear(): Promise<void> {
    this.stopped = true
    this.stopTimer()
    if (this.draining) await this.draining
    await this.send(clearLabels()).catch(() => false)
    this.applied = {}
    this.desired = {}
  }

  /**
   * Drop what is queued without touching the terminal: the conversation is
   * being replaced (`/clear`, `/resume`) and the next events republish.
   */
  cancel(): void {
    this.stopTimer()
    this.desired = this.applied ?? this.desired
  }
}
