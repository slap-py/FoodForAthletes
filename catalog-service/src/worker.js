import { httpServerHandler } from "cloudflare:node";
import { server } from "./server.js";

// Keeps the same Node HTTP implementation for local development and Workers.
export default httpServerHandler(server);
