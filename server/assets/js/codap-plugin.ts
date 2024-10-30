// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
import { initializePlugin, getDataContext, createDataContext, createParentCollection, createTable, createItems, codapInterface } from "@concord-consortium/codap-plugin-api";

// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

const Hooks = {
  CodapPlugin: {
    mounted() {
      // connect to CODAP
      const initialize = async () => {
        try {
          await initializePlugin({
            pluginName: "CC Public Portal Data",
            version: "0.0.1",
            dimensions: {
              width: 360,
              height: 536
            }
          });

          this.pushEvent("client_inited", {})

          this.handleEvent("query_result", async ({server, query, rows}) => {
            if (rows.length === 0) {
              return
            }

            try {
              const existingDataContext = await getDataContext(query);
              if (!existingDataContext.success) {
                await createDataContext(query)
                await createParentCollection(query, query, [{name: "portal"}, ...Object.keys(rows[0]).map(name => ({name}))])
                await createTable(query)
              } else {
                // delete all cases
                await codapInterface.sendRequest({
                  action: "delete",
                  resource: `dataContext[${query}].collection[${query}].allCases`
                })
              }

              await createItems(query, rows.map(row => ({portal: server, ...row})));
            } catch (e) {
              alert(`Can't display query result: ${e.toString()}`)
            }
          });
        } catch (e) {
          console.error("Failed to initialize plugin, error:", e);
        }
      };
      initialize();
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']")!.getAttribute("content")
let liveSocket = new LiveSocket("/live-iframe", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
(window as any).liveSocket = liveSocket

