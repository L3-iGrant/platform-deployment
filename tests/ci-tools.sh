# nats-server 2.14.10 (the version of nats.image: nats-server -t of the
archive="$(fetch https://github.com/nats-io/nats-server/releases/download/v2.14.10/nats-server-v2.14.10-linux-amd64.tar.gz 464f118a8aecf293e405514c1ab2c197a5d9209e58e36a5d05ad9577e5ee9b99)"
tar -xzf "$archive" -C "$work" nats-server-v2.14.10-linux-amd64/nats-server
install -m 0755 "$work/nats-server-v2.14.10-linux-amd64/nats-server" "$tools/bin/nats-server"
