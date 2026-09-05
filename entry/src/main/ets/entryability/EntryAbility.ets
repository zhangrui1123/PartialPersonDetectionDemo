import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN: number = 0x0D01;

export default class EntryAbility extends UIAbility {
  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'EntryAbility', 'onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'EntryAbility', 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'EntryAbility', 'onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'EntryAbility', 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      windowStage.getMainWindow().then((win: window.Window) => {
        try {
          win.setWindowDecorVisible(true);
          win.resize(1280, 800);
        } catch (error) {
          hilog.warn(DOMAIN, 'EntryAbility', 'resize skipped: %{public}s', JSON.stringify(error));
        }
      }).catch((error: Error) => {
        hilog.warn(DOMAIN, 'EntryAbility', 'getMainWindow failed: %{public}s', JSON.stringify(error));
      });
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'EntryAbility', 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'EntryAbility', 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'EntryAbility', 'onBackground');
  }
}
