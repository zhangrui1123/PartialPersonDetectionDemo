export const createReceiver: (width: number, height: number) => string;
export const onFrame: (callback: (width: number, height: number, stride: number, yMean: number,
  buffer: ArrayBuffer) => void) => void;
export const releaseReceiver: () => void;
