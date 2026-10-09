/* Temporary static socket probe, adapted from edge-net-devices tests.
 * Test tooling only: never installed as a wtctl runtime dependency. */
#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static void fail(const char *message) { perror(message); exit(1); }
static void transfer(int fd, unsigned char *data, size_t length, int sending) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = sending ? send(fd, data + offset, length - offset, 0)
                                : recv(fd, data + offset, length - offset, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) fail(sending ? "send" : "recv/EOF");
        offset += (size_t)count;
    }
}
int main(int argc, char **argv) {
    int no_data = argc == 5 && !strcmp(argv[4], "--expect-no-data");
    if ((argc != 4 && !no_data) || (strcmp(argv[1], "tcp") && strcmp(argv[1], "udp"))) return 2;
    int udp = !strcmp(argv[1], "udp");
    if (no_data && udp) return 2;
    long port = strtol(argv[3], NULL, 10);
    if (port < 1 || port > 65535) return 2;
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = htons(port) };
    if (inet_pton(AF_INET, argv[2], &address.sin_addr) != 1) return 2;
    int fd = socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, 0);
    if (fd < 0) fail("socket");
    struct timeval timeout = { .tv_sec = no_data ? 10 : 20 };
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout))) fail("timeout");
    if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout))) fail("timeout");
    if (connect(fd, (struct sockaddr *)&address, sizeof(address))) fail("connect");
    if (no_data) {
        unsigned char value = 0xa5;
        if (send(fd, &value, 1, 0) != 1) fail("send");
        ssize_t count = recv(fd, &value, 1, 0);
        if (count > 0) { fprintf(stderr, "unexpected forwarded payload\n"); return 1; }
        if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != ECONNRESET && errno != ETIMEDOUT) fail("recv");
        printf("{\"connected\":true,\"bytes_received\":0}\n");
        close(fd);
        return 0;
    }
    unsigned char sent[65536], received[65536];
    size_t length = udp ? 1028 : sizeof(sent);
    int rounds = udp ? 16 : 64;
    for (size_t i = 0; i < length; i++) sent[i] = (unsigned char)i;
    struct timespec start, end;
    if (clock_gettime(CLOCK_MONOTONIC, &start)) fail("clock");
    for (int round = 0; round < rounds; round++) {
        if (udp) {
            sent[0] = (unsigned char)round;
            if (send(fd, sent, length, 0) != (ssize_t)length) fail("udp send");
            if (recv(fd, received, sizeof(received), 0) != (ssize_t)length) fail("udp recv");
        } else {
            transfer(fd, sent, length, 1);
            transfer(fd, received, length, 0);
        }
        if (memcmp(sent, received, length)) { fprintf(stderr, "payload mismatch\n"); return 1; }
    }
    if (clock_gettime(CLOCK_MONOTONIC, &end)) fail("clock");
    double elapsed = end.tv_sec - start.tv_sec + (end.tv_nsec - start.tv_nsec) / 1e9;
    printf("{\"protocol\":\"%s\",\"bytes_echoed\":%zu,\"rounds\":%d,\"elapsed_seconds\":%.6f,\"echo_MiB_per_second\":%.6f}\n",
           argv[1], length * rounds, rounds, elapsed, length * rounds / elapsed / 1048576.0);
    close(fd);
    return 0;
}
