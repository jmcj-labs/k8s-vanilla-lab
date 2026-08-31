# Static binary on scratch: no shell, no package manager, no libc — a few MB
# and almost no surface. This runs hostNetwork on every worker, so its attack
# surface is the node's.
# Go 1.26: the 1.24 series carries 19 HIGH stdlib CVEs that the image scan
# fails on, all of them fixed in 1.25.13 / 1.26.6. The builder version IS the
# security surface here -- a scratch image has nothing else in it.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
# CGO off + trimpath + stripped symbols: reproducible, small, static.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /node-readiness .

FROM scratch
COPY --from=build /node-readiness /node-readiness
USER 65534:65534
EXPOSE 9890
ENTRYPOINT ["/node-readiness"]
