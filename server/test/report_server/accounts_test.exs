defmodule ReportServer.AccountsTest do
  use ReportServer.DataCase

  import ReportServer.AccountsFixtures

  alias ReportServer.Accounts
  alias ReportServer.Accounts.ApiToken
  alias ReportServer.Accounts.AuthGrant

  defp pkce_pair() do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  describe "create_api_token/2" do
    test "returns a ccd_-prefixed raw token and stores only its hash" do
      user = user_fixture()

      {:ok, raw_token, api_token} = Accounts.create_api_token(user)

      assert String.starts_with?(raw_token, "ccd_")
      assert api_token.user_id == user.id

      stored = Repo.get!(ApiToken, api_token.id)
      assert stored.token_hash != raw_token
      assert String.length(stored.token_hash) == 64
      assert stored.token_hash == :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
      refute stored.token_hash =~ raw_token
    end

    test "allows a user to hold multiple active tokens with distinct hashes" do
      user = user_fixture()

      {:ok, raw_token_1, api_token_1} = Accounts.create_api_token(user)
      {:ok, raw_token_2, api_token_2} = Accounts.create_api_token(user)

      assert raw_token_1 != raw_token_2
      assert api_token_1.token_hash != api_token_2.token_hash

      assert {:ok, _user, _token} = Accounts.verify_api_token(raw_token_1)
      assert {:ok, _user, _token} = Accounts.verify_api_token(raw_token_2)
    end

    test "persists the optional label" do
      user = user_fixture()

      {:ok, _raw_token, api_token} = Accounts.create_api_token(user, "Doug's MacBook")
      assert Repo.get!(ApiToken, api_token.id).label == "Doug's MacBook"

      {:ok, _raw_token, unlabeled} = Accounts.create_api_token(user)
      assert Repo.get!(ApiToken, unlabeled.id).label == nil
    end
  end

  describe "verify_api_token/1" do
    test "resolves a valid token to its user" do
      user = user_fixture()
      {raw_token, api_token} = api_token_fixture(user)

      assert {:ok, verified_user, verified_token} = Accounts.verify_api_token(raw_token)
      assert verified_user.id == user.id
      assert verified_user.portal_email == user.portal_email
      assert verified_token.id == api_token.id
    end

    test "returns :error for unknown, garbage and non-binary tokens" do
      user = user_fixture()
      {raw_token, _api_token} = api_token_fixture(user)

      assert :error == Accounts.verify_api_token("ccd_unknown")
      assert :error == Accounts.verify_api_token("garbage")
      assert :error == Accounts.verify_api_token("")
      assert :error == Accounts.verify_api_token(nil)
      assert :error == Accounts.verify_api_token(raw_token <> "x")
    end
  end

  describe "revoke_api_token/1" do
    test "a revoked token stops authenticating immediately" do
      user = user_fixture()
      {raw_token, api_token} = api_token_fixture(user)

      assert {:ok, _user, _token} = Accounts.verify_api_token(raw_token)

      {:ok, _revoked} = Accounts.revoke_api_token(api_token)

      assert :error == Accounts.verify_api_token(raw_token)
    end
  end

  describe "touch_api_token/1" do
    test "sets last_used_at when it is nil" do
      user = user_fixture()
      {_raw_token, api_token} = api_token_fixture(user)

      assert api_token.last_used_at == nil

      {:ok, touched} = Accounts.touch_api_token(api_token)

      assert touched.last_used_at != nil
      assert Repo.get!(ApiToken, api_token.id).last_used_at != nil
    end

    test "is a no-op within the freshness threshold" do
      user = user_fixture()
      {_raw_token, api_token} = api_token_fixture(user)

      {:ok, touched} = Accounts.touch_api_token(api_token)
      {:ok, touched_again} = Accounts.touch_api_token(touched)

      assert touched_again.last_used_at == touched.last_used_at
      assert Repo.get!(ApiToken, api_token.id).last_used_at == touched.last_used_at
    end

    test "re-touches a token whose last_used_at is older than the threshold" do
      user = user_fixture()
      {_raw_token, api_token} = api_token_fixture(user)

      stale_time = DateTime.utc_now(:second) |> DateTime.add(-120)
      {:ok, stale} = Accounts.touch_api_token(%{api_token | last_used_at: stale_time})

      assert DateTime.compare(stale.last_used_at, stale_time) == :gt
      assert DateTime.compare(Repo.get!(ApiToken, api_token.id).last_used_at, stale_time) == :gt
    end
  end

  describe "create_auth_grant/3" do
    test "stores only the code hash, bound to the challenge/portal/user, expiring in ~5 minutes" do
      user = user_fixture()
      {_verifier, challenge} = pkce_pair()

      {:ok, raw_code, auth_grant} = Accounts.create_auth_grant(user, challenge, "https://learn.concord.org")

      stored = Repo.get!(AuthGrant, auth_grant.id)
      assert stored.code_hash != raw_code
      assert String.length(stored.code_hash) == 64
      assert stored.code_hash == :crypto.hash(:sha256, raw_code) |> Base.encode16(case: :lower)
      assert stored.code_challenge == challenge
      assert stored.portal_url == "https://learn.concord.org"
      assert stored.user_id == user.id

      expected = DateTime.utc_now(:second) |> DateTime.add(300)
      assert abs(DateTime.diff(stored.expires_at, expected)) <= 5
    end
  end

  describe "exchange_auth_grant/2" do
    test "mints a verifiable API token for a valid code/verifier pair and marks the grant used" do
      user = user_fixture()
      {verifier, challenge} = pkce_pair()
      {:ok, raw_code, auth_grant} = Accounts.create_auth_grant(user, challenge, "https://learn.concord.org")

      assert {:ok, raw_token, _api_token} = Accounts.exchange_auth_grant(raw_code, verifier)
      assert String.starts_with?(raw_token, "ccd_")
      assert {:ok, verified_user, _token} = Accounts.verify_api_token(raw_token)
      assert verified_user.id == user.id

      assert Repo.get!(AuthGrant, auth_grant.id).used_at != nil
    end

    test "returns :error for unknown, expired, used and verifier-mismatch codes" do
      user = user_fixture()
      {verifier, challenge} = pkce_pair()

      assert :error == Accounts.exchange_auth_grant("unknown-code", verifier)

      {:ok, expired_code, expired_grant} = Accounts.create_auth_grant(user, challenge, "https://learn.concord.org")
      past = DateTime.utc_now(:second) |> DateTime.add(-60)
      Repo.update_all(from(g in AuthGrant, where: g.id == ^expired_grant.id), set: [expires_at: past])
      assert :error == Accounts.exchange_auth_grant(expired_code, verifier)

      {:ok, used_code, _} = Accounts.create_auth_grant(user, challenge, "https://learn.concord.org")
      assert {:ok, _token, _} = Accounts.exchange_auth_grant(used_code, verifier)
      assert :error == Accounts.exchange_auth_grant(used_code, verifier)

      {:ok, mismatch_code, _} = Accounts.create_auth_grant(user, challenge, "https://learn.concord.org")
      assert :error == Accounts.exchange_auth_grant(mismatch_code, "wrong-verifier")
    end

    test "is single-use: a second sequential exchange of the same code returns :error" do
      user = user_fixture()
      {verifier, challenge} = pkce_pair()
      {:ok, raw_code, _} = Accounts.create_auth_grant(user, challenge, "https://learn.concord.org")

      assert {:ok, _token, _} = Accounts.exchange_auth_grant(raw_code, verifier)
      assert :error == Accounts.exchange_auth_grant(raw_code, verifier)
    end

    test "a verifier mismatch consumes the code, so a later correct-verifier exchange also fails" do
      user = user_fixture()
      {verifier, challenge} = pkce_pair()
      {:ok, raw_code, _} = Accounts.create_auth_grant(user, challenge, "https://learn.concord.org")

      assert :error == Accounts.exchange_auth_grant(raw_code, "wrong-verifier")
      assert :error == Accounts.exchange_auth_grant(raw_code, verifier)
    end
  end
end
