// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let Hooks = {}
Hooks.AuthCallback = {
  mounted() {
    // this sends the auth params in the url hash to the callback liveview on mount
    // this is required since the hash parameters are not seen by the server
    const params = new URLSearchParams(window.location.hash.substring(1))
    if (params.get("access_token")) {
      this.pushEvent("save_token", Object.fromEntries(params))
    }
  }
}
Hooks.QueryDate = {
  mounted() {
    this._update_date();
  },
  updated() {
    this._update_date();
  },
  _update_date() {
    // show the query date in local time
    const date = new Date(Math.floor(this.el.dataset.date * 1000));
    this.el.innerHTML = date.toLocaleString()
  }
}
Hooks.DownloadButton = {
  mounted() {
    this.el.addEventListener("click", () => {
      this.pushEventTo(this.el.dataset.id, "download", this.el.dataset, (reply) => {
        if (reply?.url) {
          if (this.el.dataset.copy) {
            if (navigator?.clipboard?.writeText) {
              navigator.clipboard.writeText(reply.url)
              alert("The url has been copied to the clipboard.  It will expire in 10 minutes.")
            } else {
              alert("Sorry, the clipboard API is not available.")
            }
            return;
          }

          // the url has a content-disposition attachment so it will just download and not replace the page
          window.location.replace(reply.url)
        } else {
          alert("Unable to get signed url!")
        }
      })
    })
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

