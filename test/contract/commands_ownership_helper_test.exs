# SPDX-License-Identifier: AGPL-3.0-only
defmodule R5eRecurse.CommandsOwnershipHelperTest do
  use ExUnit.Case, async: false

  test "lock helper persistence and lifetime protocol" do
    {output, status} =
      System.cmd("python3", [Path.expand("../helpers/ownership_test.py", __DIR__)],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
