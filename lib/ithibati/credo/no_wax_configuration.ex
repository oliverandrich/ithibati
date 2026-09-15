# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Credo.Check) do
  defmodule Ithibati.Credo.NoWaxConfiguration do
    use Credo.Check,
      id: "ITH102",
      base_priority: :high,
      category: :warning,
      explanations: [
        check: """
        `config :wax_, rp_id:` and `origin:` configure nothing that Ithibati does.

        `wax_` reads them as its own defaults, and Ithibati never lets them be reached. It passes
        both on every call, so one application can serve a browser and a native client with
        different answers. What you set here is not what a ceremony uses. This is also exactly
        where somebody looks for the setting, which is why it is worth a warning rather than
        silence.

        Ithibati passes the relying party and the origin per call instead. The routes derive them
        from your endpoint's configured `:url`, and `c:Ithibati.Web.Handler.relying_party/2` is
        where an application answers differently for a client whose origin is not that URL.

        This check reads `config/*.exs`, which Credo does not include by default. Add `config/`
        to `files.included` in your `.credo.exs`, or the check has nothing to look at.
        """
      ]

    @settings [:rp_id, :origin]

    @impl true
    def run(%SourceFile{} = source_file, params) do
      source_file
      |> SourceFile.ast()
      |> Credo.Code.prewalk(&{&1, collect(&1, &2, IssueMeta.for(source_file, params))})
      |> Enum.reverse()
    end

    defp collect(node, acc, issue_meta) do
      case config_call(node) do
        nil ->
          acc

        {args, meta} ->
          Enum.reduce(named(args), acc, &[issue_for(issue_meta, meta[:line], &1) | &2])
      end
    end

    # The module is wildcarded on purpose, so `Config.config` and any alias of it land here too.
    defp config_call({:config, meta, args}), do: {args, meta}
    defp config_call({{:., _, [_module, :config]}, meta, args}), do: {args, meta}
    defp config_call(_node), do: nil

    # Two forms, because `wax_` reads both: `Application.get_all_env(:wax_)` picks up whatever
    # `config/2` and `config/3` wrote alike.
    defp named([:wax_, settings]) when is_list(settings),
      do: for({key, _value} <- settings, key in @settings, do: key)

    defp named([:wax_, key, _value]) when key in @settings, do: [key]

    # `config :wax_, SomeModule, rp_id: …` writes `Application.get_env(:wax_, SomeModule)`, which
    # is a different key and one `wax_` never looks in — nothing inert is being set, so reporting
    # it would be wrong. A list built at run time is unrecognisable and equally left alone: a
    # check that raised on one would abort the whole Credo run rather than report anything.
    defp named(_args), do: []

    defp issue_for(issue_meta, line_no, key) do
      format_issue(issue_meta,
        message: "config :wax_, #{key}: is never read — this library passes it per call.",
        line_no: line_no,
        trigger: "#{key}"
      )
    end
  end
end
