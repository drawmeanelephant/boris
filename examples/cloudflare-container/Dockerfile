# linux/amd64. Copy ReleaseSafe binaries built on Ubuntu (or a matching
# cross target) into bin/ next to this file before `docker build` /
# `wrangler deploy`.
FROM debian:bookworm-slim

RUN groupadd --gid 65532 boris \
    && useradd --uid 65532 --gid 65532 --home-dir /nonexistent --shell /usr/sbin/nologin boris \
    && mkdir -p /tmp/boris-jobs \
    && chown 65532:65532 /tmp/boris-jobs

COPY bin/boris /usr/local/bin/boris
COPY bin/boris-job-runner /usr/local/bin/boris-job-runner

USER 65532:65532
ENV BORIS_BIN=/usr/local/bin/boris
ENV BORIS_WORK_ROOT=/tmp/boris-jobs
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/boris-job-runner"]
CMD ["--listen", "0.0.0.0:8080", "--allow-unauthenticated"]
