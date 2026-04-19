defmodule PrizeflightWeb.ChangesetJSON do
  @moduledoc """
  JSON view for Ecto changeset errors. Produces
  `%{errors: %{field => [messages]}}` with interpolated option values.
  """

  def error(%{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
