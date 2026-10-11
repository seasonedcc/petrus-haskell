# hamsterdan-host

The Hamsterdan host: GitHub webhook custody into durable V5 PR-readiness
Instances, authority fencing, the publication, rerun, review, and mutation
gates, durable timers, the runnable index, the HTTP surface, and the
operator CLI (`serve`, `validate`, `inbox`, `requeue`, `inspect-instance`).

Every file the host writes under its state directory is the reference's,
byte for byte, so the Haskell and Python hosts can resume each other's
state. See [PARITY.md](PARITY.md) and [DIVERGENCES.md](DIVERGENCES.md).
