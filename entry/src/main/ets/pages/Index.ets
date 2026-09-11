import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CameraSession } from '../model/CameraSession';
import { PersonBox } from '../model/PersonBox';
import { PresenceTracker } from '../model/PresenceTracker';
import { YoloNanoDetector } from '../model/YoloNanoDetector';

const DOMAIN: number = 0x0D04;
const PREVIEW_ID: string = 'pcCameraPreview';

@Entry
@Component
struct Index {
  @State present: boolean = false;
  @State personCount: number = 0;
  @State partialCount: number = 0;
  @State maxScore: number = 0;
  @State statusHint: string = '正在申请相机权限...';
  @State engineHint: string = '检测引擎未就绪';
  @State cameraHint: string = '优先使用后置摄像头';
  @State canSwitchCamera: boolean = false;
  @State boxes: PersonBox[] = [];
  @State viewWidth: number = 960;
  @State viewHeight: number = 540;
  @State frameWidth: number = 640;
  @State frameHeight: number = 480;
  @State previewMap: image.PixelMap | undefined = undefined;
  private xController: XComponentController = new XComponentController();
  private cameraSession: CameraSession | undefined = undefined;
  private yolo: YoloNanoDetector = new YoloNanoDetector();
  private tracker: PresenceTracker = new PresenceTracker(1000);
  private surfaceReady: boolean = false;
  private started: boolean = false;
  private context: common.UIAbilityContext | undefined = undefined;

  aboutToAppear(): void {
    this.bootstrap();
  }

  aboutToDisappear(): void {
    this.teardown();
  }

  private async bootstrap(): Promise<void> {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.context = context;
    const granted: boolean = await this.requestCameraPermission(context);
    if (!granted) {
      this.statusHint = '未获得相机权限，无法启动检测';
      return;
    }
    const engineOk: boolean = await this.yolo.init(context);
    this.engineHint = engineOk ? '显示/输入 · 灰度 1ch' : '视觉引擎不可用，仅相机预览';
    this.statusHint = '等待相机画面...';
    this.tryStart(context);
  }

  private async requestCameraPermission(context: common.UIAbilityContext): Promise<boolean> {
    const permissions: Permissions[] = ['ohos.permission.CAMERA'];
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const result = await atManager.requestPermissionsFromUser(context, permissions);
    return result.authResults.every((status: abilityAccessCtrl.GrantStatus) => {
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    });
  }

  private onSurfaceReady(): void {
    this.surfaceReady = true;
    if (this.context) {
      this.tryStart(this.context);
    }
  }

  private tryStart(context: common.UIAbilityContext): void {
    if (this.started || !this.surfaceReady) {
      return;
    }
    this.started = true;
    const surfaceId: string = this.xController.getXComponentSurfaceId();
    this.cameraSession = new CameraSession(context);
    this.cameraSession.setGrayFrameHandler(async (gray: Uint8Array, width: number, height: number,
      stride: number, yMean: number) => {
      await this.onGrayFrame(gray, width, height, stride, yMean);
    });
    this.cameraSession.start(surfaceId).then(() => {
      this.statusHint = '实时检测中';
      this.cameraHint = this.cameraSession?.getCameraHint() ?? this.cameraHint;
      this.canSwitchCamera = this.cameraSession?.hasMultipleCameras() ?? false;
    }).catch((error: Error) => {
      this.started = false;
      this.statusHint = `相机启动失败: ${error.message}`;
      hilog.error(DOMAIN, 'Index', 'camera start failed: %{public}s', JSON.stringify(error));
    });
  }

  private async onGrayFrame(gray: Uint8Array, width: number, height: number, stride: number,
    yMean: number): Promise<void> {
    if (this.frameWidth !== width || this.frameHeight !== height) {
      this.frameWidth = width;
      this.frameHeight = height;
      hilog.info(DOMAIN, 'Index', 'native frame %{public}dx%{public}d yMean=%{public}s',
        width, height, yMean.toFixed(3));
    }
    this.showGray(gray, width, height, stride);
    const hits: PersonBox[] = await this.yolo.detectFromGray(gray, width, height, stride);
    const hint: string = this.yolo.getLastHint();
    if (this.engineHint !== hint) {
      this.engineHint = hint;
    }
    this.boxes = hits;
    this.personCount = hits.length;
    let partial: number = 0;
    let maxScore: number = 0;
    for (let i = 0; i < hits.length; i++) {
      if (hits[i].partial) {
        partial += 1;
      }
      if (hits[i].score > maxScore) {
        maxScore = hits[i].score;
      }
    }
    this.partialCount = partial;
    this.maxScore = maxScore;
    const changed: boolean = this.tracker.update(hits.length > 0);
    this.present = this.tracker.isPresent();
    if (changed) {
      const statusText: string = this.present ? '有人' : '无人';
      hilog.info(DOMAIN, 'Index',
        '上报 %{public}s count=%{public}d partial=%{public}d score=%{public}s',
        statusText, this.personCount, this.partialCount, this.maxScore.toFixed(3));
      this.statusHint = `状态变化: ${statusText}`;
    }
  }

