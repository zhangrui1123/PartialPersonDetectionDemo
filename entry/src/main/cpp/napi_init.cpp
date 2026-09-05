#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <new>
#include <string>

#include <hilog/log.h>
#include <multimedia/image_framework/image/image_native.h>
#include <multimedia/image_framework/image/image_receiver_native.h>
#include <native_buffer/native_buffer.h>
#include <napi/native_api.h>

#define LOG_TAG "FrameReceiver"
#define JPEG_COMPONENT 2000

static OH_ImageReceiverNative *g_receiver = nullptr;
static napi_threadsafe_function g_tsfn = nullptr;
static std::atomic<bool> g_busy{false};
static uint32_t g_expectW = 1280;
static uint32_t g_expectH = 720;
static int g_frameLog = 0;

struct FramePacket {
    uint32_t width;
    uint32_t height;
    int32_t stride;
    double yMean;
    uint8_t *y;
    size_t ySize;
};

static void CallJs(napi_env env, napi_value jsCb, void * /*context*/, void *data)
{
    FramePacket *pkt = static_cast<FramePacket *>(data);
    if (env == nullptr || jsCb == nullptr || pkt == nullptr) {
        if (pkt != nullptr) {
            delete[] pkt->y;
            delete pkt;
        }
        g_busy.store(false);
        return;
    }
    napi_value argv[5];
    napi_create_uint32(env, pkt->width, &argv[0]);
    napi_create_uint32(env, pkt->height, &argv[1]);
    napi_create_int32(env, pkt->stride, &argv[2]);
    napi_create_double(env, pkt->yMean, &argv[3]);
    void *abData = nullptr;
    napi_create_arraybuffer(env, pkt->ySize, &abData, &argv[4]);
    if (abData != nullptr && pkt->y != nullptr) {
        memcpy(abData, pkt->y, pkt->ySize);
    }
    napi_value result = nullptr;
    napi_call_function(env, nullptr, jsCb, 5, argv, &result);
    delete[] pkt->y;
    delete pkt;
    g_busy.store(false);
}

static double SampleMean(const uint8_t *src, size_t count)
{
    if (src == nullptr || count == 0) {
        return 0.0;
    }
    uint64_t sum = 0;
    size_t used = 0;
    size_t step = count / 256;
    if (step < 1) {
        step = 1;
    }
    for (size_t i = 0; i < count; i += step) {
        sum += src[i];
        used += 1;
    }
    return static_cast<double>(sum) / static_cast<double>(used) / 255.0;
}

static void OnImageArrive(OH_ImageReceiverNative *receiver)
{
    if (g_busy.exchange(true) || g_tsfn == nullptr) {
        OH_ImageNative *drop = nullptr;
        if (OH_ImageReceiverNative_ReadLatestImage(receiver, &drop) == IMAGE_SUCCESS && drop != nullptr) {
            OH_ImageNative_Release(drop);
        }
        if (g_tsfn == nullptr) {
            g_busy.store(false);
        }
        return;
    }

    OH_ImageNative *image = nullptr;
    Image_ErrorCode err = OH_ImageReceiverNative_ReadLatestImage(receiver, &image);
    if (err != IMAGE_SUCCESS || image == nullptr) {
        g_busy.store(false);
        return;
    }

    Image_Size imgSize = {};
    OH_ImageNative_GetImageSize(image, &imgSize);
    uint32_t width = imgSize.width > 0 ? imgSize.width : g_expectW;
    uint32_t height = imgSize.height > 0 ? imgSize.height : g_expectH;

    OH_NativeBuffer *nativeBuffer = nullptr;
    err = OH_ImageNative_GetByteBuffer(image, JPEG_COMPONENT, &nativeBuffer);
    if (err != IMAGE_SUCCESS || nativeBuffer == nullptr) {
        uint32_t *types = nullptr;
        size_t typeSize = 0;
        if (OH_ImageNative_GetComponentTypes(image, &types, &typeSize) == IMAGE_SUCCESS && types != nullptr &&
            typeSize > 0) {
            err = OH_ImageNative_GetByteBuffer(image, types[0], &nativeBuffer);
        }
    }
    if (err != IMAGE_SUCCESS || nativeBuffer == nullptr) {
        OH_LOG_ERROR(LOG_APP, "GetByteBuffer failed %{public}d", err);
        OH_ImageNative_Release(image);
        g_busy.store(false);
        return;
    }

    int32_t rowStride = 0;
    OH_ImageNative_GetRowStride(image, JPEG_COMPONENT, &rowStride);
    size_t bufSize = 0;
    OH_ImageNative_GetBufferSize(image, JPEG_COMPONENT, &bufSize);

    void *virAddr = nullptr;
    OH_NativeBuffer_Config config = {};
    if (OH_NativeBuffer_MapAndGetConfig(nativeBuffer, &virAddr, &config) != 0 || virAddr == nullptr) {
        if (OH_NativeBuffer_Map(nativeBuffer, &virAddr) != 0 || virAddr == nullptr) {
            OH_LOG_ERROR(LOG_APP, "Map native buffer failed");
            OH_ImageNative_Release(image);
            g_busy.store(false);
            return;
        }
        OH_NativeBuffer_GetConfig(nativeBuffer, &config);
    }

    int32_t stride = rowStride > 0 ? rowStride : (config.stride > 0 ? config.stride : static_cast<int32_t>(width));
    if (stride < static_cast<int32_t>(width)) {
        stride = static_cast<int32_t>(width);
    }
    auto *src = static_cast<const uint8_t *>(virAddr);
    size_t yCount = static_cast<size_t>(width) * static_cast<size_t>(height);
    auto *y = new (std::nothrow) uint8_t[yCount];
    if (y == nullptr) {
        OH_NativeBuffer_Unmap(nativeBuffer);
        OH_ImageNative_Release(image);
        g_busy.store(false);
        return;
    }
    for (uint32_t row = 0; row < height; ++row) {
        memcpy(y + row * width, src + static_cast<size_t>(row) * static_cast<size_t>(stride), width);
    }
    double yMean = SampleMean(y, yCount);
    double yStd = 0.0;
    if (yCount > 0) {
        double acc = 0;
        size_t used = 0;
        size_t step = yCount / 256;
        if (step < 1) {
            step = 1;
        }
        for (size_t i = 0; i < yCount; i += step) {
            double d = static_cast<double>(y[i]) / 255.0 - yMean;
            acc += d * d;
            used += 1;
        }
        yStd = used > 0 ? sqrt(acc / static_cast<double>(used)) : 0.0;
    }
    g_frameLog += 1;
    if (g_frameLog <= 3 || g_frameLog % 15 == 0) {
        OH_LOG_INFO(LOG_APP,
            "native frame %{public}ux%{public}u stride=%{public}d buf=%{public}zu fmt=%{public}d "
            "cfg=%{public}ux%{public}u usage=%{public}u yMean=%{public}.3f yStd=%{public}.3f",
            width, height, stride, bufSize, config.format, config.width, config.height, config.usage, yMean, yStd);
    }

    OH_NativeBuffer_Unmap(nativeBuffer);
    OH_ImageNative_Release(image);

    auto *pkt = new FramePacket();
    pkt->width = width;
    pkt->height = height;
    pkt->stride = static_cast<int32_t>(width);
    pkt->yMean = yMean;
    pkt->y = y;
    pkt->ySize = yCount;
    napi_status status = napi_call_threadsafe_function(g_tsfn, pkt, napi_tsfn_nonblocking);
    if (status != napi_ok) {
        delete[] pkt->y;
        delete pkt;
        g_busy.store(false);
    }
}

