defmodule SymphonyElixir.FeedbackJournalTest do
  use ExUnit.Case
  alias SymphonyElixir.FeedbackSync.Journal

  test "a stalled lock helper times out without opening the journal" do
    {:ok, tmp} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(tmp, "feedback-journal-lock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    helper = root <> "/python3"
    File.write!(helper, "#!/bin/sh\nexec /bin/sleep 6\n")
    File.chmod!(helper, 0o700)
    previous = System.get_env("PATH")
    System.put_env("PATH", root)

    try do
      assert {:error, :feedback_journal_unavailable} = Journal.open(root <> "/journal")
      refute File.exists?(root <> "/journal/deliveries.json")
    after
      System.put_env("PATH", previous)
      File.rm_rf(root)
    end
  end
end
