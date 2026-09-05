export class PresenceTracker {
  private enterFrames: number;
  private exitFrames: number;
  private present: boolean = false;
  private seen: number = 0;
  private missed: number = 0;

  constructor(enterFrames: number = 3, exitFrames: number = 10) {
    this.enterFrames = enterFrames;
    this.exitFrames = exitFrames;
  }

  isPresent(): boolean {
    return this.present;
  }

  update(detected: boolean): boolean {
    if (detected) {
      this.seen += 1;
      this.missed = 0;
      if (!this.present && this.seen >= this.enterFrames) {
        this.present = true;
        return true;
      }
    } else {
      this.missed += 1;
      this.seen = 0;
      if (this.present && this.missed >= this.exitFrames) {
        this.present = false;
        return true;
      }
    }
    return false;
  }
}
