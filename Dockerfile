FROM alpine:3 AS build
RUN apk add --no-cache cmake gcc make musl-dev
COPY rebound.c CMakeLists.txt /src/
WORKDIR /src/build
RUN cmake -DBUILD_STATIC=ON -DCMAKE_BUILD_TYPE=Release .. && \
    cmake --build .

FROM scratch
COPY --from=build /src/build/rebound /rebound
ENTRYPOINT ["/rebound"]
