FROM alpine:3 AS build
RUN apk add --no-cache gcc musl-dev make
COPY rebound.c Makefile /src/
WORKDIR /src
RUN make static

FROM scratch
COPY --from=build /src/rebound /rebound
ENTRYPOINT ["/rebound"]
