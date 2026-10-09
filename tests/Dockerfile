FROM alpine:3.20
RUN apk add --no-cache build-base curl openssl python3
COPY tests/fixture.c /fixture.c
RUN cc -Wall -Wextra -Werror -Os /fixture.c -o /fixture
WORKDIR /work
ENTRYPOINT ["/bin/sh", "/work/tests/test.sh"]
