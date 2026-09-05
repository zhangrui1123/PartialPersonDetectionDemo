import { camera } from '@kit.CameraKit';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { createReceiver, onFrame, releaseReceiver } from 'libframereceiver.so';

const DOMAIN: number = 0x0D03;

export type GrayFrameHandler =
  (gray: Uint8Array, width: number, height: number, stride: number, yMean: number) => Promise<void>;

class UprightGray {
  gray: Uint8Array = new Uint8Array();
  width: number = 0;
  height: number = 0;
  stride: number = 0;
}

export class CameraSession {
  private context: common.UIAbilityContext;
  private cameraManager: camera.CameraManager | undefined = undefined;
  private session: camera.Session | undefined = undefined;
  private cameraInput: camera.CameraInput | undefined = undefined;
  private previewOutput: camera.PreviewOutput | undefined = undefined;
  private analysisOutput: camera.PreviewOutput | undefined = undefined;
  private handler: GrayFrameHandler | undefined = undefined;
  private busy: boolean = false;
  private started: boolean = false;
  private devices: Array<camera.CameraDevice> = [];
  private cameraIndex: number = -1;
  private surfaceId: string = '';
  private cameraHint: string = '未选择摄像头';
  private imageRotation: camera.ImageRotation = camera.ImageRotation.ROTATION_0;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  setGrayFrameHandler(handler: GrayFrameHandler): void {
    this.handler = handler;
  }

  getCameraHint(): string {
    return this.cameraHint;
  }

  hasMultipleCameras(): boolean {
    return this.devices.length > 1;
  }

  async switchNext(): Promise<void> {
    if (this.devices.length <= 1) {
      return;
    }
    this.cameraIndex = (this.cameraIndex + 1) % this.devices.length;
    await this.stop();
    await this.start(this.surfaceId);
  }

