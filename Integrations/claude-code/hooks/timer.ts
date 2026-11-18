/**
 * A hooks module has no `setTimeout`: its timers are `$.clock.after`. The
 * publishers take this small interface instead, so they stay plain classes
 * that tests drive with a fake clock.
 */

export interface Cancelable {
  cancel(): void
}

/** Calls `fn` once after `ms` milliseconds (`$.clock.after`). */
export type After = (ms: number, fn: () => void) => Cancelable
