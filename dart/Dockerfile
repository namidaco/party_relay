FROM dart:stable AS build

WORKDIR /app
COPY pubspec.yaml ./
RUN dart pub get
COPY . .
RUN dart pub get --offline
RUN dart compile exe bin/relay.dart -o /app/relay

# -- runtime image carries only the dart runtime deps and the exe
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/relay /bin/relay

ENV PORT=8787
ENV HOST=0.0.0.0
EXPOSE 8787

ENTRYPOINT ["/bin/relay"]