  async start(surfaceId: string): Promise<void> {
    if (this.started) {
      return;
    }
    this.surfaceId = surfaceId;
    this.cameraManager = camera.getCameraManager(this.context);
    const cameras: Array<camera.CameraDevice> = this.cameraManager.getSupportedCameras();
    if (cameras.length === 0) {
      throw new Error('未找到摄像头');
    }
    this.devices = cameras;
    this.logCameras(cameras);
    const device: camera.CameraDevice = this.pickCamera(cameras);
    this.cameraHint = this.describeCamera(device, this.cameraIndex, cameras.length);
    const capability: camera.CameraOutputCapability =
      this.cameraManager.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_PHOTO);
    if (capability.previewProfiles.length === 0) {
      throw new Error('摄像头不支持预览');
    }
    const profile: camera.Profile = this.pickPreviewProfile(capability.previewProfiles, 1280, 720);
    const recvSurface: string = createReceiver(profile.size.width, profile.size.height);
    onFrame((width: number, height: number, stride: number, yMean: number, buffer: ArrayBuffer) => {
      this.onNativeGray(width, height, stride, yMean, new Uint8Array(buffer));
    });
    this.cameraInput = this.cameraManager.createCameraInput(device);
    await this.cameraInput.open();
    this.previewOutput = this.cameraManager.createPreviewOutput(profile, surfaceId);
    this.analysisOutput = this.cameraManager.createPreviewOutput(profile, recvSurface);
    this.session = this.cameraManager.createSession(camera.SceneMode.NORMAL_PHOTO) as camera.PhotoSession;
    this.session.beginConfig();
    this.session.addInput(this.cameraInput);
    this.session.addOutput(this.previewOutput);
    this.session.addOutput(this.analysisOutput);
    await this.session.commitConfig();
    await this.session.start();
    this.imageRotation = this.resolveRotation();
    this.started = true;
    this.cameraHint = `${this.describeCamera(device, this.cameraIndex, cameras.length)} · ` +
      `分析${profile.size.width}×${profile.size.height} rot=${this.imageRotation}`;
    hilog.info(DOMAIN, 'CameraSession',
      'started photo dual %{public}dx%{public}d rot=%{public}d camOri=%{public}d surface=%{public}s',
      profile.size.width, profile.size.height, this.imageRotation, device.cameraOrientation, recvSurface);
  }

  async stop(): Promise<void> {
    if (!this.started) {
      return;
    }
    this.started = false;
    try {
      releaseReceiver();
    } catch (error) {
      hilog.warn(DOMAIN, 'CameraSession', 'releaseReceiver: %{public}s', JSON.stringify(error));
    }
    try {
      if (this.session) {
        await this.session.stop();
        await this.session.release();
      }
    } catch (error) {
      hilog.warn(DOMAIN, 'CameraSession', 'stop session: %{public}s', JSON.stringify(error));
    }
    try {
      await this.cameraInput?.close();
    } catch (error) {
      hilog.warn(DOMAIN, 'CameraSession', 'close input: %{public}s', JSON.stringify(error));
    }
    this.session = undefined;
    this.cameraInput = undefined;
    this.previewOutput = undefined;
    this.analysisOutput = undefined;
  }

  private onNativeGray(width: number, height: number, stride: number, yMean: number, gray: Uint8Array): void {
    if (!this.started || this.busy || !this.handler) {
      return;
    }
    this.busy = true;
    const upright: UprightGray = this.rotateGray(gray, width, height, stride, this.imageRotation);
    this.handler(upright.gray, upright.width, upright.height, upright.stride, yMean).catch((error: Error) => {
      hilog.warn(DOMAIN, 'CameraSession', 'gray handle failed: %{public}s', JSON.stringify(error));
    }).then(() => {
      this.busy = false;
    });
  }

  private resolveRotation(): camera.ImageRotation {
    try {
      const degree: number = display.getDefaultDisplaySync().rotation * 90;
      if (this.analysisOutput) {
        return this.analysisOutput.getPreviewRotation(degree);
      }
    } catch (error) {
      hilog.warn(DOMAIN, 'CameraSession', 'preview rotation: %{public}s', JSON.stringify(error));
    }
    return camera.ImageRotation.ROTATION_0;
  }

  private rotateGray(src: Uint8Array, width: number, height: number, stride: number,
    rotation: camera.ImageRotation): UprightGray {
    const out: UprightGray = new UprightGray();
    if (rotation === camera.ImageRotation.ROTATION_0) {
      out.gray = src;
      out.width = width;
      out.height = height;
      out.stride = stride;
      return out;
    }
    if (rotation === camera.ImageRotation.ROTATION_180) {
      const dest: Uint8Array = new Uint8Array(width * height);
      for (let y: number = 0; y < height; y++) {
        const srcRow: number = y * stride;
        const destRow: number = (height - 1 - y) * width;
        for (let x: number = 0; x < width; x++) {
          dest[destRow + (width - 1 - x)] = src[srcRow + x];
        }
      }
      out.gray = dest;
      out.width = width;
      out.height = height;
      out.stride = width;
      return out;
    }
    const destW: number = height;
    const destH: number = width;
    const dest: Uint8Array = new Uint8Array(destW * destH);
    if (rotation === camera.ImageRotation.ROTATION_90) {
      for (let y: number = 0; y < height; y++) {
        const srcRow: number = y * stride;
        for (let x: number = 0; x < width; x++) {
          dest[x * destW + (destW - 1 - y)] = src[srcRow + x];
        }
      }
    } else {
      for (let y: number = 0; y < height; y++) {
        const srcRow: number = y * stride;
        for (let x: number = 0; x < width; x++) {
          dest[(destH - 1 - x) * destW + y] = src[srcRow + x];
        }
      }
    }
    out.gray = dest;
    out.width = destW;
    out.height = destH;
    out.stride = destW;
    return out;
  }

  private pickCamera(cameras: Array<camera.CameraDevice>): camera.CameraDevice {
    if (this.cameraIndex >= 0 && this.cameraIndex < cameras.length) {
      return cameras[this.cameraIndex];
    }
    for (let i = 0; i < cameras.length; i++) {
      if (cameras[i].cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) {
        this.cameraIndex = i;
        return cameras[i];
      }
    }
    this.cameraIndex = cameras.length - 1;
    return cameras[this.cameraIndex];
  }

  private logCameras(cameras: Array<camera.CameraDevice>): void {
    for (let i = 0; i < cameras.length; i++) {
      hilog.info(DOMAIN, 'CameraSession', 'camera[%{public}d] pos=%{public}d id=%{public}s',
        i, cameras[i].cameraPosition, cameras[i].cameraId);
    }
  }

  private describeCamera(device: camera.CameraDevice, index: number, total: number): string {
    let position: string = '未知';
    if (device.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) {
      position = '后置';
    } else if (device.cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT) {
      position = '前置';
    }
    return `${position}摄像头 ${index + 1}/${total}`;
  }

  private pickPreviewProfile(profiles: Array<camera.Profile>, targetW: number,
    targetH: number): camera.Profile {
    let best: camera.Profile = profiles[0];
    let bestScore: number = Number.MAX_VALUE;
    for (let i = 0; i < profiles.length; i++) {
      const item: camera.Profile = profiles[i];
      if (item.format !== camera.CameraFormat.CAMERA_FORMAT_YUV_420_SP) {
        continue;
      }
      const score: number = Math.abs(item.size.width - targetW) + Math.abs(item.size.height - targetH);
      if (score < bestScore) {
        bestScore = score;
        best = item;
      }
    }
    return best;
  }
}
