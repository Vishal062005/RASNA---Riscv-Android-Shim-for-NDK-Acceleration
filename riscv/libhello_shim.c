#define _GNU_SOURCE
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/socket.h>
#include <android/log.h>
#include <linux/vm_sockets.h>

#include "../proto/wire.h"

#define TAG         "JNI_SHIM"
#define RELAY_CID   2u    /* host relay CID as seen from guest */
#define RELAY_PORT  9999u

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static int      g_sock   = -1;
static uint32_t g_req_id = 0;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

static int ensure_connected(void) {
    if (g_sock >= 0) return 0;

    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) {
        if (errno == EAFNOSUPPORT) {
            LOGE("FATAL: AF_VSOCK EAFNOSUPPORT in RISC-V guest. "
                 "Cannot relay JNI call. Kernel config needs VSOCK support.");
        } else {
            LOGE("socket: %s", strerror(errno));
        }
        return -1;
    }

    struct sockaddr_vm addr = {
        .svm_family = AF_VSOCK,
        .svm_cid    = RELAY_CID,
        .svm_port   = RELAY_PORT,
    };
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        LOGE("connect(CID=%u port=%u): %s", RELAY_CID, RELAY_PORT, strerror(errno));
        close(fd);
        return -1;
    }
    g_sock = fd;
    return 0;
}

/* Runs at library unload / process exit; emits the teardown line that mirrors
 * the relay's "RISC-V VM closed connection" and the dispatcher's "closed". */
__attribute__((destructor))
static void shim_teardown(void) {
    if (g_sock >= 0) {
        LOGI("closing connection to HOST relay (CID %u)", RELAY_CID);
        close(g_sock);
        g_sock = -1;
    }
}

JNIEXPORT void JNICALL Java_HelloJNI_sayHello(JNIEnv *env, jobject thiz) {
    (void)thiz;

    pthread_mutex_lock(&g_mu);

    if (ensure_connected() < 0) {
        pthread_mutex_unlock(&g_mu);
        if (env) {
            jclass exc = (*env)->FindClass(env, "java/lang/RuntimeException");
            (*env)->ThrowNew(env, exc, "JNI_SHIM: vsock connect failed");
        }
        return;
    }

    uint32_t req_id = ++g_req_id;

    /* Build and send request frame. */
    const char *lib = "libhello_arm.so";
    const char *sym = "Java_HelloJNI_sayHello";
    const char *sig = "()V";
    uint32_t arg_len = 0;

    wire_req_hdr_t hdr = {
        .magic   = WIRE_MAGIC,
        .req_id  = req_id,
        .op      = WIRE_OP_INVOKE,
        .flags   = 0,
    };

    LOGI("SEND INVOKE req_id=%u sym=%s sig=%s arg_len=%u", req_id, sym, sig, arg_len);

    if (write_exact(g_sock, &hdr, sizeof(hdr)) < 0 ||
        write_lenstr16(g_sock, lib) < 0 ||
        write_lenstr16(g_sock, sym) < 0 ||
        write_lenstr16(g_sock, sig) < 0 ||
        write_exact(g_sock, &arg_len, 4) < 0) {
        LOGE("write request failed: %s", strerror(errno));
        close(g_sock); g_sock = -1;
        pthread_mutex_unlock(&g_mu);
        if (env) {
            jclass exc = (*env)->FindClass(env, "java/lang/RuntimeException");
            (*env)->ThrowNew(env, exc, "JNI_SHIM: write request failed");
        }
        return;
    }

    /* Read reply. */
    wire_reply_hdr_t reply;
    if (read_exact(g_sock, &reply, sizeof(reply)) < 0) {
        LOGE("read reply header failed: %s", strerror(errno));
        close(g_sock); g_sock = -1;
        pthread_mutex_unlock(&g_mu);
        if (env) {
            jclass exc = (*env)->FindClass(env, "java/lang/RuntimeException");
            (*env)->ThrowNew(env, exc, "JNI_SHIM: read reply failed");
        }
        return;
    }

    uint8_t *ret_payload = NULL;
    if (reply.ret_len > 0) {
        if (reply.ret_len > 4 * 1024 * 1024) {
            LOGE("ret_len %u too large", reply.ret_len);
            close(g_sock); g_sock = -1;
            pthread_mutex_unlock(&g_mu);
            return;
        }
        ret_payload = (uint8_t *)malloc(reply.ret_len + 1);
        if (!ret_payload || read_exact(g_sock, ret_payload, reply.ret_len) < 0) {
            free(ret_payload);
            close(g_sock); g_sock = -1;
            pthread_mutex_unlock(&g_mu);
            return;
        }
        ret_payload[reply.ret_len] = '\0';
    }

    pthread_mutex_unlock(&g_mu);

    if (reply.status != 0) {
        LOGE("remote invocation failed (status=%u): %s",
             reply.status, ret_payload ? (char *)ret_payload : "(no message)");
        free(ret_payload);
        if (env) {
            jclass exc = (*env)->FindClass(env, "java/lang/RuntimeException");
            char msg[512];
            snprintf(msg, sizeof(msg), "JNI_SHIM: remote error: %s",
                     ret_payload ? (char *)ret_payload : "unknown");
            (*env)->ThrowNew(env, exc, msg);
        }
        return;
    }

    /* Trim trailing newline(s) so the captured payload prints on one line. */
    if (ret_payload) {
        uint32_t pl = reply.ret_len;
        while (pl > 0 && (ret_payload[pl - 1] == '\n' || ret_payload[pl - 1] == '\r'))
            ret_payload[--pl] = '\0';
    }
    LOGI("RECV REPLY  req_id=%u status=%u retdesc='%c' ret_len=%u payload: \"%s\"   "
         "[from ARM VM(CID4) via HOST relay]",
         reply.req_id, reply.status, (char)reply.retdesc, reply.ret_len,
         ret_payload ? (char *)ret_payload : "");

    free(ret_payload);
    /* void return — done */
}
