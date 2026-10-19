/**
 * The Angular entry point: start the application with its one component.
 *
 * `lepton.ts` and `measures.ts` are shared with every other frontend, so choosing Angular
 * changed how the screen is expressed and nothing about what it measures.
 */

import { bootstrapApplication } from "@angular/platform-browser";
import { App } from "./app/app.ts";

bootstrapApplication(App).catch((error: unknown) => {
  console.error(error);
});
