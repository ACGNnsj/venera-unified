# Match the packaging runner: the image is built on 24.04, so its bundled
# libraries (and glibc floor) are 24.04-era and cannot run on 22.04.
FROM ubuntu:24.04
# Deliberately no GTK or WebKit packages. Only the display/driver host interface.
# 24.04 的 dbus 等包在 postinst 里调 invoke-rc.d，容器里没有 runlevel 时会以 4 退出；
# 用 policy-rc.d 直接拒绝启动服务，跳过这一整类脚本。
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xvfb xdotool dbus-x11 libgl1-mesa-dri libegl1 libgl1 ca-certificates fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home smoke
RUN apt-get -o Acquire::Retries=3 update && apt-get -o Acquire::Retries=3 install -y --no-install-recommends libgles2 \
    && rm -rf /var/lib/apt/lists/*
USER smoke
ENV HOME=/home/smoke
WORKDIR /home/smoke