static napi_value CreateReceiver(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t width = 1280;
    int32_t height = 720;
    if (argc >= 2) {
        napi_get_value_int32(env, args[0], &width);
        napi_get_value_int32(env, args[1], &height);
    }
    g_expectW = static_cast<uint32_t>(width);
    g_expectH = static_cast<uint32_t>(height);

    if (g_receiver != nullptr) {
        OH_ImageReceiverNative_Off(g_receiver);
        OH_ImageReceiverNative_Release(g_receiver);
        g_receiver = nullptr;
    }

    OH_ImageReceiverOptions *options = nullptr;
    Image_ErrorCode err = OH_ImageReceiverOptions_Create(&options);
    if (err != IMAGE_SUCCESS || options == nullptr) {
        napi_throw_error(env, nullptr, "OH_ImageReceiverOptions_Create failed");
        return nullptr;
    }
    Image_Size imgSize;
    imgSize.width = static_cast<uint32_t>(width);
    imgSize.height = static_cast<uint32_t>(height);
    OH_ImageReceiverOptions_SetSize(options, imgSize);
    OH_ImageReceiverOptions_SetCapacity(options, 8);
    err = OH_ImageReceiverNative_Create(options, &g_receiver);
    OH_ImageReceiverOptions_Release(options);
    if (err != IMAGE_SUCCESS || g_receiver == nullptr) {
        napi_throw_error(env, nullptr, "OH_ImageReceiverNative_Create failed");
        return nullptr;
    }
    err = OH_ImageReceiverNative_On(g_receiver, OnImageArrive);
    if (err != IMAGE_SUCCESS) {
        OH_ImageReceiverNative_Release(g_receiver);
        g_receiver = nullptr;
        napi_throw_error(env, nullptr, "OH_ImageReceiverNative_On failed");
        return nullptr;
    }
    uint64_t surfaceId = 0;
    err = OH_ImageReceiverNative_GetReceivingSurfaceId(g_receiver, &surfaceId);
    if (err != IMAGE_SUCCESS) {
        napi_throw_error(env, nullptr, "GetReceivingSurfaceId failed");
        return nullptr;
    }
    std::string id = std::to_string(surfaceId);
    OH_LOG_INFO(LOG_APP, "native receiver %{public}dx%{public}d surface=%{public}s", width, height, id.c_str());
    napi_value result;
    napi_create_string_utf8(env, id.c_str(), id.size(), &result);
    return result;
}

static napi_value OnFrame(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_tsfn != nullptr) {
        napi_release_threadsafe_function(g_tsfn, napi_tsfn_release);
        g_tsfn = nullptr;
    }
    napi_value name;
    napi_create_string_utf8(env, "FrameReceiver", NAPI_AUTO_LENGTH, &name);
    napi_status status = napi_create_threadsafe_function(env, args[0], nullptr, name, 1, 1, nullptr, nullptr, nullptr,
        CallJs, &g_tsfn);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "create threadsafe function failed");
        return nullptr;
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value ReleaseReceiver(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_receiver != nullptr) {
        OH_ImageReceiverNative_Off(g_receiver);
        OH_ImageReceiverNative_Release(g_receiver);
        g_receiver = nullptr;
    }
    if (g_tsfn != nullptr) {
        napi_release_threadsafe_function(g_tsfn, napi_tsfn_release);
        g_tsfn = nullptr;
    }
    g_busy.store(false);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"createReceiver", nullptr, CreateReceiver, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onFrame", nullptr, OnFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseReceiver", nullptr, ReleaseReceiver, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "framereceiver",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterFrameReceiverModule(void)
{
    napi_module_register(&g_module);
}
