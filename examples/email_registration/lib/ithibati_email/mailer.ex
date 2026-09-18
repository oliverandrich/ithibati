defmodule IthibatiEmail.Mailer do
  @moduledoc "The application's mailer; the adapter is configured by the application."
  use Swoosh.Mailer, otp_app: :ithibati_email
end
