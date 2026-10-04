# Casting signals

Incoming signals arrive as a string-keyed map:

    {:ok, signals, conn} = Datastar.Plug.Signals.read_signals(conn)
    #=> %{"text" => "Buy milk", "fontSize" => "medium", "done" => true}

Turning that into typed application data is the edge every Datastar
application has, and this library deliberately does not do it. A
type-and-constraint schema is not Datastar, it is a generic params
caster, and owning one means owning nested objects, custom types and
error-message formatting forever. The ecosystem already has these:
`Ecto.Changeset`, `Peri`, `Drops`, `Goal`, `Parameter`, `Norm`, `Vex`,
`ExJsonSchema` and `OpenApiSpex.cast`.

What *is* Datastar-specific is small, and worth knowing before you pick
one.

## Three things about signals specifically

**An unchecked checkbox is absent, not `false`.** The client sends the
signal only when it is set, so a cast that treats a missing key as an
error will reject every unchecked box. Default it to `false`.

**Keys are strings, and they nest.** Signals mirror the client-side
signal store, so a namespaced signal arrives as a nested object, not a
flattened `"user.name"` key.

**A rejection travels in a signal, not a status code.** On a status of
400 or above the client dispatches a `datastar-fetch` error event
carrying the status, so a non-2xx response is an unreliable carrier for
signal patches. Answer `200` and put the rejection in a signal. See
`Datastar.Plug.start/2`.

## A schemaless Ecto changeset

`Ecto.Changeset` works without a schema and without a database; plain
`ecto` has no database dependency. This handles string keys, defaults
and typed errors in one expression:

    @types %{text: :string, font_size: :string, done: :boolean}

    def cast(signals) do
      {%{done: false}, @types}
      |> Ecto.Changeset.cast(signals, Map.keys(@types))
      |> Ecto.Changeset.validate_required([:text])
      |> Ecto.Changeset.validate_length(:text, max: 200)
      |> Ecto.Changeset.validate_inclusion(:font_size, ~w(small medium large))
      |> Ecto.Changeset.apply_action(:insert)
    end

`{%{done: false}, @types}` is the schemaless form: the first element is
the default data, which is where the absent-checkbox rule lives. The
result is `{:ok, map}` or `{:error, changeset}`. Run against Ecto 3.12:

    iex> cast(%{"text" => "x"})
    {:ok, %{done: false, text: "x"}}

    iex> cast(%{"text" => "x", "done" => true, "font_size" => "medium"})
    {:ok, %{done: true, text: "x", font_size: "medium"}}

    iex> {:error, changeset} = cast(%{"text" => ""})
    iex> changeset.errors
    [text: {"can't be blank", [validation: :required]}]

Two details to know. A field with no default and no input, like
`font_size` above, is simply absent from the result map. And an explicit
JSON `null` overrides the default rather than falling back to it:

    iex> cast(%{"text" => "x", "done" => nil})
    {:ok, %{done: nil, text: "x"}}

If a signal can be `null`, normalise it before casting.

`cast/3` takes atom keys and matches them against the string keys in
`signals`, so a client-side `"fontSize"` is **silently dropped** unless
you have a matching atom (`:fontSize`) or rename the key before casting.
Name signals in snake case on the client (`$font_size`), or rename.

## Turning errors back into signals

Whatever caster you choose, the error has to reach the browser as a
signal:

    def reject(conn, changeset) do
      message =
        changeset
        |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
        |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)

      conn
      |> Datastar.Plug.start()
      |> Datastar.Plug.send_event!(Datastar.patch_signals(%{"_error" => message}))
    end

For `%{"text" => ""}` the message is `"text can't be blank"`, and for an
out-of-range `font_size` it is `"font_size is invalid"`. Status `200`,
error in the signal. That is the pattern, and it is the same whichever
library does the casting.
