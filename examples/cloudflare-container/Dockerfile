# linux/amd64. Copy ReleaseSafe binaries built on Ubuntu (or a matching
# cross target) into bin/ next to this file before `docker build` /
# `wrangler deploy`. The default `boris` theme is resolved against the
# process cwd (`/`), so a content-only source archive can build with the
# bundled default layout; copy it next to this file too (scripts/
# test-job-runner-image-parity.sh does both).
# Match GitHub Actions ubuntu-latest (24.04) so a ReleaseSafe host binary
# does not trip a glibc-too-old base.
FROM ubuntu:24.04

RUN groupadd --gid 65532 boris \
    && useradd --uid 65532 --gid 65532 --home-dir /nonexistent --shell /usr/sbin/nologin boris \
    && mkdir -p /tmp/boris-jobs \
    && chown 65532:65532 /tmp/boris-jobs

COPY bin/boris /usr/local/bin/boris
COPY bin/boris-job-runner /usr/local/bin/boris-job-runner
COPY themes/boris /themes/boris

USER 65532:65532
ENV BORIS_BIN=/usr/local/bin/boris
ENV BORIS_WORK_ROOT=/tmp/boris-jobs
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/boris-job-runner"]
CMD ["--listen", "0.0.0.0:8080", "--allow-unauthenticated"]
