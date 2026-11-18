// JNI bridge between Kotlin (WhisperLib.kt) and whisper.cpp
#include <jni.h>
#include <atomic>
#include <string>
#include <vector>
#include "whisper.h"

#ifdef __ANDROID__
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "WhisperJNI", __VA_ARGS__)
#else
#include <cstdio>
#define LOGI(...) (fprintf(stderr, __VA_ARGS__), fprintf(stderr, "\n"))
#endif

static std::atomic<bool> g_abort(false);

static bool abort_cb(void * /*user_data*/) {
    return g_abort.load();
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_pasuyobuddy_transcribe_whisper_WhisperLib_initContext(JNIEnv *env, jobject, jstring modelPath) {
    const char *path = env->GetStringUTFChars(modelPath, nullptr);
    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;
    whisper_context *ctx = whisper_init_from_file_with_params(path, cparams);
    env->ReleaseStringUTFChars(modelPath, path);
    if (ctx == nullptr) LOGI("Failed to load model");
    return reinterpret_cast<jlong>(ctx);
}

extern "C" JNIEXPORT void JNICALL
Java_com_pasuyobuddy_transcribe_whisper_WhisperLib_freeContext(JNIEnv *, jobject, jlong ptr) {
    auto *ctx = reinterpret_cast<whisper_context *>(ptr);
    if (ctx != nullptr) whisper_free(ctx);
}

extern "C" JNIEXPORT void JNICALL
Java_com_pasuyobuddy_transcribe_whisper_WhisperLib_setAbort(JNIEnv *, jobject, jboolean value) {
    g_abort.store(value == JNI_TRUE);
}

// Returns an array of strings:
//   [0]   = "LANG|<detected language code>"
//   [1..] = "<t0 ms>|<t1 ms>|<text>"   (times relative to the start of `samples`)
// Returns null if whisper_full failed or was aborted.
extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_pasuyobuddy_transcribe_whisper_WhisperLib_transcribe(
        JNIEnv *env, jobject, jlong ptr, jfloatArray samples, jstring language,
        jint threads, jboolean keepContext) {
    auto *ctx = reinterpret_cast<whisper_context *>(ptr);
    if (ctx == nullptr) return nullptr;

    const char *lang = env->GetStringUTFChars(language, nullptr);
    std::string langStr(lang);
    env->ReleaseStringUTFChars(language, lang);

    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = false;
    params.language = langStr.c_str();   // "auto" enables language detection
    params.n_threads = threads > 0 ? threads : 4;
    params.no_context = keepContext != JNI_TRUE;
    params.suppress_blank = true;
    params.abort_callback = abort_cb;
    params.abort_callback_user_data = nullptr;

    jsize n = env->GetArrayLength(samples);
    jfloat *data = env->GetFloatArrayElements(samples, nullptr);
    int rc = whisper_full(ctx, params, data, n);
    env->ReleaseFloatArrayElements(samples, data, JNI_ABORT);

    if (rc != 0 || g_abort.load()) {
        LOGI("whisper_full returned %d (abort=%d)", rc, (int) g_abort.load());
        return nullptr;
    }

    const int nSeg = whisper_full_n_segments(ctx);
    jclass strClass = env->FindClass("java/lang/String");
    jobjectArray result = env->NewObjectArray(nSeg + 1, strClass, nullptr);

    const char *detected = whisper_lang_str(whisper_full_lang_id(ctx));
    std::string head = std::string("LANG|") + (detected ? detected : "");
    jstring jHead = env->NewStringUTF(head.c_str());
    env->SetObjectArrayElement(result, 0, jHead);
    env->DeleteLocalRef(jHead);

    for (int i = 0; i < nSeg; ++i) {
        // whisper timestamps are in 10 ms units
        long long t0 = (long long) whisper_full_get_segment_t0(ctx, i) * 10;
        long long t1 = (long long) whisper_full_get_segment_t1(ctx, i) * 10;
        const char *text = whisper_full_get_segment_text(ctx, i);
        std::string line = std::to_string(t0) + "|" + std::to_string(t1) + "|" + (text ? text : "");

        // NewStringUTF needs valid (modified) UTF-8; build from bytes to be safe with any byte sequence
        jbyteArray bytes = env->NewByteArray((jsize) line.size());
        env->SetByteArrayRegion(bytes, 0, (jsize) line.size(), reinterpret_cast<const jbyte *>(line.data()));
        jclass sc = env->FindClass("java/lang/String");
        jmethodID ctor = env->GetMethodID(sc, "<init>", "([BLjava/lang/String;)V");
        jstring charset = env->NewStringUTF("UTF-8");
        auto jLine = (jstring) env->NewObject(sc, ctor, bytes, charset);
        env->SetObjectArrayElement(result, i + 1, jLine);
        env->DeleteLocalRef(jLine);
        env->DeleteLocalRef(charset);
        env->DeleteLocalRef(bytes);
        env->DeleteLocalRef(sc);
    }
    return result;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_pasuyobuddy_transcribe_whisper_WhisperLib_systemInfo(JNIEnv *env, jobject) {
    return env->NewStringUTF(whisper_print_system_info());
}
