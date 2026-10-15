/**
 * The entry: mounts the Vue screen into `#app`.
 *
 * `lepton.ts` is the binding that gets you the channel; replace `App.vue` with your own
 * application and keep it.
 */

import { createApp } from "vue";
import App from "./App.vue";
import "./lepton-sdk.css";

createApp(App).mount("#app");
