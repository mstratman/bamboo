defmodule Bamboo.SendGridAdapterTest do
  use ExUnit.Case
  alias Bamboo.Email
  alias Bamboo.SendGridAdapter

  @config %{adapter: SendGridAdapter, api_key: "123_abc"}
  @config_with_bad_key %{adapter: SendGridAdapter, api_key: nil}
  @config_with_env_var_key %{adapter: SendGridAdapter, api_key: {:system, "SENDGRID_API"}}
  @config_with_sandbox_enabled %{adapter: SendGridAdapter, api_key: "123_abc", sandbox: true}

  defmodule FakeSendgrid do
    use Plug.Router

    plug(
      Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Jason
    )

    plug(:match)
    plug(:dispatch)

    def start_server(parent) do
      Agent.start_link(fn -> Map.new() end, name: __MODULE__)
      Agent.update(__MODULE__, &Map.put(&1, :parent, parent))
      port = get_free_port()
      Application.put_env(:bamboo, :sendgrid_base_uri, "http://localhost:#{port}")
      Plug.Adapters.Cowboy.http(__MODULE__, [], port: port, ref: __MODULE__)
    end

    defp get_free_port do
      {:ok, socket} = :ranch_tcp.listen(port: 0)
      {:ok, port} = :inet.port(socket)
      :erlang.port_close(socket)
      port
    end

    def shutdown do
      Plug.Adapters.Cowboy.shutdown(__MODULE__)
    end

    post "/mail/send" do
      case get_in(conn.params, ["from", "email"]) do
        "INVALID_EMAIL" -> conn |> send_resp(500, "Error!!") |> send_to_parent
        _ -> conn |> send_resp(200, "SENT") |> send_to_parent
      end
    end

    defp send_to_parent(conn) do
      parent = Agent.get(__MODULE__, fn set -> Map.get(set, :parent) end)
      send(parent, {:fake_sendgrid, conn})
      conn
    end
  end

  setup do
    FakeSendgrid.start_server(self())

    on_exit(fn ->
      FakeSendgrid.shutdown()
    end)

    :ok
  end

  test "raises if the api key is nil" do
    assert_raise ArgumentError, ~r/no API key set/, fn ->
      new_email(from: "foo@bar.com") |> SendGridAdapter.deliver(@config_with_bad_key)
    end

    assert_raise ArgumentError, ~r/no API key set/, fn ->
      SendGridAdapter.handle_config(%{})
    end
  end

  test "can read the api key from an ENV var" do
    System.put_env("SENDGRID_API", "123_abc")

    config = SendGridAdapter.handle_config(@config_with_env_var_key)

    assert config[:api_key] == "123_abc"
  end

  test "raises if an invalid ENV var is used for the API key" do
    System.delete_env("SENDGRID_API")

    assert_raise ArgumentError, ~r/no API key set/, fn ->
      new_email(from: "foo@bar.com") |> SendGridAdapter.deliver(@config_with_env_var_key)
    end

    assert_raise ArgumentError, ~r/no API key set/, fn ->
      SendGridAdapter.handle_config(@config_with_env_var_key)
    end
  end

  test "deliver/2 sends the to the right url" do
    new_email() |> SendGridAdapter.deliver(@config)

    assert_receive {:fake_sendgrid, %{request_path: request_path}}

    assert request_path == "/mail/send"
  end

  test "deliver/2 sends from, html and text body, subject, headers and attachment" do
    email =
      new_email(
        from: {"From", "from@foo.com"},
        subject: "My Subject",
        text_body: "TEXT BODY",
        html_body: "HTML BODY"
      )
      |> Email.put_header("Reply-To", "reply@foo.com")
      |> Email.put_attachment(Path.join(__DIR__, "../../../support/attachment.txt"))

    email |> SendGridAdapter.deliver(@config)

    assert SendGridAdapter.supports_attachments?()
    assert_receive {:fake_sendgrid, %{params: params, req_headers: headers}}

    assert params["from"]["name"] == email.from |> elem(0)
    assert params["from"]["email"] == email.from |> elem(1)
    assert params["subject"] == email.subject
    assert Enum.member?(params["content"], %{"type" => "text/plain", "value" => email.text_body})
    assert Enum.member?(params["content"], %{"type" => "text/html", "value" => email.html_body})
    assert Enum.member?(headers, {"authorization", "Bearer #{@config[:api_key]}"})

    assert params["attachments"] == [
             %{
               "type" => "text/plain",
               "filename" => "attachment.txt",
               "content" => "VGVzdCBBdHRhY2htZW50Cg=="
             }
           ]
  end

  test "deliver/2 correctly custom args" do
    email = new_email()

    email
    |> Email.put_private(:custom_args, %{post_code: "123"})
    |> SendGridAdapter.deliver(@config)

    assert_receive {:fake_sendgrid, %{params: params}}
    personalization = List.first(params["personalizations"])
    assert personalization["custom_args"] == %{"post_code" => "123"}
  end

  test "deliver/2 without custom args" do
    email = new_email()

    email
    |> SendGridAdapter.deliver(@config)

    assert_receive {:fake_sendgrid, %{params: params}}
    personalization = List.first(params["personalizations"])
    assert personalization["custom_args"] == nil
  end

  test "deliver/2 correctly formats recipients" do
    email =
      new_email(
        to: [{"To", "to@bar.com"}, {nil, "noname@bar.com"}],
        cc: [{"CC", "cc@bar.com"}],
        bcc: [{"BCC", "bcc@bar.com"}]
      )

    email |> SendGridAdapter.deliver(@config)

    assert_receive {:fake_sendgrid, %{params: params}}
    addressees = List.first(params["personalizations"])

    assert addressees["to"] == [
             %{"name" => "To", "email" => "to@bar.com"},
             %{"email" => "noname@bar.com"}
           ]

    assert addressees["cc"] == [%{"name" => "CC", "email" => "cc@bar.com"}]
    assert addressees["bcc"] == [%{"name" => "BCC", "email" => "bcc@bar.com"}]
  end

  test "deliver/2 correctly handles templates" do
    email =
      new_email(
        from: {"From", "from@foo.com"},
        subject: "My Subject"
      )

    email
    |> Bamboo.SendGridHelper.with_template("a4ca8ac9-3294-4eaf-8edc-335935192b8d")
    |> Bamboo.SendGridHelper.substitute("%foo%", "bar")
    |> SendGridAdapter.deliver(@config)

    assert_receive {:fake_sendgrid, %{params: params}}
    personalization = List.first(params["personalizations"])
    refute Map.has_key?(params, "content")
    assert params["template_id"] == "a4ca8ac9-3294-4eaf-8edc-335935192b8d"
    assert personalization["substitutions"] == %{"%foo%" => "bar"}
  end

  test "deliver/2 correctly handles an asm_group_id" do
    email =
      new_email(
        from: {"From", "from@foo.com"},
        subject: "My Subject"
      )

    email
    |> Bamboo.SendGridHelper.with_asm_group_id(1234)
    |> SendGridAdapter.deliver(@config)

    assert_receive {:fake_sendgrid, %{params: params}}
    assert params["asm"]["group_id"] == 1234
  end

  test "deliver/2 correctly handles a bypass_list_management" do
    email =
      new_email(
        from: {"From", "from@foo.com"},
        subject: "My Subject"
      )

    email
    |> Bamboo.SendGridHelper.with_bypass_list_management(true)
    |> SendGridAdapter.deliver(@config)

    assert_receive {:fake_sendgrid, %{params: params}}
    assert params["mail_settings"]["bypass_list_management"]["enable"] == true
  end

  test "deliver/2 doesn't force a subject" do
    email = new_email(from: {"From", "from@foo.com"})

    email
    |> SendGridAdapter.deliver(@config)

    assert_receive {:fake_sendgrid, %{params: params}}
    refute Map.has_key?(params, "subject")
  end

  test "deliver/2 correctly formats reply-to from headers" do
    email = new_email(headers: %{"reply-to" => "foo@bar.com"})

    email |> SendGridAdapter.deliver(@config)

    assert_receive {:fake_sendgrid, %{params: params}}
    assert params["reply_to"] == %{"email" => "foo@bar.com"}
  end

  test "deliver/2 correctly formats Reply-To from headers" do
    email = new_email(headers: %{"Reply-To" => "foo@bar.com"})

    email |> SendGridAdapter.deliver(@config)

    assert_receive {:fake_sendgrid, %{params: params}}
    assert params["reply_to"] == %{"email" => "foo@bar.com"}
  end

  test "deliver/2 correctly formats Reply-To from headers with name and email" do
    email = new_email(headers: %{"Reply-To" => {"Foo Bar", "foo@bar.com"}})

    email |> SendGridAdapter.deliver(@config)

    assert_receive {:fake_sendgrid, %{params: params}}
    assert params["reply_to"] == %{"email" => "foo@bar.com", "name" => "Foo Bar"}
  end

  test "deliver/2 correctly formats reply-to from headers with name and email" do
    email = new_email(headers: %{"reply-to" => {"Foo Bar", "foo@bar.com"}})

    email |> SendGridAdapter.deliver(@config)

    assert_receive {:fake_sendgrid, %{params: params}}
    assert params["reply_to"] == %{"email" => "foo@bar.com", "name" => "Foo Bar"}
  end

  test "deliver/2 omits attachments key if no attachments" do
    email = new_email()
    email |> SendGridAdapter.deliver(@config)

    assert_receive {:fake_sendgrid, %{params: params}}
    refute Map.has_key?(params, "attachments")
  end

  test "deliver/2 will set sandbox mode correctly" do
    email = new_email()
    email |> SendGridAdapter.deliver(@config_with_sandbox_enabled)

    assert_receive {:fake_sendgrid, %{params: params}}
    assert params["mail_settings"]["sandbox_mode"]["enable"] == true
  end

  test "deliver/2 with sandbox mode enabled, does not overwrite other mail_settings" do
    email = new_email()

    email
    |> Bamboo.SendGridHelper.with_bypass_list_management(true)
    |> SendGridAdapter.deliver(@config_with_sandbox_enabled)

    assert_receive {:fake_sendgrid, %{params: params}}
    assert params["mail_settings"]["sandbox_mode"]["enable"] == true
    assert params["mail_settings"]["bypass_list_management"]["enable"] == true
  end

  test "raises if the response is not a success" do
    email = new_email(from: "INVALID_EMAIL")

    assert_raise Bamboo.ApiError, fn ->
      email |> SendGridAdapter.deliver(@config)
    end
  end

  test "removes api key from error output" do
    email = new_email(from: "INVALID_EMAIL")

    assert_raise Bamboo.ApiError, ~r/"key" => "\[FILTERED\]"/, fn ->
      email |> SendGridAdapter.deliver(@config)
    end
  end

  defp new_email(attrs \\ []) do
    attrs = Keyword.merge([from: "foo@bar.com", to: []], attrs)
    Email.new_email(attrs) |> Bamboo.Mailer.normalize_addresses()
  end
end
