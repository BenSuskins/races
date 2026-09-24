# The Races server. Pure Go — the SQLite driver is modernc.org/sqlite, not
# cgo — so the binary is static and the runtime image is distroless.
FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/races-server ./cmd/races-server

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/races-server /races-server
# The database lives here; mount a host directory owned by the container user.
VOLUME /data
ENV RACES_DB_PATH=/data/races.db LISTEN_ADDR=:8080
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/races-server"]
