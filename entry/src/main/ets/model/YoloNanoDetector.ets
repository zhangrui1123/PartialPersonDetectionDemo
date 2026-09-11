import { common } from '@kit.AbilityKit';
import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PersonBox } from './PersonBox';

const DOMAIN: number = 0x0D05;
const MODEL_NAME: string = 'yolo_gray_640_480.ms';
const INPUT_WIDTH: number = 640;
const INPUT_HEIGHT: number = 480;
const CONF_PARTIAL: number = 0.05;
const IOU_THRESHOLD: number = 0.45;
const MIN_BOX_AREA_RATIO: number = 0.0004;
const MAX_BOX_AREA_RATIO: number = 0.92;
const PAD_VALUE: number = 114 / 255;

class Letterbox {
  scale: number = 1;
  padX: number = 0;
  padY: number = 0;
}

export class YoloNanoDetector {
  private model: mindSporeLite.Model | undefined = undefined;
  private frameCount: number = 0;
  private lastHint: string = 'YOLO gray';

  async init(context: common.UIAbilityContext): Promise<boolean> {
    if (!canIUse('SystemCapability.AI.MindSporeLite')) {
      hilog.error(DOMAIN, 'YoloNano', 'MindSporeLite not available');
      return false;
    }
    try {
      const rawFile: Uint8Array = await context.resourceManager.getRawFileContent(MODEL_NAME);
      const modelBuffer: ArrayBuffer = rawFile.buffer.slice(rawFile.byteOffset,
        rawFile.byteOffset + rawFile.byteLength);
      this.model = await mindSporeLite.loadModelFromBuffer(modelBuffer, {
        target: ['cpu'],
        cpu: {
          threadNum: 4
        }
      });
      const inputs: mindSporeLite.MSTensor[] = this.model.getInputs();
      if (inputs.length === 0) {
        this.model = undefined;
        return false;
      }
      hilog.info(DOMAIN, 'YoloNano', 'model ready input=%{public}s elements=%{public}d',
        inputs[0].shape.join('x'), inputs[0].elementNum);
      return true;
    } catch (error) {
      hilog.error(DOMAIN, 'YoloNano', 'load failed: %{public}s', JSON.stringify(error));
      this.model = undefined;
      return false;
    }
  }

  isReady(): boolean {
    return this.model !== undefined;
  }

  getLastHint(): string {
    return this.lastHint;
  }

  async detectFromGray(gray: Uint8Array, frameWidth: number, frameHeight: number,
    rowStride: number): Promise<PersonBox[]> {
    if (!this.model || frameWidth <= 0 || frameHeight <= 0) {
      return [];
    }
    try {
      const stride: number = rowStride > 0 ? rowStride : frameWidth;
      const letterbox: Letterbox = this.makeLetterbox(frameWidth, frameHeight);
      const inputData: Float32Array = this.preprocess(gray, frameWidth, frameHeight, stride, letterbox);
      const inputs: mindSporeLite.MSTensor[] = this.model.getInputs();
      inputs[0].setData(inputData.buffer);
      const outputs: mindSporeLite.MSTensor[] = await this.model.predict(inputs);
      if (outputs.length === 0) {
        this.lastHint = 'YOLO gray 无输出';
        return [];
      }
      const boxes: PersonBox[] = this.parse(this.tensorToFloat32(outputs[0]), outputs[0].shape,
        frameWidth, frameHeight, letterbox);
      this.frameCount += 1;
      if (this.frameCount <= 3 || this.frameCount % 15 === 0) {
        hilog.info(DOMAIN, 'YoloNano',
          'src=%{public}dx%{public}d hits=%{public}d hint=%{public}s',
          frameWidth, frameHeight, boxes.length, this.lastHint);
      }
      return boxes;
    } catch (error) {
      hilog.warn(DOMAIN, 'YoloNano', 'detectFromGray failed: %{public}s', JSON.stringify(error));
      return [];
    }
  }

  release(): void {
    this.model = undefined;
  }

  private makeLetterbox(srcW: number, srcH: number): Letterbox {
    const box: Letterbox = new Letterbox();
    box.scale = Math.min(INPUT_WIDTH / srcW, INPUT_HEIGHT / srcH);
    box.padX = Math.floor((INPUT_WIDTH - Math.round(srcW * box.scale)) / 2);
    box.padY = Math.floor((INPUT_HEIGHT - Math.round(srcH * box.scale)) / 2);
    return box;
  }

