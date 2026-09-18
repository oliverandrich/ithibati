import Config

env = fn name, default ->
  case System.get_env(name) do
    value when value in [nil, ""] -> default
    value -> value
  end
end

adapter =
  case System.fetch_env!("ITHIBATI_ADAPTER_PROBE") do
    "postgres" -> Ecto.Adapters.Postgres
    "sqlite" -> Ecto.Adapters.SQLite3
    "mysql" -> Ecto.Adapters.MyXQL
    other -> raise "unknown adapter probe: #{inspect(other)}"
  end

key_type =
  case env.("ITHIBATI_USERS_KEY_TYPE", "binary_id") do
    "binary_id" -> :binary_id
    "id" -> :id
    other -> raise "invalid account key type: #{inspect(other)}"
  end

uuid_storage =
  case env.("ITHIBATI_SQLITE_UUID_STORAGE", "string") do
    "string" -> :string
    "binary" -> :binary
    other -> raise "invalid SQLite UUID storage: #{inspect(other)}"
  end

config :ecto_sqlite3, :binary_id_type, uuid_storage
config :ithibati, :users_key_type, key_type

config :ithibati, :probe_adapter, adapter
config :logger, level: :warning

connection =
  case adapter do
    Ecto.Adapters.SQLite3 ->
      [
        database:
          Path.expand("../tmp/adapter_probe_#{key_type}_#{uuid_storage}.sqlite3", __DIR__),
        busy_timeout: 1_000
      ]

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
        database:
          if(key_type == :id, do: "ithibati_adapter_probe_id", else: "ithibati_adapter_probe")
      ]
  end

config :ithibati,
       Ithibati.AdapterRepo,
       connection ++ [pool: Ecto.Adapters.SQL.Sandbox, pool_size: 4]

identity_options =
  if adapter == Ecto.Adapters.MyXQL,
    do: [
      after_connect:
        {MyXQL, :query!, ["SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED", []]}
    ],
    else: []

config :ithibati,
       Ithibati.AdapterIdentityRepo,
       connection ++ identity_options ++ [pool: Ecto.Adapters.SQL.Sandbox, pool_size: 4]
