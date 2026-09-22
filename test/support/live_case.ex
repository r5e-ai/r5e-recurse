defmodule R5eRecurse.LiveCase do
  @moduledoc "Opt-in live tests; excluded without R5E_LIVE=1."
  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :live
      @moduletag skip: System.get_env("R5E_LIVE") != "1"
    end
  end
end