  private preprocess(pixels: Uint8Array, srcW: number, srcH: number, rowStride: number,
    letterbox: Letterbox): Float32Array {
    const data: Float32Array = new Float32Array(INPUT_WIDTH * INPUT_HEIGHT);
    for (let y: number = 0; y < INPUT_HEIGHT; y++) {
      const srcY: number = Math.floor((y - letterbox.padY) / letterbox.scale);
      for (let x: number = 0; x < INPUT_WIDTH; x++) {
        const srcX: number = Math.floor((x - letterbox.padX) / letterbox.scale);
        let gray: number = PAD_VALUE;
        if (srcX >= 0 && srcY >= 0 && srcX < srcW && srcY < srcH) {
          const srcIndex: number = srcY * rowStride + srcX;
          if (srcIndex < pixels.length) {
            gray = pixels[srcIndex] / 255;
          }
        }
        data[y * INPUT_WIDTH + x] = gray;
      }
    }
    return data;
  }

  private tensorToFloat32(tensor: mindSporeLite.MSTensor): Float32Array {
    const buffer: ArrayBuffer = tensor.getData();
    if (tensor.dtype !== mindSporeLite.DataType.NUMBER_TYPE_FLOAT16) {
      return new Float32Array(buffer);
    }
    const raw: Uint16Array = new Uint16Array(buffer);
    const converted: Float32Array = new Float32Array(raw.length);
    for (let i: number = 0; i < raw.length; i++) {
      converted[i] = this.float16To32(raw[i]);
    }
    return converted;
  }

  private float16To32(h: number): number {
    const sign: number = (h & 0x8000) !== 0 ? -1 : 1;
    const exp: number = (h & 0x7C00) >> 10;
    const frac: number = h & 0x03FF;
    if (exp === 0) {
      return sign * Math.pow(2, -14) * (frac / 1024);
    }
    if (exp === 31) {
      return frac === 0 ? sign * Infinity : Number.NaN;
    }
    return sign * Math.pow(2, exp - 15) * (1 + frac / 1024);
  }

  private parse(data: Float32Array, shape: number[], frameWidth: number, frameHeight: number,
    letterbox: Letterbox): PersonBox[] {
    let numBoxes: number = 0;
    let params: number = 0;
    let channelFirst: boolean = true;
    if (shape.length >= 2) {
      const last: number = shape[shape.length - 1];
      const prev: number = shape[shape.length - 2];
      if (prev === 5 || prev === 6) {
        params = prev;
        numBoxes = last;
        channelFirst = true;
      } else if (last === 5 || last === 6) {
        params = last;
        numBoxes = prev;
        channelFirst = false;
      }
    }
    if ((params !== 5 && params !== 6) || numBoxes <= 0) {
      this.lastHint = `YOLO gray 输出 ${shape.join('x')}`;
      return [];
    }
    const xyxy: boolean = params === 6;
    const candidates: PersonBox[] = [];
    let rawMax: number = 0;
    let scorePass: number = 0;
    let rejectArea: number = 0;
    for (let i: number = 0; i < numBoxes; i++) {
      const mapped: PersonBox | undefined = this.boxFromRow(data, channelFirst, numBoxes, params, xyxy, i,
        frameWidth, frameHeight, letterbox);
      const score: number = this.normalizeScore(this.at(data, channelFirst, numBoxes, params, i, 4));
      if (score > rawMax) {
        rawMax = score;
      }
      if (score >= CONF_PARTIAL) {
        scorePass += 1;
        if (!mapped) {
          rejectArea += 1;
        }
      }
      if (mapped) {
        candidates.push(mapped);
      }
    }
    const kept: PersonBox[] = this.nms(candidates);
    this.lastHint = `YOLO26 ${kept.length} 人 raw=${rawMax.toFixed(3)} pass=${scorePass} area=${rejectArea}`;
    return kept;
  }

  private boxFromRow(data: Float32Array, channelFirst: boolean, numBoxes: number, params: number,
    xyxy: boolean, index: number, frameWidth: number, frameHeight: number,
    letterbox: Letterbox): PersonBox | undefined {
    const score: number = this.normalizeScore(this.at(data, channelFirst, numBoxes, params, index, 4));
    if (score < CONF_PARTIAL || score > 1) {
      return undefined;
    }
    if (xyxy) {
      const x1: number = this.at(data, channelFirst, numBoxes, params, index, 0);
      const y1: number = this.at(data, channelFirst, numBoxes, params, index, 1);
      const x2: number = this.at(data, channelFirst, numBoxes, params, index, 2);
      const y2: number = this.at(data, channelFirst, numBoxes, params, index, 3);
      return this.mapBox(x1, y1, x2, y2, score, frameWidth, frameHeight, letterbox);
    }
    const cx: number = this.at(data, channelFirst, numBoxes, params, index, 0);
    const cy: number = this.at(data, channelFirst, numBoxes, params, index, 1);
    const w: number = this.at(data, channelFirst, numBoxes, params, index, 2);
    const h: number = this.at(data, channelFirst, numBoxes, params, index, 3);
    return this.mapBox(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, score, frameWidth, frameHeight, letterbox);
  }

