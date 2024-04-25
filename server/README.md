# Report Server

## Authentication

The report server authenticates with the portal using oauth2.  Because the portal returns the access token as a hash parameter in the url the "oauth dance" is a little complex.  Here are the steps:

1. On any page load if a `portal` query parameter is present it is saved in the user's current session within `ReportServerWeb.Auth.Plug`.
2. When the user clicks the "Login" link they are redirected to the authorization url constructed by `ReportServerWeb.Auth.PortalStrategy`.  This authorization url uses the saved `portal` session variable and if that does not exist it uses the value configured for `url` under `config :report_server, :portal` in either `dev.exs` in development or `runtime.exs` in production.  Finally if no `url` config value is found it defaults to the staging portal.
3. When the user is not logged in and they access a protected url the user's session is checked to see if they have a valid, unexpired access token.  This check is done in the `mount/3` function in `ReportServerWeb.ReportLive.Index` (currently only that module needs authentication).  If they do not have a valid, unexpired access token they are redirected to the login page with the `return_to` parameter set which is then handled by step 2.
4. During the login step the portal authorization url is passed a redirect url of `/auth/callback` back on this server.  That route is handled by `ReportServerWeb.AuthLive.Callback` which is a LiveView as it needs to get access to the hash parameters which are not seen by the server.  The LiveView html either renders the error query parameter from the portal or if there is no error renders a div with the `AuthCallback` hook enabled.  This hook, defined in `app.js`, is triggered on mount and it parses the hash parameters and pushes a `save_token` event with the hash parameters if the `access_token` is present.  The `ReportServerWeb.AuthLive.Callback` process then handles that event by redirecting to `/auth/save_token` with the `access_token` and `expires_in` as parameters - this is needed as LiveViews can't update the user's session, only regular controllers can.
5. The `save_token` method in `ReportServerWeb.AuthController` saves the `access_token` and a computed `expires` value along with the `portal_url` in the user's session and then redirects to the `return_to` url saved in the session (and deletes that key in the session before the redirect).  At this point the user is "logged in" and if they return to a protected url like in step 3 the protected page will load.
6. At any time the user can click the "Logout" button at the top of the page.  This will clear the user's session, including the saved `portal` query parameter.


## Development Setup

First install the `asdf` version manager: https://asdf-vm.com/guide/getting-started.html

Then run `asdf install` in this project's directory.  It will use the `.tool-versions` file to install the proper version of Erlang and Elixir.

If you see an error about your SSL library missing do the following: if you are on a Mac run `brew install openssl` and on Linux run `sudo apt-get install libssl-dev`.

Finally if you are on Linux install the inotify tools via `sudo apt-get install inotify-tools`.

## Development

To start the Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.
