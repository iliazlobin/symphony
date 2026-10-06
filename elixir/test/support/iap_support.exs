defmodule SymphonyElixir.IAPFixture do
  def key_pair do
    key = :public_key.generate_key({:namedCurve, {1, 2, 840, 10045, 3, 1, 7}})
    private = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
    public = :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, {{:ECPoint, elem(key, 4)}, {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}})])
    {private, public}
  end

  def claims do
    now = System.system_time(:second)

    %{
      "iss" => "https://cloud.google.com/iap",
      "aud" => "/projects/123/global/backendServices/456",
      "sub" => "accounts.google.com:fixture",
      "email" => "iliazlobin91@gmail.com",
      "iat" => now,
      "exp" => now + 600
    }
  end

  def token(private, changes \\ %{}, alg \\ "ES256", kid \\ "fixture") do
    {:ok, token} = Assent.JWTAdapter.AssentJWT.sign(Map.merge(claims(), changes), alg, private, private_key_id: kid, json_library: Jason)
    token
  end

  defmodule Keys do
    def init(opts), do: opts

    def call(conn, opts) do
      send(opts[:owner], :iap_keys_requested)
      if Plug.Conn.request_url(conn) != "https://www.gstatic.com/iap/verify/public_key", do: raise("IAP keys request must use the fixed provider URL")
      conn = if opts[:status] == 302, do: Plug.Conn.put_resp_header(conn, "location", "https://attacker.example/keys"), else: conn

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.put_resp_header("cache-control", opts[:cache] || "max-age=60")
      |> Plug.Conn.send_resp(opts[:status] || 200, Jason.encode!(opts[:keys]))
    end
  end
end