  private normalizeScore(score: number): number {
    if (score >= 0 && score <= 1) {
      return score;
    }
    if (score > 1 && score < 16) {
      return 1 / (1 + Math.exp(-score));
    }
    return 0;
  }

  private at(data: Float32Array, channelFirst: boolean, numBoxes: number, params: number, box: number,
    key: number): number {
    if (channelFirst) {
      return data[key * numBoxes + box];
    }
    return data[box * params + key];
  }

  private mapBox(x1: number, y1: number, x2: number, y2: number, score: number, frameWidth: number,
    frameHeight: number, letterbox: Letterbox): PersonBox | undefined {
    let left: number = x1;
    let top: number = y1;
    let right: number = x2;
    let bottom: number = y2;
    const maxAbs: number = Math.max(Math.abs(x1), Math.abs(y1), Math.abs(x2), Math.abs(y2));
    if (maxAbs <= 2) {
      left = x1 * INPUT_WIDTH;
      top = y1 * INPUT_HEIGHT;
      right = x2 * INPUT_WIDTH;
      bottom = y2 * INPUT_HEIGHT;
    }
    left = (left - letterbox.padX) / letterbox.scale;
    top = (top - letterbox.padY) / letterbox.scale;
    right = (right - letterbox.padX) / letterbox.scale;
    bottom = (bottom - letterbox.padY) / letterbox.scale;
    if (right < left) {
      const swapX: number = left;
      left = right;
      right = swapX;
    }
    if (bottom < top) {
      const swapY: number = top;
      top = bottom;
      bottom = swapY;
    }
    left = Math.max(0, Math.min(frameWidth, left));
    top = Math.max(0, Math.min(frameHeight, top));
    right = Math.max(0, Math.min(frameWidth, right));
    bottom = Math.max(0, Math.min(frameHeight, bottom));
    const width: number = right - left;
    const height: number = bottom - top;
    if (width < 2 || height < 2) {
      return undefined;
    }
    const areaRatio: number = (width * height) / (frameWidth * frameHeight);
    if (areaRatio < MIN_BOX_AREA_RATIO || areaRatio > MAX_BOX_AREA_RATIO) {
      return undefined;
    }
    const box: PersonBox = new PersonBox();
    box.left = left;
    box.top = top;
    box.width = width;
    box.height = height;
    box.score = score;
    box.partial = this.isPartial(box, frameWidth, frameHeight) ||
      this.isLowerBodyLike(box, frameWidth, frameHeight);
    return box;
  }

  private isLowerBodyLike(box: PersonBox, frameWidth: number, frameHeight: number): boolean {
    const heightRatio: number = box.height / frameHeight;
    const widthRatio: number = box.width / frameWidth;
    if (heightRatio > 0.5 || widthRatio > 0.55) {
      return false;
    }
    const bottom: number = box.top + box.height;
    const centerY: number = box.top + box.height / 2;
    return bottom >= frameHeight * 0.68 || centerY >= frameHeight * 0.52;
  }

  private isPartial(box: PersonBox, frameWidth: number, frameHeight: number): boolean {
    const margin: number = Math.max(8, Math.floor(Math.min(frameWidth, frameHeight) * 0.02));
    return box.left <= margin || box.top <= margin ||
      (box.left + box.width) >= (frameWidth - margin) ||
      (box.top + box.height) >= (frameHeight - margin);
  }

  private nms(boxes: PersonBox[]): PersonBox[] {
    const ordered: PersonBox[] = boxes.slice();
    ordered.sort((a: PersonBox, b: PersonBox) => {
      return b.score - a.score;
    });
    const kept: PersonBox[] = [];
    for (let i: number = 0; i < ordered.length; i++) {
      let overlap: boolean = false;
      for (let j: number = 0; j < kept.length; j++) {
        if (this.iou(ordered[i], kept[j]) > IOU_THRESHOLD) {
          overlap = true;
          break;
        }
      }
      if (!overlap) {
        kept.push(ordered[i]);
      }
    }
    return kept;
  }

  private iou(a: PersonBox, b: PersonBox): number {
    const x1: number = Math.max(a.left, b.left);
    const y1: number = Math.max(a.top, b.top);
    const x2: number = Math.min(a.left + a.width, b.left + b.width);
    const y2: number = Math.min(a.top + a.height, b.top + b.height);
    const inter: number = Math.max(0, x2 - x1) * Math.max(0, y2 - y1);
    if (inter <= 0) {
      return 0;
    }
    const union: number = a.width * a.height + b.width * b.height - inter;
    return union <= 0 ? 0 : inter / union;
  }
}
