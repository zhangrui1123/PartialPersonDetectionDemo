export class PresenceTracker {
  private confirmMs: number;
  private present: boolean = false;
  private pending: boolean | undefined = undefined;
  private pendingSince: number = 0;

  constructor(confirmMs: number = 1000) {
    this.confirmMs = confirmMs;
  }

  isPresent(): boolean {
    return this.present;
  }

  update(detected: boolean): boolean {
    const now: number = Date.now();
    if (detected === this.present) {
      this.pending = undefined;
      this.pendingSince = 0;
      return false;
    }
    if (this.pending !== detected) {
      this.pending = detected;
      this.pendingSince = now;
      return false;
    }
    if (now - this.pendingSince >= this.confirmMs) {
      this.present = detected;
      this.pending = undefined;
      this.pendingSince = 0;
      return true;
    }
    return false;
  }
}
