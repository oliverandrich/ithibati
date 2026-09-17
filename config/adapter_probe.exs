import Config

adapter =
  case System.fetch_env!("ITHIBATI_ADAPTER_PROBE") do
    "postgres" -> Ecto.Adapters.Postgres
    "sqlite" -> Ecto.Adapters.SQLite3
    "mysql" -> Ecto.Adapters.MyXQL
    other -> raise "unknown adapter probe: #{inspect(other)}"
  end

config :ithibati, :probe_adapter, adapter
config :logger, level: :warning

connection =
  case adapter do
    Ecto.Adapters.SQLite3 ->
      [database: Path.expand("../tmp/adapter_probe.sqlite3", __DIR__), busy_timeout: 100]

    Ecto.Adapters.Postgres ->
      [
        hostname: System.get_env("PGHOST", "localhost"),
        port: String.to_integer(System.get_env("PGPORT", "5432")),
        username: System.get_env("PGUSER", "postgres"),
        password: System.get_env("PGPASSWORD", "postgres"),
        database: "ithibati_adapter_probe"
      ]

    Ecto.Adapters.MyXQL ->
      [
        protocol: :tcp,
        hostname: System.get_env("MYSQL_HOST", "localhost"),
        port: String.to_integer(System.get_env("MYSQL_PORT", "3306")),
        username: System.get_env("MYSQL_USER", "root"),
        password: System.get_env("MYSQL_PASSWORD", ""),
        database: "ithibati_adapter_probe"
      ]
  end

config :ithibati,
       Ithibati.AdapterRepo,
       connection ++ [pool: Ecto.Adapters.SQL.Sandbox, pool_size: 4]
