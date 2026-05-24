#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <stdarg.h>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <linux/vm_sockets.h>

#include "../proto/wire.h"

#define RELAY_PORT   9999u
#define ARM_CID      4u
#define RISCV_CID    3u

/* Millisecond-resolution timestamp + "[relay]" prefix, matching the format the
 * demo views use so all three log streams correlate by wall-clock time. */
static void rlog(const char *fmt, ...) {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    struct tm tm;
    localtime_r(&now.tv_sec, &tm);
    char when[32];
    strftime(when, sizeof when, "%m-%d %H:%M:%S", &tm);
    printf("%s.%03ld [relay] ", when, now.tv_nsec / 1000000);
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
    fflush(stdout);
}

static int connect_to_arm(void) {
    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket(ARM)"); return -1; }
    struct sockaddr_vm addr = {
        .svm_family = AF_VSOCK,
        .svm_cid    = ARM_CID,
        .svm_port   = RELAY_PORT,
    };
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect(ARM)");
        close(fd);
        return -1;
    }
    return fd;
}

/* Forward one complete request from riscv_fd to arm, read reply, send back.
 * Returns 0 on success, -1 on any error. */
static int relay_one(int riscv_fd) {
    /* --- Read request from RISC-V --- */
    wire_req_hdr_t hdr;
    if (read_exact(riscv_fd, &hdr, sizeof(hdr)) < 0) {
        /* Normal end-of-session: the RISC-V client closed the connection. */
        return -1;
    }
    if (hdr.magic != WIRE_MAGIC) {
        fprintf(stderr, "[relay] bad magic 0x%08x\n", hdr.magic);
        return -1;
    }

    char *lib = NULL, *sym = NULL, *sig = NULL;
    uint16_t lib_len, sym_len, sig_len;
    if (read_lenstr16(riscv_fd, &lib, &lib_len) < 0) goto err;
    if (read_lenstr16(riscv_fd, &sym, &sym_len) < 0) goto err;
    if (read_lenstr16(riscv_fd, &sig, &sig_len) < 0) goto err;

    uint32_t arg_len;
    if (read_exact(riscv_fd, &arg_len, 4) < 0) goto err;
    uint8_t *args = NULL;
    if (arg_len > 0) {
        if (arg_len > 1024 * 1024) { fprintf(stderr, "[relay] arg_len too large\n"); goto err; }
        args = (uint8_t *)malloc(arg_len);
        if (!args) goto err;
        if (read_exact(riscv_fd, args, arg_len) < 0) goto err;
    }

    rlog("FWD  INVOKE req_id=%u lib=%s sym=%s sig=%s arg_len=%u",
         hdr.req_id, lib, sym, sig, arg_len);

    /* --- Open fresh connection to ARM and forward verbatim --- */
    int arm_fd = connect_to_arm();
    if (arm_fd < 0) goto err;

    /* Re-emit the header */
    if (write_exact(arm_fd, &hdr, sizeof(hdr)) < 0) { close(arm_fd); goto err; }
    if (write_lenstr16(arm_fd, lib) < 0) { close(arm_fd); goto err; }
    if (write_lenstr16(arm_fd, sym) < 0) { close(arm_fd); goto err; }
    if (write_lenstr16(arm_fd, sig) < 0) { close(arm_fd); goto err; }
    if (write_exact(arm_fd, &arg_len, 4) < 0) { close(arm_fd); goto err; }
    if (arg_len > 0 && write_exact(arm_fd, args, arg_len) < 0) { close(arm_fd); goto err; }

    /* --- Read reply from ARM --- */
    wire_reply_hdr_t rhdr;
    if (read_exact(arm_fd, &rhdr, sizeof(rhdr)) < 0) {
        fprintf(stderr, "[relay] failed reading reply from ARM\n");
        close(arm_fd);
        goto err;
    }
    uint8_t *ret_payload = NULL;
    if (rhdr.ret_len > 0) {
        if (rhdr.ret_len > 4 * 1024 * 1024) { close(arm_fd); goto err; }
        ret_payload = (uint8_t *)malloc(rhdr.ret_len);
        if (!ret_payload) { close(arm_fd); goto err; }
        if (read_exact(arm_fd, ret_payload, rhdr.ret_len) < 0) {
            free(ret_payload); close(arm_fd); goto err;
        }
    }
    close(arm_fd);

    rlog("FWD  REPLY  req_id=%u status=%u retdesc='%c' ret_len=%u ",
         rhdr.req_id, rhdr.status, (char)rhdr.retdesc, rhdr.ret_len);

    /* --- Forward reply to RISC-V --- */
    if (write_exact(riscv_fd, &rhdr, sizeof(rhdr)) < 0) {
        free(ret_payload); goto err;
    }
    if (rhdr.ret_len > 0) {
        if (write_exact(riscv_fd, ret_payload, rhdr.ret_len) < 0) {
            free(ret_payload); goto err;
        }
    }

    free(ret_payload);
    free(args); free(lib); free(sym); free(sig);
    return 0;

err:
    free(args); free(lib); free(sym); free(sig);
    return -1;
}

int main(void) {
    int listen_fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        if (errno == EAFNOSUPPORT) {
            fprintf(stderr, "[relay] FATAL: AF_VSOCK not supported on this host kernel. "
                    "Cannot relay vsock traffic.\n");
            return 1;
        }
        perror("socket(listen)");
        return 1;
    }

    struct sockaddr_vm addr = {
        .svm_family = AF_VSOCK,
        .svm_cid    = VMADDR_CID_ANY,
        .svm_port   = RELAY_PORT,
    };
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); return 1;
    }
    if (listen(listen_fd, 4) < 0) {
        perror("listen"); return 1;
    }
    printf("[relay] listening on AF_VSOCK port %u  (forwarding CID%u→CID%u)\n",
           RELAY_PORT, RISCV_CID, ARM_CID);
    fflush(stdout);

    for (;;) {
        struct sockaddr_vm peer;
        socklen_t plen = sizeof(peer);
        int client_fd = accept(listen_fd, (struct sockaddr *)&peer, &plen);
        if (client_fd < 0) { perror("accept"); continue; }
        rlog("──── new session ───────────────────────────────────────────────");
        rlog("accepted vsock connection from RISC-V VM (CID %u); dialing ARM VM (CID %u) ...",
             peer.svm_cid, ARM_CID);

        /* Service requests on this connection until the client closes. */
        while (relay_one(client_fd) == 0)
            ;

        rlog("RISC-V VM (CID %u) closed connection;", peer.svm_cid);
        close(client_fd);
    }
}
