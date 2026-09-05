# PartialPersonDetectionDemo

HarmonyOS 部分人体检测演示：后置相机取灰度帧，YOLOv8n-P2（640×480，1 通道）识别完整或贴边人体，上报有人 / 无人。

## 功能

- 拍照会话双路预览：隐藏的 XComponent 维持相机流，左侧显示分析用灰度图
- Native `OH_ImageReceiver` 读取 NV21 的 Y 平面
- MindSpore Lite 加载 `entry/src/main/resources/rawfile/yolo_gray_640_480.ms`
- 检测框贴边或偏下半身时标记为部分人体，同样计为有人

## 打开工程

用 DevEco Studio 打开本目录，连接手机或 2in1 后编译运行。

```powershell
hvigorw assembleHap
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`

- 包名：`com.example.partialpersondetection`
- 设备：`phone`、`2in1`
- 权限：相机

## 目录

```
PartialPersonDetectionDemo/
├── AppScope/
├── entry/
│   ├── src/main/cpp/          # Native ImageReceiver
│   ├── src/main/ets/
│   │   ├── pages/Index.ets    # 灰度预览与有人/无人
│   │   └── model/             # 相机、YOLO、滞回
│   └── src/main/resources/rawfile/yolo_gray_640_480.ms
├── build-profile.json5
└── oh-package.json5
```
