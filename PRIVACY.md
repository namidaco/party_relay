# Privacy

What a listening party sends, who can see it, and how long anything is kept. This describes the relay in this repo,
which is what runs on `party.namida.app`.

## The short version

- **No accounts.** Joining needs nothing but a room code.
- **No audio ever leaves your device.** Not local files, not streams. Every device plays its own copy.
- **The relay never reads what you send.** Queue, playback, and chat travel as opaque bytes it forwards without parsing.
- **Nothing is stored after a room ends.** No room lives longer than 24 hours.
- **No analytics, no tracking, no third parties.** The relay logs nothing about you.

## What the relay holds while a room is open

Per room: the room code, the party protocol version, when it was created, the member limit, the host's membership tier
and identity string, which member is host, the join options (approval, lock, public), a **hash** of the room password if
one is set, and the ban list.

Per connected member: the member number, the display name you chose, your device id, your IP address, and a hash of
your session token. The IP is there to rate-limit abuse and to enforce bans.

All of it is deleted when the room ends: the host closes it, nobody is connected for 10 minutes, or 24 hours pass.

**Data frames**: the queue, playback position, chat, and everything else the app sends, are forwarded between members
and never parsed, inspected, or written down. The relay cannot read them, by design, because every party decision is
made by the host device rather than the server.

## What other people in the room see

- Your display name, your role, and whether you are listening or using the device as a remote.
- The tracks you add: title, artist, album and duration for local files, or the video id for YouTube. **The file itself
  and its path never leave your device.**
- Your chat messages.

The host additionally sees your **device id** when approval is enabled, because a join request carries it. Nobody in the
room ever sees your IP address.

## What a public room shows to strangers

Rooms are **unlisted by default**. Making one public is a deliberate choice, and then `GET /v1/rooms` shows: the room
name, how many people are in it, the member limit, whether it needs a password or approval, and an anonymous id for the
room's creator. Unlisted rooms never appear, so a room code cannot be discovered by browsing.

"Share what's playing" is a **separate, off-by-default switch**. Only with it on does a public room also show the
current title and artist. The anonymous creator id is a truncated hash, it identifies nothing on its own, and it exists
so people can hide a host's rooms without anyone having an account.

A public room's entry disappears the moment it is unlisted, locked, emptied or closed, and expires on its own 15
minutes after its last refresh.

## Membership checks

Creating a room on `party.namida.app` requires a namida membership, so the relay verifies the proof your app already
holds:

- **Patreon**: your access token is passed through to Patreon's own API to read your pledge tier. The token is never
  stored and never logged.
- **Coupons**: your coupon id and email are passed to the existing namida subscription function, the same call the app
  makes on its own.

Only the result is cached, for 10 minutes, under a hash of the proof. It is used to check your tier and to count how
many rooms you have open.

## Local network parties

A LAN party runs the relay inside the app on the host's own device. Nothing reaches `party.namida.app` or any other
server, and the relay keeps its state in memory only, never on disk. It is gone when the party ends.

## Self-hosting

Anyone can run this relay. A self-hosted instance needs no membership check, can turn the public directory off entirely
with `DIRECTORY=off`, and is reachable only by people you give the address to.

## On your own device

The app stores your party preferences locally: the relay you last created a room on, your default visibility and
listening choices, and the list of hosts whose public rooms you chose to hide. Your display name comes from the same
device name the sync feature uses.
