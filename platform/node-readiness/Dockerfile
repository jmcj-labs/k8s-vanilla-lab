# Static binary on scratch: no shell, no package manager, no libc — a few MB
# and almost no surface. This runs hostNetwork on every worker, so its attack
# surface is the node's.
FROM golang:1.24-alpine AS build
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
