# Namida Party Relay

Relay for [Namida](https://github.com/namidaco/namida) listening parties. It only knows rooms, members, who the host is,
bans and limits, it never parses party data. All queue/playback/chat logic lives in the app.

- [PROTOCOL.md](PROTOCOL.md) the contract both implementations follow.
- [worker](worker) Cloudflare Worker + Durable Objects, what runs on `party.namida.app`. Deploy your own for free.
- [dart](dart) pure Dart package, used in-app for LAN parties and as a standalone self-host binary/docker image. Holds the
  black-box conformance suite that both implementations must pass.

# Credits

Created by claude