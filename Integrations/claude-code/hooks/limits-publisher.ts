/**
 * Writes the readings into herdr-core's `limits` document without losing
 * anyone's writes, as pi-herdr's `limits-publisher.ts` does:
 *
 *   - every reading is written, even with the same numbers: `at` says when
 *     the subscription last confirmed them, so readers tell live from stale;
 *   - readings inside the debounce window go out as one write;
 *   - every write reads the document, folds into it and writes it back at the
 *     version it read; when another writer came in between, it reads again
 *     and retries;
 *   - a failed write is dropped, not retried: the next turn brings a fresh
 *     reading anyway.
 *
 * Never throws and never blocks a hook: `record` only queues.
 */

import { asLimitsDoc, foldReading, type LimitAccount, type LimitReading, type LimitsDoc } from './limits'
import type { After, Cancelable } from './timer'

/** A herdr-core document and its version (zero when never written). */
export interface Doc {
  value: unknown
  version: number
}

export interface DocStore {
  get(): Promise<Doc | undefined>
  /** The new version, `"conflict"` when the document moved on, undefined on failure. */
  set(value: LimitsDoc, version: number): Promise<number | 'conflict' | undefined>
}

export interface LimitsPublisherOptions {
  debounceMs?: number
  /** Writes tried per flush before giving up on conflicts. */
  attempts?: number
}

interface Pending {
  reading: LimitReading
  account: LimitAccount
  /** When it was read, epoch ms. */
  at: number
}

export class LimitsPublisher {
  private pending: Pending[] = []
  private timer: Cancelable | undefined
  private draining: Promise<void> | undefined
  private again = false
  private readonly debounceMs: number
  private readonly attempts: number
  /** The machine name stored with each reading. */
  host: string | undefined

  constructor(
    private readonly store: DocStore,
    private readonly after: After,
    options: LimitsPublisherOptions = {},
  ) {
    this.debounceMs = options.debounceMs ?? 500
    this.attempts = options.attempts ?? 5
  }

  /** Queue a reading taken at `at` (epoch ms); it is written within the debounce window. */
  record(reading: LimitReading, account: LimitAccount, at: number): void {
    this.pending.push({ reading, account, at })
    if (this.timer) return
    try {
      this.timer = this.after(this.debounceMs, () => {
        this.timer = undefined
        void this.flush()
      })
    } catch {
      void this.flush()
    }
  }

  /** Write what is queued now. Resolves once it landed or the write failed. */
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

  /** Drop what is queued (Claude is quitting and can't wait). */
  cancel(): void {
    this.stopTimer()
    this.pending = []
  }

  private stopTimer(): void {
    if (!this.timer) return
    try {
      this.timer.cancel()
    } catch {
      // Already fired.
    }
    this.timer = undefined
  }

  private async drain(): Promise<void> {
    do {
      this.again = false
      const batch = this.pending
      this.pending = []
      if (batch.length) await this.write(batch).catch(() => undefined)
    } while (this.again)
  }

  private async write(batch: Pending[]): Promise<void> {
    for (let attempt = 0; attempt < this.attempts; attempt++) {
      const current = await this.store.get()
      if (!current) return
      let doc = asLimitsDoc(current.value)
      for (const p of batch) doc = foldReading(doc, p.reading, p.account, Math.floor(p.at / 1000), this.host)
      const result = await this.store.set(doc, current.version)
      if (result !== 'conflict') return
    }
  }
}
