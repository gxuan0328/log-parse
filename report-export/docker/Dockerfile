# syntax=docker/dockerfile:1
#
# report-export runtime image (docs/design.md §4.7).
#
# Two stages:
#   builder  -- resolves the hash-pinned runtime dependency set
#               (requirements.lock, design.md §4.7.1) into a venv using
#               network access to PyPI. Nothing from this stage ships
#               except the resulting /opt/venv.
#   runtime  -- a FRESH copy of the same base image + digest; contains
#               only the venv, the application source, and the bundled
#               HOSP_ID reference table. No compiler toolchain, no pip
#               cache, no dev/test dependencies (design.md §4.7.1/§4.7.4).
#
# Build (context MUST be report-export/, not docker/):
#   docker build -t report-export:1.0.0 -f docker/Dockerfile .
#
# The base image is pinned by digest, not by a mutable tag (design.md
# §4.7.1/§4.7.4), so a rebuild months from now still resolves the exact
# same bytes. Re-resolve the pin (e.g. after a deliberate base-image
# refresh) with:
#   docker pull python:3.12-slim
#   docker inspect --format '{{index .RepoDigests 0}}' python:3.12-slim
# then update PYTHON_DIGEST below.

ARG PYTHON_DIGEST=sha256:c3d81d25b3154142b0b42eb1e61300024426268edeb5b5a26dd7ddf64d9daf28

# ==============================================================================
# Stage: builder
# ==============================================================================
FROM python:3.12-slim@${PYTHON_DIGEST} AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

# openpyxl is pure Python (design.md §2.2) -- the builder never needs a
# compiler toolchain, only pip + PyPI network access.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# Copied alone, before the rest of the source tree, so this layer only
# invalidates when the pinned dependency set actually changes.
COPY requirements.lock .

# --require-hashes: EVERY package in requirements.lock -- openpyxl AND
# its transitive et_xmlfile dependency (design.md §4.7.1, C2-8) -- must
# be `==` pinned with a sha256 hash, or the install aborts. Supply-chain
# integrity, not just version pinning.
RUN pip install --no-cache-dir --require-hashes -r requirements.lock

# ==============================================================================
# Stage: runtime
# ==============================================================================
FROM python:3.12-slim@${PYTHON_DIGEST} AS runtime

# ARGs used after a stage's own FROM must be re-declared inside that
# stage (a global ARG declared above is visible only to FROM lines).
ARG PYTHON_DIGEST
ARG APP_UID=10001
ARG APP_GID=10001
# design.md §3.3: identifies which HOSP_ID master-table snapshot
# this image bundles. Bump alongside every `reference/` refresh
# (recompute with:
#   python3 -c "import json; \
#     print(json.load(open('reference/hosp_id_map.manifest.json'))['sha256'])"
# ) and pass the new value via `--build-arg HOSP_DATA_VERSION=...`.
ARG HOSP_DATA_VERSION=e95c66acb48dfffb0f5108337a5ec491a520654393d1e8a1d90ad62a556200e3
ARG IMAGE_VERSION=1.0.0

LABEL org.opencontainers.image.title="report-export" \
      org.opencontainers.image.description="Independent weekly Excel connection-log report automation for LUNG-CANCER-REPORT (design.md)." \
      org.opencontainers.image.source="https://github.com/gxuan0328/log-parse" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.base.name="python:3.12-slim" \
      org.opencontainers.image.base.digest="${PYTHON_DIGEST}" \
      hosp-data-version="${HOSP_DATA_VERSION}"

# Non-root by default (design.md §4.7.4). `docker run --user
# "$(id -u):$(id -g)"` overrides this at run time for host bind-mount
# writability (design.md §4.7.3 HIGH finding: a fixed image UID cannot
# write a freshly-created, caller-owned host directory -- EACCES on a
# real host even though it "worked" on a bind-mount that happened to be
# world-writable in a dev environment).
RUN groupadd --gid "${APP_GID}" appuser \
    && useradd --uid "${APP_UID}" --gid "${APP_GID}" \
       --no-create-home --no-log-init --shell /usr/sbin/nologin appuser

# PYTHONHASHSEED=0: deterministic hash-dependent iteration order
# (design.md §2.4 ethos: "確定性可重放"). LANG/LC_ALL=C.UTF-8: correct
# handling of the Chinese deliverable filenames/sheet names (design.md
# §3.7.2/§6-16) without depending on locale packages being installed.
# TZ=Asia/Taipei: the business-day boundary for `run_date` (design.md
# §3.8 S0, §6-17); the base image ships tzdata, no extra package needed.
# HOME=/tmp: `--user` may select a uid with no /etc/passwd entry, so no
# component may rely on home-directory lookup (design.md §4.7.3) --
# paired with `docker run --tmpfs /tmp` at the call site.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONHASHSEED=0 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Taipei \
    HOME=/tmp \
    PATH="/opt/venv/bin:${PATH}" \
    PYTHONPATH=/app/src

WORKDIR /app

# The venv from the builder stage; both stages share the identical
# base-image digest, so the venv's absolute-path symlinks back to the
# system interpreter (/usr/local/bin/python3.12) resolve correctly here.
COPY --from=builder /opt/venv /opt/venv

# Application source runs straight off PYTHONPATH -- no `pip install`
# of report_export itself (design.md §4.7.6), so no build step, no
# editable-install machinery, and no dependency on setuptools/pip being
# present in the final image beyond what the venv already carries.
COPY src/ /app/src/

# Bundled HOSP_ID -> HOSP_ABBR lookup table (design.md §3.3): the only
# reference data the runtime image ships; the 2.3MB source workbook and
# the one-off export tool that produced this file never enter the image
# (design.md §3.3, §4.7.2).
COPY reference/hosp_id_map.csv.gz reference/hosp_id_map.manifest.json /app/reference/

USER ${APP_UID}:${APP_GID}

# No HEALTHCHECK: this is a one-shot batch process, not a long-running
# service (design.md §1.1, §1.3 "非常駐、非服務、非資料庫") -- there is no
# "is it healthy" question to ask between the start and the exit code.
ENTRYPOINT ["python", "-m", "report_export"]
CMD []
