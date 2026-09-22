defmodule R5eRecurse.NonceJournalReceiptTest do
  use ExUnit.Case, async: true

  test "HTTP receipt parsing is bounded and cannot confer an admission outcome" do
    {output, status} =
      System.cmd("python3", ["test/support/journal_receipt_probe.py"], stderr_to_stdout: true)

    assert status == 0, output
  end
end
