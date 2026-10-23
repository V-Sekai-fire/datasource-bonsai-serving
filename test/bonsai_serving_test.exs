defmodule BonsaiServingTest do
  use ExUnit.Case, async: true

  alias BonsaiServing.{Capacity, Devices, Log, Witness}

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

  describe "witness hash" do
    test "matches a known sha256 vector" do
      assert Witness.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    end

    test "a different answer hashes differently" do
      refute Witness.sha256("abc") == Witness.sha256("abd")
    end
  end
end
