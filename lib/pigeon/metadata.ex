defmodule Pigeon.Metadata do
  @moduledoc """
  Internal push notification metadata.
  """

  @type t :: %__MODULE__{
          on_response: Pigeon.on_response() | nil,
          impl: atom() | nil,
          current_try: pos_integer()
        }

  defstruct on_response: nil, impl: nil, current_try: 0
end
