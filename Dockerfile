# ========================================================
# Stage 1: Frontend (Vite)
# ========================================================
FROM --platform=$BUILDPLATFORM node:22-alpine AS frontend
WORKDIR /src/frontend
# Используем *, чтобы не упасть, если package-lock.json вообще отсутствует в релизе
COPY frontend/package*.json ./
# Заменяем строгий 'npm ci' на отказоустойчивый 'npm install'
RUN npm install
COPY frontend/ ./
COPY internal/web/translation /src/internal/web/translation
RUN npm run build

# ========================================================
# Stage 2: Builder (Панель + Утилиты AWG)
# ========================================================
FROM golang:1.26-alpine AS builder
WORKDIR /app
ARG TARGETARCH

# Добавили git, make, linux-headers и bash для сборки AWG
RUN apk --no-cache --update add \
  build-base \
  gcc \
  curl \
  unzip \
  git \
  make \
  linux-headers \
  bash

# Собираем панель
COPY . .
COPY --from=frontend /src/internal/web/dist ./internal/web/dist

ENV CGO_ENABLED=1
ENV CGO_CFLAGS="-D_LARGEFILE64_SOURCE"
RUN go build -ldflags "-w -s" -o build/x-ui main.go
RUN ./DockerInit.sh "$TARGETARCH"

# Собираем утилиты AWG
RUN git clone https://github.com/amnezia-vpn/amneziawg-tools.git /tmp/awg-tools && \
    cd /tmp/awg-tools/src && \
    make && \
    make install WITH_WGQUICK=yes PREFIX=/usr DESTDIR=/app/build-awg

RUN git clone https://github.com/amnezia-vpn/amneziawg-go.git /tmp/awg-go && \
    cd /tmp/awg-go && \
    go build -v -o /app/build-awg/usr/bin/amneziawg-go

# ========================================================
# Stage 3: Final Image of 3x-ui / Lucx-UI
# ========================================================
FROM alpine
ENV TZ=Asia/Tehran
WORKDIR /app

# Добавили сетевые пакеты для WG и AWG
RUN apk add --no-cache --update \
  ca-certificates \
  tzdata \
  fail2ban \
  bash \
  curl \
  openssl \
  iptables \
  iproute2 \
  wireguard-tools \
  wireguard-tools-wg-quick \
  openresolv

COPY --from=builder /app/build/ /app/
COPY --from=builder /app/DockerEntrypoint.sh /app/
COPY --from=builder /app/x-ui.sh /usr/bin/x-ui
COPY --from=builder /app/internal/web/translation /app/internal/web/translation

# Копируем бинарники AWG
COPY --from=builder /app/build-awg/usr/bin/awg /usr/bin/awg
COPY --from=builder /app/build-awg/usr/bin/awg-quick /usr/bin/awg-quick
COPY --from=builder /app/build-awg/usr/bin/amneziawg-go /usr/bin/amneziawg-go

# Выдаем права
RUN chmod +x /usr/bin/awg /usr/bin/awg-quick #/usr/bin/amneziawg-go

# Configure fail2ban
RUN rm -f /etc/fail2ban/jail.d/alpine-ssh.conf \
  && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local \
  && sed -i "s/^\[ssh\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/^\[sshd\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/#allowipv6 = auto/allowipv6 = auto/g" /etc/fail2ban/fail2ban.conf

RUN chmod +x \
  /app/DockerEntrypoint.sh \
  /app/x-ui \
  /usr/bin/x-ui

ENV XUI_IN_DOCKER="true"
ENV XUI_MAIN_FOLDER="/app"
ENV XUI_ENABLE_FAIL2BAN="true"
ENV XUI_DB_TYPE=""
ENV XUI_DB_DSN=""
EXPOSE 2053
VOLUME [ "/etc/x-ui" ]
CMD [ "./x-ui" ]
ENTRYPOINT [ "/app/DockerEntrypoint.sh" ]