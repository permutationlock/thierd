# Thierd: a simple game server for native and browser clients

The motivation behind this project is to create a game server with a small
static memory layout that can host authenticated game sessions.
It also needs to support browser clients, and thus must use TCP for networking
and implement a basic version of the WebSocket protocol.

The current state is a server that can be compiled to serialize and transmit a
compile time decided `Message` struct to and from clients. Connections can be
authenticated with [Ed25519][1] and encrypted with [ChaCha20-Poly130][2].
The server listens on a single TCP socket and can accept WebSocket connections
or raw TCP connections. The design only requires 8 bytes of additional memory
per connection to support WebSocket connections.

In progress is an account system alongside lobbies and matchmaking.

[1]: https://en.wikipedia.org/wiki/EdDSA#Ed25519
[2]: https://en.wikipedia.org/wiki/ChaCha20-Poly1305
