/* Test-only ELF client: validates manager argv/lifecycle, not tunnel traffic. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

static volatile sig_atomic_t stopped;
static void stop(int sig) { (void)sig; stopped = 1; }
int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "client") && !strcmp(argv[2], "--help")) {
        puts("--local-to-remote --remote-to-local --tls-verify-certificate "
             "--http-upgrade-credentials --http-upgrade-path-prefix "
             "--nb-worker-threads --reverse-tunnel-connection-retry-max-backoff");
        return 0;
    }
    if (argc < 2 || strcmp(argv[1], "client")) return 2;
    const char *dir = getenv("WTCTL_FIXTURE_CAPTURES");
    if (dir) {
        char path[512]; snprintf(path, sizeof(path), "%s/%ld", dir, (long)getpid());
        FILE *out = fopen(path, "w");
        if (!out) return 3;
        for (int i = 1; i < argc; ++i) fprintf(out, "%s\n", argv[i]);
        fprintf(out, "CA=%s\n", getenv("SSL_CERT_FILE") ? getenv("SSL_CERT_FILE") : "");
        fclose(out);
    }
    signal(SIGTERM, stop); signal(SIGINT, stop);
    while (!stopped) {
        const char *failure = getenv("WTCTL_FIXTURE_FAILURE");
        if (failure && access(failure, F_OK) == 0) return 7;
        sleep(1);
    }
    const char *delay = getenv("WTCTL_FIXTURE_STOP_DELAY");
    if (delay) sleep((unsigned int)atoi(delay));
    return 0;
}
