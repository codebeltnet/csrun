ARG BASE_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0.404-noble@sha256:fe0fd4e93bd2fbb47c883b7a6369e5c8d3db8bf01cdc5981f6ee35fbdf3ff4fb
FROM ${BASE_IMAGE}

# Empty for a single-SDK build. BuildAndPublish resolves exact, hashed official
# SDK archives for additional versions; the base SDK and PowerShell are reused.
ARG SDK_ARTIFACTS_JSON=[]
ARG TARGETARCH
COPY container-build.ps1 /opt/csrun-build.ps1
RUN pwsh -NoLogo -NoProfile -NonInteractive -File /opt/csrun-build.ps1 \
    && rm /opt/csrun-build.ps1

COPY csrun.ps1 container-entrypoint.ps1 /opt/csrun/
ARG ENGINE_VERSION
ARG ENGINE_SHA256
ARG ENGINE_URL=https://github.com/codebeltnet/csrun/releases/latest/download/csrun.ps1
RUN test -n "$ENGINE_VERSION" && test -n "$ENGINE_SHA256" \
    && echo "$ENGINE_SHA256  /opt/csrun/csrun.ps1" | sha256sum --check --strict
LABEL net.codebelt.csrun.engine.release=${ENGINE_VERSION} \
      net.codebelt.csrun.engine.sha256=${ENGINE_SHA256} \
      net.codebelt.csrun.engine.url=${ENGINE_URL}
ENV HOME=/tmp \
    DOTNET_CLI_HOME=/tmp \
    NUGET_PACKAGES=/tmp/.nuget/packages \
    XDG_CACHE_HOME=/tmp/.cache \
    XDG_CONFIG_HOME=/tmp/.config \
    XDG_DATA_HOME=/tmp/.local/share \
    TMPDIR=/tmp \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=true \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    TESTINGPLATFORM_TELEMETRY_OPTOUT=1
WORKDIR /tmp
USER $APP_UID
ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", "/opt/csrun/container-entrypoint.ps1"]
