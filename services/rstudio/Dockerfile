FROM rocker/rstudio:4.6.0

ARG RSTUDIO_VERSION=2026.07.1
ARG RSTUDIO_BUILD=147
ARG RENV_VERSION=1.1.5

# Encode distro, architecture and R minor version in the URL so binary
# selection does not depend on the R User-Agent configured by the base image.
ENV RSPM=https://packagemanager.posit.co/cran/latest/bin/linux/noble-x86_64/4.6
# The repository URL already selects the exact Linux binary platform. Prevent
# renv from appending a second __linux__/noble/<R-version> segment.
ENV RENV_CONFIG_PPM_ENABLED=false

RUN printf '%s\n' \
        'local({' \
        '  options(repos = c(CRAN = Sys.getenv("RSPM")))' \
        '})' \
        >> /usr/local/lib/R/etc/Rprofile.site

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openssh-client \
        ca-certificates \
        curl \
        git \
        build-essential \
        pkg-config \
        libcurl4-openssl-dev \
        libssl-dev \
        libxml2-dev \
        libicu-dev \
        libfontconfig1-dev \
        libfreetype6-dev \
        libharfbuzz-dev \
        libfribidi-dev \
        zlib1g-dev \
        libbz2-dev \
        liblzma-dev \
    && curl -fsSL \
        "https://download2.rstudio.org/server/jammy/amd64/rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_BUILD}-amd64.deb" \
        -o /tmp/rstudio-server.deb \
    && apt-get install -y --no-install-recommends /tmp/rstudio-server.deb \
    && rstudio-server version | grep -F "${RSTUDIO_VERSION}+${RSTUDIO_BUILD}" \
    && curl -fsSL "https://cloud.r-project.org/src/contrib/Archive/renv/renv_${RENV_VERSION}.tar.gz" -o /tmp/renv.tar.gz \
    && R CMD INSTALL /tmp/renv.tar.gz \
    && Rscript -e 'stopifnot(as.character(packageVersion("renv")) == Sys.getenv("RENV_VERSION", unset = "1.1.5"))' \
    && rm -f /tmp/rstudio-server.deb \
    && rm -f /tmp/renv.tar.gz \
    && rm -rf /var/lib/apt/lists/*