  private showGray(gray: Uint8Array, width: number, height: number, stride: number): void {
    try {
      const rgba: Uint8Array = new Uint8Array(width * height * 4);
      let offset: number = 0;
      for (let y: number = 0; y < height; y++) {
        const row: number = y * stride;
        for (let x: number = 0; x < width; x++) {
          const value: number = gray[row + x];
          rgba[offset] = value;
          rgba[offset + 1] = value;
          rgba[offset + 2] = value;
          rgba[offset + 3] = 255;
          offset += 4;
        }
      }
      const options: image.InitializationOptions = {
        size: {
          width: width,
          height: height
        },
        srcPixelFormat: image.PixelMapFormat.RGBA_8888,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      };
      const next: image.PixelMap = image.createPixelMapSync(rgba.buffer, options);
      const prev: image.PixelMap | undefined = this.previewMap;
      this.previewMap = next;
      if (prev) {
        prev.release();
      }
    } catch (error) {
      hilog.warn(DOMAIN, 'Index', 'showGray failed: %{public}s', JSON.stringify(error));
    }
  }

  private async switchCamera(): Promise<void> {
    if (!this.cameraSession) {
      return;
    }
    this.statusHint = '正在切换摄像头...';
    try {
      await this.cameraSession.switchNext();
      this.cameraHint = this.cameraSession.getCameraHint();
      this.statusHint = '实时检测中';
    } catch (error) {
      this.statusHint = '切换摄像头失败';
      hilog.error(DOMAIN, 'Index', 'switch camera failed: %{public}s', JSON.stringify(error));
    }
  }

  private async teardown(): Promise<void> {
    await this.cameraSession?.stop();
    this.yolo.release();
    if (this.previewMap) {
      this.previewMap.release();
      this.previewMap = undefined;
    }
  }

  private boxTitle(box: PersonBox): string {
    const scoreText: string = box.score.toFixed(2);
    return box.partial ? `部分人体 ${scoreText}` : `人体 ${scoreText}`;
  }

  private boxX(box: PersonBox): number {
    return box.left / this.frameWidth * this.viewWidth;
  }

  private boxY(box: PersonBox): number {
    return box.top / this.frameHeight * this.viewHeight;
  }

  private boxW(box: PersonBox): number {
    return box.width / this.frameWidth * this.viewWidth;
  }

  private boxH(box: PersonBox): number {
    return box.height / this.frameHeight * this.viewHeight;
  }

  build() {
    Stack() {
      XComponent({
        id: PREVIEW_ID,
        type: XComponentType.SURFACE,
        controller: this.xController
      })
        .id(PREVIEW_ID)
        .width(160)
        .height(90)
        .position({ x: -640, y: -360 })
        .onLoad(() => {
          this.onSurfaceReady();
        })

      Row() {
      Stack() {
        if (this.previewMap) {
          Image(this.previewMap)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Fill)
            .syncLoad(true)
            .interpolation(ImageInterpolation.Low)
            .grayscale(1)
        } else {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(Color.Black)
        }

        ForEach(this.boxes, (box: PersonBox) => {
          Column() {
            Text(this.boxTitle(box))
              .fontSize(12)
              .fontColor(Color.White)
              .backgroundColor(box.partial ? '#E67E22' : '#22C55E')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            Blank()
          }
            .width(this.boxW(box))
            .height(this.boxH(box))
            .border({
              width: 2,
              color: box.partial ? '#E67E22' : '#22C55E'
            })
            .position({ x: this.boxX(box), y: this.boxY(box) })
        }, (box: PersonBox) => `${box.left}_${box.top}_${box.score}`)

        Row() {
          Text(this.present ? '有人' : '无人')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
          Text(`  ${this.personCount}人  部分${this.partialCount}`)
            .fontSize(16)
            .fontColor(Color.White)
        }
        .width('100%')
        .height(48)
        .padding({ left: 16 })
        .backgroundColor(this.present ? '#CC16A34A' : '#CC334155')
        .alignItems(VerticalAlign.Center)
      }
      .id('previewArea')
      .layoutWeight(3)
      .height('100%')
      .clip(true)
      .backgroundColor(Color.Black)
      .onAreaChange((_old: Area, area: Area) => {
        this.viewWidth = Number(area.width);
        this.viewHeight = Number(area.height);
      })

      Column({ space: 16 }) {
        Text('部分人体检测 Demo')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('显示/输入 · 灰度 1ch')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Text(this.present ? '有人' : '无人')
          .fontSize(40)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.present ? $r('app.color.present_color') : $r('app.color.absent_color'))
        Text(this.statusHint)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .margin({ top: 8 })
        Text(this.engineHint)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Text(this.cameraHint)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Text(`置信度 ${this.maxScore.toFixed(2)}`)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Button('切换摄像头')
          .width('100%')
          .height(44)
          .enabled(this.canSwitchCamera)
          .onClick(() => {
            this.switchCamera();
          })
        Blank()
        Text('检测框贴边视为部分人体，同样上报有人。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width(320)
      .height('100%')
      .padding(24)
      .backgroundColor($r('app.color.panel_background'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }
}
