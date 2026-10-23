# datasource-bonsai-serving

An OTP application that binds this box's Bonsai 2 serving stack: one NInfer process over the RTX 4090
and the RTX 3090 as a layer pipeline, its systemd unit, and the two questions worth asking about it —
what text does it produce, and how much context can it hold. It replaces the ad-hoc CLI harnesses.

It sits on the hexagon's **datasource** side. RFD 2028 (`V-Sekai-fire/manuals-weftspun`, the Netflix
formulation of the pattern) puts the implementations against the real world in `datasources/` and
names "a GPU compute host" among them; this repository is that implementation for Bonsai 2. It is
checked out at `6-datasource/bonsai-serving` by `V-Sekai-fire/contract-manifest-taskweft`.

Standard Elixir + OTP only. No dependencies beyond OTP's own `:inets`, `:ssl`, `:crypto` and `:json`.

## Commands

```
mix bonsai status                     # unit state, the split and capacity lines, per-card memory
mix bonsai devices                    # the pinned UUIDs, checked against the cards present
mix bonsai witness [--expected SHA]   # one temperature-0 answer, hashed and compared
mix bonsai capacity [--kv-dtype rk8v4] [--max-context 1048576]
mix bonsai start | stop
mix test                              # log matching, the pins, the capacity line, the hash, the shell
```

`capacity` needs the cards to itself: it stops the unit, runs one probe process with
`--kv-capacity auto`, reads the capacity line it resolves, and starts the unit again **whatever the
probe does** — a failed restore outranks a good probe, because the box must be left serving.

## Design notes

- **Devices are named by GPU UUID, never by index.** The order of the UUIDs in `CUDA_VISIBLE_DEVICES`
  is the CUDA ordinal order, while `nvidia-smi`'s indices and `CUDA_DEVICE_ORDER` are separate
  opinions. Pins live in `/etc/ninfer/pipeline.devices`; a UUID that is not present is an error, never
  a fallback.
- **Every wait is driven by the log line it waits for.** `BonsaiServing.Unit.await/4` opens a port on
  `timeout N journalctl -f` and matches the bytes as they arrive. No sleep, no poll. The window
  starts at a stamp taken *before* the process is started, because `journalctl -u <name>` mixes every
  instance of a unit name and a previous run's `capacity |` line would otherwise answer for this one.
- **Judged by output, not by startup.** `witness` compares the served text's sha256 with the expected
  answer; a serving process that produces different tokens is a failure.
- **No error trapping.** `try`, `rescue`, `catch` and `throw` are blocklisted in Elixir here. Expected
  failures come back as `{:ok, value}` / `{:error, reason}`; `test/blocklist_test.exs` scans `lib/` for
  the keywords and carries a planted control that must match.
- **The API key is read from the files first.** A long-lived process (the agent gateway) holds a
  snapshot of its environment from before a key rotation, so an exported `BONSAI_DESK_API_KEY` can be
  stale while `~/.hermes/.env` is current. A `/v1/models` body is never printed: ninfer-serve echoes
  its command line, `--api-key` included.
- **Scratch servers run outside the agent's memory cgroup** (`systemd-run --unit=... --collect`), or
  they get OOM-killed mid-load.

## Layout

| file | what it owns |
|---|---|
| `lib/bonsai_serving/unit.ex` | the systemd unit: status, start/stop, log following |
| `lib/bonsai_serving/arm.ex` | a scratch server as a transient systemd unit |
| `lib/bonsai_serving/devices.ex` | the UUID pins, checked against the driver |
| `lib/bonsai_serving/witness.ex` | the API key, the temp-0 request, the hash |
| `lib/bonsai_serving/capacity.ex` | the stop-probe-restore cycle |
| `lib/bonsai_serving/log.ex` | pure log-line matching |
| `lib/bonsai_serving/shell.ex` | tagged-tuple wrappers over System.cmd |
| `lib/bonsai_serving/cli.ex` | `mix bonsai <command>` |
