# Report Server

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
