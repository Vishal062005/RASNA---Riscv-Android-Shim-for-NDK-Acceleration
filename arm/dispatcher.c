#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <android/log.h>
#include <linux/vm_sockets.h>

#include "../proto/wire.h"

#define TAG        "JNI_DISPATCHER"
#define LISTEN_PORT 9999u

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/* -------------------------------------------------------------------------
 * v1 constraint: only supports native functions that do NOT dereference
 * JNIEnv* or jobject.  HelloJNI's sayHello() only calls printf(), so NULL
 * pointers are safe.  Any function that touches env-> or thiz will crash
 * and needs a phase-2 JNI bridge implementation.
 * --------------------------------------------------------------------- */

/* Simple linked-list dlopen cache keyed by lib name. */
typedef struct lib_entry {
    char             *name;
    void             *handle;
    struct lib_entry *next;
} lib_entry_t;

static lib_entry_t *g_libs = NULL;

static void *get_lib(const char *name) {
    for (lib_entry_t *e = g_libs; e; e = e->next)
        if (strcmp(e->name, name) == 0) return e->handle;

    void *h = dlopen(name, RTLD_NOW | RTLD_LOCAL);
    if (!h) { LOGE("dlopen(%s) failed: %s", name, dlerror()); return NULL; }
    LOGI("dlopen(%s) ok", name);

    lib_entry_t *e = (lib_entry_t *)malloc(sizeof(*e));
    e->name   = strdup(name);
    e->handle = h;
    e->next   = g_libs;
    g_libs    = e;
    return h;
}

/*
 * Invoke the symbol, capture its stdout via a pipe.
 * Returns malloc'd captured output (NUL-terminated) in *out_buf,
 * length in *out_len.  Returns 0 on success, -1 on error.
 */
static int invoke_and_capture(const char *lib, const char *sym,
                               uint8_t **out_buf, uint32_t *out_len,
                               char *errbuf, size_t errbufsz) {
    void *h = get_lib(lib);
    if (!h) {
        snprintf(errbuf, errbufsz, "dlopen(%s): %s", lib, dlerror());
        return -1;
    }

    void (*fn)(void *, void *) = (void (*)(void *, void *))dlsym(h, sym);
    if (!fn) {
        snprintf(errbuf, errbufsz, "dlsym(%s): %s", sym, dlerror());
        return -1;
    }
    LOGI("dlsym(%s) ok, invoking with NULL JNIEnv/jobject", sym);

    /* Redirect stdout to a pipe so we capture what the function prints. */
    int pipefd[2];
    if (pipe(pipefd) < 0) {
        snprintf(errbuf, errbufsz, "pipe: %s", strerror(errno));
        return -1;
    }

    int saved_stdout = dup(STDOUT_FILENO);
    dup2(pipefd[1], STDOUT_FILENO);
    close(pipefd[1]);

    /* v1: NULL JNIEnv*, NULL jobject */
    fn(NULL, NULL);
    fflush(stdout);

    dup2(saved_stdout, STDOUT_FILENO);
    close(saved_stdout);

    /* Drain the pipe. */
    size_t cap = 4096, used = 0;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) { close(pipefd[0]); return -1; }
    ssize_t n;
    while ((n = read(pipefd[0], buf + used, cap - used)) > 0) {
        used += (size_t)n;
        if (used == cap) {
            cap *= 2;
            uint8_t *nb = (uint8_t *)realloc(buf, cap);
            if (!nb) { free(buf); close(pipefd[0]); return -1; }
            buf = nb;
        }
    }
    close(pipefd[0]);

    LOGI("captured %zu bytes of stdout: %.*s", used, (int)used, (char *)buf);

    *out_buf = buf;
    *out_len = (uint32_t)used;
    return 0;
}

static void handle_client(int client_fd) {
    for (;;) {
        wire_req_hdr_t hdr;
        int r = read_exact(client_fd, &hdr, sizeof(hdr));
        if (r < 0) break; /* client closed */

        if (hdr.magic != WIRE_MAGIC) {
            LOGE("bad magic 0x%08x, closing", hdr.magic);
            break;
        }

        char *lib = NULL, *sym = NULL, *sig = NULL;
        if (read_lenstr16(client_fd, &lib, NULL) < 0) break;
        if (read_lenstr16(client_fd, &sym, NULL) < 0) { free(lib); break; }
        if (read_lenstr16(client_fd, &sig, NULL) < 0) { free(lib); free(sym); break; }

        uint32_t arg_len;
        if (read_exact(client_fd, &arg_len, 4) < 0) { free(lib); free(sym); free(sig); break; }
        if (arg_len > 0) {
            /* skip args (HelloJNI sends none; we don't forward JNI handles) */
            uint8_t *tmp = (uint8_t *)malloc(arg_len);
            if (!tmp || read_exact(client_fd, tmp, arg_len) < 0) {
                free(tmp); free(lib); free(sym); free(sig); break;
            }
            free(tmp);
        }

        LOGI("INVOKE req_id=%u lib=%s sym=%s sig=%s", hdr.req_id, lib, sym, sig);

        wire_reply_hdr_t reply = { .req_id = hdr.req_id };
        uint8_t *out_buf = NULL;
        uint32_t out_len = 0;
        char errbuf[256] = {0};

        if (invoke_and_capture(lib, sym, &out_buf, &out_len, errbuf, sizeof(errbuf)) == 0) {
            reply.status  = 0;
            reply.retdesc = 's'; /* string blob = captured stdout */
            reply.ret_len = out_len;
        } else {
            LOGE("invoke failed: %s", errbuf);
            reply.status  = 1;
            reply.retdesc = 's';
            out_buf = (uint8_t *)strdup(errbuf);
            reply.ret_len = out_buf ? (uint32_t)strlen(errbuf) : 0;
        }

        write_exact(client_fd, &reply, sizeof(reply));
        if (reply.ret_len > 0) write_exact(client_fd, out_buf, reply.ret_len);
        free(out_buf);
        free(lib); free(sym); free(sig);
    }
}

int main(void) {
    int listen_fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        if (errno == EAFNOSUPPORT) {
            LOGE("FATAL: AF_VSOCK not supported in this guest kernel.");
            fprintf(stderr, "FATAL: AF_VSOCK EAFNOSUPPORT\n");
            return 1;
        }
        LOGE("socket: %s", strerror(errno));
        return 1;
    }

    struct sockaddr_vm addr = {
        .svm_family = AF_VSOCK,
        .svm_cid    = VMADDR_CID_ANY,
        .svm_port   = LISTEN_PORT,
    };
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        LOGE("bind: %s", strerror(errno)); return 1;
    }
    if (listen(listen_fd, 4) < 0) {
        LOGE("listen: %s", strerror(errno)); return 1;
    }
    LOGI("ARM64 dispatcher listening on vsock port %u", LISTEN_PORT);
    printf("[dispatcher] listening on vsock port %u\n", LISTEN_PORT);
    fflush(stdout);

    for (;;) {
        struct sockaddr_vm peer;
        socklen_t plen = sizeof(peer);
        int client_fd = accept(listen_fd, (struct sockaddr *)&peer, &plen);
        if (client_fd < 0) { LOGE("accept: %s", strerror(errno)); continue; }
        LOGI("accepted connection from CID %u", peer.svm_cid);
        handle_client(client_fd);
        LOGI("connection from CID %u closed", peer.svm_cid);
        close(client_fd);
    }
}
