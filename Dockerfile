# ========== GO BUILD STAGE ==========
# 使用 Debian 版 Go 镜像（glibc），解决 Go CGO 与 musl 不兼容问题
FROM golang:1.25-bookworm AS go-builder

# Docker Buildx 自动注入目标架构信息
ARG TARGETARCH
ARG TARGETVARIANT

WORKDIR /build/bridge

# Install build dependencies (gcc required for CGO)
RUN apt-get update && \
    apt-get install -y --no-install-recommends git build-essential && \
    rm -rf /var/lib/apt/lists/*

# Copy Go source code FIRST (needed for dependency analysis)
COPY bridge/converter.go ./

# Initialize new go.mod dynamically
RUN go mod init github.com/aethersailor/subconverter-extended/bridge

# Get latest Mihomo and resolve all dependencies
RUN go get github.com/metacubex/mihomo@Meta

# Upgrade all dependencies to latest versions (security fix)
RUN go get -u all

# Tidy dependencies (auto-resolves transitive deps)
RUN go mod tidy

# Copy scripts for scheme generation
COPY scripts/ ../scripts/
RUN go run ../scripts/generate_schemes.go mihomo_schemes.h
RUN go run ../scripts/generate_param_compat.go -o param_compat.h

# Build static library (enable CGO for glibc)
# 注意：不使用 -ldflags="-s -w"，因为移除符号表会导致 CGO 程序 Segfault
RUN echo "==> Building for $TARGETARCH" && \
    CGO_ENABLED=1 go build \
    -buildmode=c-archive \
    -o libmihomo.a \
    .

# Verify build output
RUN ls -lh libmihomo.a libmihomo.h

# ========== C++ BUILD STAGE ==========
# 使用 Debian 编译（glibc），确保二进制链接 glibc
FROM debian:bookworm-slim AS builder
ARG THREADS="4"
ARG SHA=""
ARG VERSION="dev"

WORKDIR /

# Install build dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    git g++ build-essential cmake python3 python3-pip \
    pkg-config curl \
    libcurl4-openssl-dev libpcre2-dev rapidjson-dev \
    libyaml-cpp-dev ca-certificates ninja-build ccache && \
    rm -rf /var/lib/apt/lists/*

# quickjspp
RUN set -xe && \
    git clone --depth=1 https://github.com/ftk/quickjspp.git && \
    cd quickjspp && \
    git submodule update --init && \
    cmake -DCMAKE_BUILD_TYPE=Release . && \
    make quickjs -j ${THREADS} && \
    install -d /usr/lib/quickjs/ && \
    install -m644 quickjs/libquickjs.a /usr/lib/quickjs/ && \
    install -d /usr/include/quickjs/ && \
    install -m644 quickjs/quickjs.h quickjs/quickjs-libc.h /usr/include/quickjs/ && \
    install -m644 quickjspp.hpp /usr/include

# libcron
RUN set -xe && \
    git clone https://github.com/PerMalmberg/libcron --depth=1 && \
    cd libcron && \
    git submodule update --init && \
    cmake -DCMAKE_BUILD_TYPE=Release . && \
    make libcron -j ${THREADS} && \
    install -m644 libcron/out/Release/liblibcron.a /usr/lib/ && \
    install -d /usr/include/libcron/ && \
    install -m644 libcron/include/libcron/* /usr/include/libcron/ && \
    install -d /usr/include/date/ && \
    install -m644 libcron/externals/date/include/date/* /usr/include/date/

# toml11
RUN set -xe && \
    git clone https://github.com/ToruNiina/toml11 --branch="v4.3.0" --depth=1 && \
    cd toml11 && \
    cmake -DCMAKE_CXX_STANDARD=11 . && \
    make install -j ${THREADS}

# Copy Go library and module files from go-builder stage
COPY --from=go-builder /build/bridge/libmihomo.a /usr/lib/
COPY --from=go-builder /build/bridge/libmihomo.h /usr/include/
COPY --from=go-builder /build/bridge/go.mod /src/bridge/go.mod
COPY --from=go-builder /build/bridge/go.sum /src/bridge/go.sum

# build subconverter from THIS repository source (provided by build context)
WORKDIR /src
COPY . /src
COPY --from=go-builder /build/bridge/mihomo_schemes.h /src/src/parser/mihomo_schemes.h
COPY --from=go-builder /build/bridge/param_compat.h /src/src/parser/param_compat.h

# Download latest header-only libraries (override old versions in repo)
RUN set -xe && \
    echo "Downloading latest cpp-httplib..." && \
    curl -fsSL https://raw.githubusercontent.com/yhirose/cpp-httplib/master/httplib.h -o include/httplib.h && \
    echo "Downloading latest nlohmann/json..." && \
    curl -fsSL https://github.com/nlohmann/json/releases/latest/download/json.hpp -o include/nlohmann/json.hpp && \
    echo "Downloading latest inja..." && \
    curl -fsSL https://raw.githubusercontent.com/pantor/inja/master/single_include/inja/inja.hpp -o include/inja.hpp && \
    echo "Downloading latest jpcre2..." && \
    curl -fsSL https://raw.githubusercontent.com/jpcre2/jpcre2/master/src/jpcre2.hpp -o include/jpcre2.hpp && \
    echo "Copying latest quickjspp from compiled source..." && \
    cp /usr/include/quickjspp.hpp include/quickjspp.hpp && \
    echo "All header libraries updated to latest versions"

RUN set -xe && \
    [ -n "${SHA}" ] && sed -i "s/#define BUILD_ID \"\"/#define BUILD_ID \"${SHA}\"/ " src/version.h || true && \
    [ -n "${VERSION}" ] && sed -i "s/#define VERSION \"dev\"/#define VERSION \"${VERSION}\"/" src/version.h || true && \
    # Copy Go library to bridge directory for CMake detection
    mkdir -p bridge && \
    cp /usr/lib/libmihomo.a bridge/ && \
    cp /usr/include/libmihomo.h bridge/ && \
    # Configure ccache
    export PATH="/usr/lib/ccache:$PATH" && \
    export CCACHE_DIR=/tmp/ccache && \
    export CCACHE_COMPILERCHECK=content && \
    # Use Ninja generator and enable ccache
    cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER_LAUNCHER=ccache . && \
    # Parallel build
    ninja -j ${THREADS}

# ========== FINAL STAGE ==========
# 使用 Alpine 作为最终镜像（体积小），安装 glibc 兼容层支持 glibc 编译的二进制
FROM alpine:latest

# 安装运行时依赖 + glibc 兼容层
# glibc 兼容层解决 Debian 编译的二进制在 Alpine 上运行的问题
RUN apk add --no-cache \
    libstdc++ pcre2 libcurl yaml-cpp ca-certificates wget && \
    wget -q -O /etc/apk/keys/sgerrand.rsa.pub https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub && \
    wget https://github.com/sgerrand/alpine-pkg-glibc/releases/download/2.35-r1/glibc-2.35-r1.apk && \
    apk add --no-cache --force-overwrite glibc-2.35-r1.apk && \
    rm glibc-2.35-r1.apk && \
    apk del wget

COPY --from=builder /src/subconverter /usr/bin/subconverter
COPY --from=builder /src/base /base/

# 确保二进制可执行
RUN chmod +x /usr/bin/subconverter

ENV TZ=Africa/Abidjan
RUN ln -sf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

WORKDIR /base
CMD ["/usr/bin/subconverter"]
EXPOSE 25500/tcp
