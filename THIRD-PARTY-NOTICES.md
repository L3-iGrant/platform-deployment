# Third-party notices

The chart runs these images of other projects without a change. Each project gives its software under its own licence. The images also contain the packages of their base system, each under its own licence. The list of all images of the chart, for your own mirror, is in [docs/images.md](docs/images.md).

| Software | Image (values key) | Licence | Source |
| --- | --- | --- | --- |
| PostgreSQL | `docker.io/library/postgres` (`database.postgresql.image`) | PostgreSQL Licence | https://www.postgresql.org/about/licence/ |
| NATS Server | `docker.io/library/nats` (`nats.image`) | Apache License 2.0 | https://github.com/nats-io/nats-server |
| NATS config reloader | `docker.io/natsio/nats-server-config-reloader` (`nats.reloader.image`) | Apache License 2.0 | https://github.com/nats-io/nack |
| Valkey | `docker.io/valkey/valkey` (`redis.image`) | BSD 3-Clause License; the text is in [licenses/valkey/COPYING](licenses/valkey/COPYING) (the file `COPYING` of Valkey 8.1.10) | https://github.com/valkey-io/valkey |

When you copy an image to your own registry, also keep its licence text with it: for Valkey, `licenses/valkey/COPYING`.
