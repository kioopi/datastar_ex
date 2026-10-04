# Client attribute syntax

This library ships the server half of the Datastar protocol: it builds
events and writes them as SSE. The other half is the `data-*` attributes
in your markup, which the client reads. `Datastar.Attribute` builds
those, and this guide explains the rule it enforces, because getting it
wrong produces no error at all.

## The plugin name runs from `data-` to the first colon

The client parses an attribute name as:

    data-<plugin>:<key>__<modifier>.<arg>.<arg>__<modifier>

- The **plugin name** is everything between `data-` and the first colon
  (or the end of the name, if there is no colon), and it must be a
  plugin the client has registered.
- The **key** is everything after the first colon, up to the first `__`.
- Each `__`-separated segment after that is a **modifier**: its name,
  then its arguments, separated by `.`.

So this is wrong:

    <button data-on-click="@delete('/items/1')">Delete</button>

The plugin name is `on-click`, and the client has no plugin by that name,
so **the attribute is ignored in silence**: no console warning, no
exception, no visual difference. The page renders and the button does
nothing.

This is right:

    <button data-on:click="@delete('/items/1')">Delete</button>

The rule is *not* "never put a hyphen after `data-`". Several real
plugins have hyphenated names: `on-intersect`, `on-interval`,
`on-signal-patch` and `json-signals`. `data-on-intersect` is correct
because `on-intersect` is registered; `data-on-click` is wrong because
`on-click` is not.

### The registered plugins

For Datastar v1.0.4 (the version this library pins), the attribute
plugins are:

    attr  bind  class  computed  effect  indicator  init  json-signals
    on  on-intersect  on-interval  on-signal-patch  ref  show  signals
    style  text

A few `data-*` attributes are not plugins at all, so they take no key:

    ignore  ignore-morph  nonce  preserve-attr

The `@`-actions available inside expressions are `@get`, `@post`,
`@put`, `@patch`, `@delete`, `@peek`, `@setAll` and `@toggleAll`.

These lists are pinned and checked against the vendored client bundle by
this library's test suite. `Datastar.Attribute.plugins/0` and
`Datastar.Attribute.bare_attributes/0` return them, and are the source of
truth if this page ever lags a client upgrade.

## Let the library catch it

`Datastar.Attribute` validates the plugin name against that list, so the
mistake becomes an exception where you wrote it:

    iex> Datastar.Attribute.on(:click, "@delete('/items/1')")
    {"data-on:click", "@delete('/items/1')"}

    iex> Datastar.Attribute.attribute("on-click", "@delete('/items/1')")
    ** (ArgumentError) unknown Datastar plugin "on-click"; the client ignores an unknown plugin in silence. Known plugins: attr, bind, class, computed, effect, indicator, init, json-signals, on, on-intersect, on-interval, on-signal-patch, ref, show, signals, style, text, ignore, ignore-morph, nonce, preserve-attr

A hyphenated plugin that does exist is accepted:

    iex> Datastar.Attribute.attribute("on-intersect", "$seen = true")
    {"data-on-intersect", "$seen = true"}

Modifiers are options:

    iex> Datastar.Attribute.on(:init, "el.classList.add('leaving')", delay: "4s")
    {"data-on:init__delay.4s", "el.classList.add('leaving')"}

    iex> Datastar.Attribute.on(:click, "x", debounce: "500ms")
    {"data-on:click__debounce.500ms", "x"}

The client splits a modifier on `.` into its name and arguments, so
`Datastar.Attribute` rejects a `.` in a modifier name or argument. It
allows `.` in a key, because the client takes the key whole; and it
rejects `__` in a key, because the client would read it as the start of
a modifier. Bare attributes cannot take a key:

    iex> Datastar.Attribute.attribute("ignore", "", key: "x")
    ** (ArgumentError) "ignore" is a bare attribute, not a plugin, so it cannot take a :key (got "x")

## Tuples, and who escapes what

Every function returns a `{name, value}` tuple rather than markup,
because there is no single correct rendering: HEEx wants
`Phoenix.HTML.Safe`, plain EEx wants raw iodata.

In HEEx, spread the tuple (or a list of them):

    <button {[Datastar.Attribute.on(:click, Datastar.Attribute.action(:delete, "/items/#{@id}"))]}>
      Delete
    </button>

HEEx escapes the value for you. In plain EEx, render it yourself and
**escape the value**, because plain EEx has no auto-escaping:

    defp attr({name, value}), do: ~s( #{name}="#{html_escape(value)}")

`Datastar.Attribute` escapes for the contexts it owns: the
plugin/key/modifier grammar, and the single-quoted JavaScript string
inside `action/2`. It deliberately does **not** HTML-escape. HTML
escaping is the renderer's job, and a renderer that escapes again would
double-escape.

## Action expressions

`Datastar.Attribute.action/2` builds the `@verb('url')` value, escaping
the URL for the JS string literal it sits in:

    iex> Datastar.Attribute.action(:put, "/items/42")
    "@put('/items/42')"

    iex> Datastar.Attribute.action(:get, "/it'ems")
    "@get('/it\\'ems')"

Build these with `action/2` rather than interpolating a URL into a
string. With an integer id, hand-interpolation is safe; with a slug, a
single quote closes the string early.

## Redirects

The canonical Datastar redirect is a script event, not an attribute, and
it has its own constructor for the same reason: `Datastar.redirect/1,2`
JSON-encodes the URL into the script it sends.

    Datastar.redirect("/")
