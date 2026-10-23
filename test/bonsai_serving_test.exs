defmodule BonsaiServingTest do
  use ExUnit.Case, async: true

  alias BonsaiServing.{Capacity, Config, Devices, Log, Sweep, Witness}

  describe "log following" do
    test "finds the needle in a complete line and keeps the partial one" do
      acc = "loading weights | 8.43 GiB\nlistening on http://127.0.0.1:8091 | model bonsai-27b\npin"
      assert {:ok, line} = Log.first_line(acc, "listening on")
      assert line =~ "listening on http://127.0.0.1:8091"
    end

    test "a partial line is not matched, and is handed back whole" do
      assert {:more, "listen"} = Log.first_line("loading\nlisten", "listening on")
      assert {:more, ""} = Log.first_line("loading\n", "listening on")
    end

    # Negative control: the capacity probe must not be satisfied by a device line, or by anything
    # else that happens to share the log.
    test "the wrong needle does not match" do
      acc = "device 0 | weights 5.02 GiB\ncapacity | KV 262,144 tokens\n"
      assert {:more, ""} = Log.first_line(acc, "listening on")
      assert {:ok, _} = Log.first_line(acc, "capacity |")
    end
  end

  describe "card pins" do
    test "parses the pins file" do
      text = "primary=GPU-84d66b8f-ff8b-1f01-61c5-2c387321332a\nsecondary=GPU-61a3f976-dd0f-dfcd-dc1f-edf3eb1a8ee1\n"
      assert {:ok, pins} = Devices.parse(text)
      assert pins.primary == "GPU-84d66b8f-ff8b-1f01-61c5-2c387321332a"
      assert pins.secondary == "GPU-61a3f976-dd0f-dfcd-dc1f-edf3eb1a8ee1"
    end

    test "a half-written pins file is an error, not a default" do
      assert {:error, {:incomplete_pins, _}} = Devices.parse("primary=GPU-aaa\n")
      assert {:error, {:incomplete_pins, _}} = Devices.parse("")
    end

    test "comments and blank lines are ignored" do
      text = "# pins\n\nprimary=GPU-a\nsecondary=GPU-b\n"
      assert {:ok, %{primary: "GPU-a", secondary: "GPU-b"}} = Devices.parse(text)
    end

    test "parses the driver's csv" do
      csv = "0, GPU-61a3f976, NVIDIA GeForce RTX 3090, 24576 MiB\n1, GPU-84d66b8f, NVIDIA GeForce RTX 4090, 24564 MiB\n"
      cards = Devices.parse_cards(csv)
      assert [%{index: 0, uuid: "GPU-61a3f976", name: "NVIDIA GeForce RTX 3090"}, %{index: 1}] = cards
    end

    test "a malformed driver line is dropped, not guessed" do
      assert Devices.parse_cards("0, GPU-a\n1, GPU-b, RTX 4090, 24564 MiB\n") |> length() == 1
    end
  end

  describe "capacity line" do
    test "parses the 1M probe line" do
      line =
        "2026-10-23 03:34:26.012  INFO  capacity | KV 1,048,576 tokens, rk8v4, auto | pages 16,384/16,384 | runtime 13.2 GiB | free 4.49 GiB"

      assert {:ok, capacity} = Capacity.parse_line(line)
      assert capacity.tokens == 1_048_576
      assert capacity.kv_dtype == "rk8v4"
      assert capacity.mode == "auto"
      assert capacity.pages_total == 16_384
      assert capacity.runtime == 13.2
      assert capacity.free == 4.49
    end

    test "parses the deployment line" do
      line = "2026-10-23 03:29:56.007  INFO  capacity | KV 262,144 tokens, rk8v4, explicit | pages 4,096/4,096 | runtime 4.83 GiB | free 13.5 GiB"
      assert {:ok, capacity} = Capacity.parse_line(line)
      assert capacity.tokens == 262_144
      assert capacity.mode == "explicit"
    end

    # Negative control: another line of the same log must not be read as a capacity line.
    test "a device line does not parse as capacity" do
      line = "2026-10-23 03:29:56.007  INFO  device 0 | weights 5.02 GiB | state 3.09 GiB | workspace 826.5 MiB"
      assert {:error, {:unparsed_capacity_line, ^line}} = Capacity.parse_line(line)
    end
  end

  describe "api key lookup" do
    test "reads the desk variable" do
      assert {:ok, "abc123"} = Witness.parse_env("BONSAI_DESK_API_KEY=abc123\n", ["BONSAI_DESK_API_KEY", "NINFER_API_KEY"])
    end

    test "falls through to the second name" do
      assert {:ok, "xyz"} = Witness.parse_env("NINFER_API_KEY=xyz\n", ["BONSAI_DESK_API_KEY", "NINFER_API_KEY"])
    end

    test "a missing key is an error" do
      assert {:error, :not_found} = Witness.parse_env("OTHER=1\n", ["BONSAI_DESK_API_KEY"])
    end
  end

  describe "shell" do
    test "a missing program is a tagged error, not a raise" do
      assert {:error, {:not_found, "definitely-not-a-program"}} =
               BonsaiServing.Shell.run(["definitely-not-a-program"])
    end

    test "an extra directory is searched when PATH does not carry the program" do
      dir = Path.join(System.tmp_dir!(), "bonsai-serving-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      planted = Path.join(dir, "planted-probe")
      File.write!(planted, "#!/bin/sh\necho planted\n")
      File.chmod!(planted, 0o755)

      assert {:ok, ^planted} = BonsaiServing.Shell.which("planted-probe", [dir])
      # Control: without the extra directory the same program is not found.
      assert {:error, {:not_found, "planted-probe"}} = BonsaiServing.Shell.which("planted-probe", [])

      File.rm_rf!(dir)
    end

    test "a non-zero exit carries its code" do
      assert {:error, {:exit, 1, ""}} = BonsaiServing.Shell.run(["false"])
    end

    test "a missing file read through sudo reports the exit, not an exception" do
      assert {:error, {:exit, _code, _output}} = BonsaiServing.Shell.sudo(["cat", "/nonexistent/pins"])
    end
  end

  describe "latency lines" do
    @short_line "2026-10-23 04:21:54.672  INFO  req#14 done | openai-chat | stop token | prompt 27 | output 181 | cache 27 (100.0%, shared prefix) | TTFT 78.7 ms | total 1.4s | queue 45.9 ms | prefill 0.0 tok/s | decode 140.3 tok/s | dflash2 accepted 109/355 (30.7%)"
    @long_line "2026-10-23 04:07:40.010  INFO  req#3 done | openai-chat | stop token | prompt 21,520 | output 20 | cache 0 (0.0%) | TTFT 10.1s | total 10.2s | queue 39.3 ms | prefill 2.16k tok/s | decode 192.6 tok/s | dflash2 accepted 15/20 (75.0%)"

    test "parses a cached short request" do
      assert {:ok, r} = BonsaiServing.Latency.parse_done(@short_line)
      assert r.req == 14
      assert r.prompt_tokens == 27
      assert r.cache_pct == 100.0
      assert r.cache_note == "shared prefix"
      assert r.ttft_ms == 78.7
      assert r.total_ms == 1400.0
      assert r.decode_tps == 140.3
      assert r.spec_accepted == 109 and r.spec_drafted == 355
    end

    test "parses an uncached long request and its thousands separators" do
      assert {:ok, r} = BonsaiServing.Latency.parse_done(@long_line)
      assert r.prompt_tokens == 21_520
      assert r.cache_pct == 0.0
      assert r.ttft_ms == 10_100.0
      # the log writes "2.16k tok/s"
      assert r.prefill_tps == 2160.0
      assert r.spec_pct == 75.0
    end

    # Negative control: the engine also logs a `started` line for the same request number, and it
    # must not be read as a finished one.
    test "a started line is not a done line" do
      started =
        "2026-10-23 04:21:53.337  INFO  req#14 started | openai-chat non-stream | 1 message | max output 200 | thinking off"

      assert {:error, {:unparsed_done_line, ^started}} = BonsaiServing.Latency.parse_done(started)
      assert BonsaiServing.Latency.parse_dones([started, @short_line]) |> length() == 1
    end

    # A request that never queued has no queue field, and this is the common case for a lone caller.
    # A parser that requires it drops every such run.
    test "a line without a queue field parses" do
      line =
        "2026-10-23 05:25:52.008  INFO  req#1 done | openai-chat | stop token | prompt 18 | output 4 | cache 0 (0.0%) | TTFT 1.1s | total 1.2s | prefill 16.2 tok/s | decode 62.6 tok/s | dflash2 accepted 0/15 (0.0%)"

      assert {:ok, r} = BonsaiServing.Latency.parse_done(line)
      assert r.queue_ms == 0.0
      assert r.ttft_ms == 1100.0
      assert r.decode_tps == 62.6
      assert r.spec_accepted == 0 and r.spec_drafted == 15
    end

    # A request with no speculative decoding has no dflash2 field at all; the group comes back as
    # an empty string and must read as zero, not crash the parse.
    test "a line without a speculative section parses with zeros" do
      line =
        "2026-10-23 04:00:00.000  INFO  req#9 done | openai-chat | length | prompt 512 | output 64 | cache 0 (0.0%) | TTFT 250.0 ms | total 900.0 ms | queue 1.0 ms | prefill 2.00k tok/s | decode 80.0 tok/s"

      assert {:ok, r} = BonsaiServing.Latency.parse_done(line)
      assert r.spec_accepted == 0 and r.spec_drafted == 0 and r.spec_pct == 0.0
      assert r.prefill_tps == 2000.0
      assert r.finish == "length"
    end

    test "spread reports min, median, max and the spread as a percentage of the median" do
      rows = [req(100.0, 100.0, 0.0), req(200.0, 110.0, 0.0), req(300.0, 120.0, 0.0)]
      s = BonsaiServing.Latency.spread(rows, :ttft_ms)
      assert s.n == 3
      assert s.min == 100.0 and s.median == 200.0 and s.max == 300.0

      # An even count takes the mean of the two middles.
      four = [req(100.0, 1.0, 0.0), req(200.0, 1.0, 0.0), req(300.0, 1.0, 0.0), req(400.0, 1.0, 0.0)]
      assert BonsaiServing.Latency.spread(four, :ttft_ms).median == 250.0

      lines = BonsaiServing.Latency.spread_table(rows)
      assert Enum.at(lines, 0) =~ "metric"
      # Row 1 is the separator, row 2 the first metric.
      assert Enum.at(lines, 2) =~ "TTFT"
      assert Enum.at(lines, 2) =~ "100%"
    end

    test "a prompt of N words is long enough to prefill" do
      assert String.length(BonsaiServing.Latency.prompt(4)) >= 24
      assert String.length(BonsaiServing.Latency.prompt(256)) >= 1536
    end
  end

  describe "argument lists" do
    test "the capacity probe overrides its three flags instead of appending them" do
      args = Capacity.probe_args("rk4v4-e8", 1_048_576, 8098)

      for flag <- ["--devices", "--max-context", "--kv-capacity", "--kv-dtype", "--port"] do
        assert Enum.count(args, &(&1 == flag)) == 1, "#{flag} appears more than once"
      end

      assert "auto" == args |> Enum.drop_while(&(&1 != "--kv-capacity")) |> Enum.at(1)
      assert "rk4v4-e8" == args |> Enum.drop_while(&(&1 != "--kv-dtype")) |> Enum.at(1)
      assert "1048576" == args |> Enum.drop_while(&(&1 != "--max-context")) |> Enum.at(1)
    end
  end

  describe "the sweep" do
    defp req(ttft_ms, decode_tps, cache_pct) do
      %{
        req: 1,
        prompt_tokens: 4096,
        output_tokens: 64,
        cache_tokens: 0,
        cache_pct: cache_pct,
        cache_note: "",
        ttft_ms: ttft_ms,
        total_ms: ttft_ms + 500,
        queue_ms: 1.0,
        prefill_tps: 2000.0,
        decode_tps: decode_tps,
        spec_accepted: 0,
        spec_drafted: 0,
        spec_pct: 0.0,
        finish: "stop token"
      }
    end

    test "replace/3 swaps a value or appends the flag" do
      args = ["--kv-dtype", "rk8v4", "--vision"]
      assert Sweep.replace(args, "--kv-dtype", "rk4v4-e8") == ["--kv-dtype", "rk4v4-e8", "--vision"]
      assert Sweep.replace(args, "--draft-tokens", "3") == ["--kv-dtype", "rk8v4", "--vision", "--draft-tokens", "3"]
    end

    test "every variant leaves one value per flag and never names the artifact" do
      base = Config.unit_args()

      for {name, transform} <- Sweep.variants() do
        args = transform.(base)
        # The arm passes the artifact to the binary itself, so a variant must not add one.
        refute Config.models() in args, "#{name} added the artifact"
        # At most once: a variant may drop a flag (no_spec drops two), but never repeat one.
        for flag <- ["--devices", "--kv-dtype", "--draft-tokens", "--spec", "--max-context"] do
          assert Enum.count(args, &(&1 == flag)) <= 1, "#{name} repeated #{flag}"
        end

        assert Enum.count(args, &(&1 == "--devices")) == 1, "#{name} dropped --devices"
      end
    end

    test "remove_spec leaves no speculative flags behind" do
      args = Sweep.remove_spec(Config.unit_args())
      refute "--spec" in args
      refute "--draft-tokens" in args
      assert "--devices" in args
    end

    test "the summary reports the cold and warm rows and a failed variant" do
      rows = [
        {:served, {:ok, %{requests: [req(10_000.0, 90.0, 0.0), req(100.0, 200.0, 82.9)]}}},
        {:draft3, {:error, :boom}}
      ]

      lines = Sweep.summary(rows)
      assert Enum.at(lines, 0) =~ "variant"
      assert Enum.at(lines, 2) =~ "served"
      assert Enum.at(lines, 2) =~ "10.0 s"
      assert Enum.at(lines, 2) =~ "100 ms"
      assert Enum.at(lines, 3) =~ "draft3"
      assert Enum.at(lines, 3) =~ "failed"
    end
  end

  describe "witness hash" do
    test "matches a known sha256 vector" do
      assert Witness.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    end

    test "a different answer hashes differently" do
      refute Witness.sha256("abc") == Witness.sha256("abd")
    end
  end
end
