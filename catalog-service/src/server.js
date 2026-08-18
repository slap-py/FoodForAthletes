import http from "node:http";
import { catalogVersion, foodDetail, search } from "./catalog.js";

const port = Number(process.env.PORT ?? 8787);

http.createServer((request, response) => {
  const url = new URL(request.url, `http://${request.headers.host ?? "localhost"}`);
  response.setHeader("content-type", "application/json; charset=utf-8");
  response.setHeader("cache-control", "public, max-age=300");

  if (url.pathname === "/v1/catalog") return json(response, 200, { version: catalogVersion });
  if (url.pathname === "/v1/foods/search") return json(response, 200, { version: catalogVersion, foods: search(url.searchParams.get("q") ?? "").slice(0, 25) });
  const detail = url.pathname.match(/^\/v1\/foods\/([^/]+)$/);
  if (detail) {
    const food = foodDetail(decodeURIComponent(detail[1]));
    return json(response, food ? 200 : 404, food ?? { error: "food_not_found" });
  }
  return json(response, 404, { error: "route_not_found" });
}).listen(port, () => console.log(`Dayplate catalog ${catalogVersion} listening on ${port}`));

function json(response, status, value) { response.writeHead(status); response.end(JSON.stringify(value)); }
