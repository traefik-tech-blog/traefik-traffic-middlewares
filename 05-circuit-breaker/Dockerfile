FROM golang:1.19 as builder

WORKDIR /go/src/app
COPY main.go .

RUN GO111MODULE=off CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -a -installsuffix cgo -o app .

FROM scratch

COPY --from=builder /go/src/app/app /app

ENTRYPOINT ["/app"]
